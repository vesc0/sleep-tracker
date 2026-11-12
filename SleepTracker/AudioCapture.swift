// AudioCapture writes short microphone segments, including while the phone is locked.
// NightAnalysis checks them for possible snoring when the app is open.

import AVFoundation
import SoundAnalysis
import OSLog

enum CaptureError: LocalizedError {
    case microphoneUnavailable, classifierUnavailable, unsupportedAudioFormat
    case writeClip(Error), analyzeClip(Error), saveSession(Error)

    var errorDescription: String? {
        switch self {
        case .microphoneUnavailable: "No microphone input is available."
        case .classifierUnavailable: "Snoring detection is unavailable on this device."
        case .unsupportedAudioFormat: "The microphone format couldn’t be converted."
        case .writeClip(let error): "Couldn’t write the recording. \(details(error))"
        case .analyzeClip(let error): "Couldn’t analyze the recording. \(details(error))"
        case .saveSession(let error): "Couldn’t save the session. \(details(error))"
        }
    }

    private func details(_ error: Error) -> String {
        let error = error as NSError
        return "\(error.localizedDescription) (\(error.domain) \(error.code))"
    }
}

private final class SnoreObserver: NSObject, SNResultsObserving {
    private let label: String
    private let lock = NSLock()
    private var detected = false
    private var failure: Error?

    init(label: String) { self.label = label }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let classification = (result as? SNClassificationResult)?.classifications.first,
              classification.identifier == label, classification.confidence >= 0.55 else { return }
        lock.withLock { detected = true }
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        lock.withLock { failure = error }
    }

    func requestDidComplete(_ request: SNRequest) {}

    func result() throws -> Bool {
        try lock.withLock {
            if let failure { throw failure }
            return detected
        }
    }
}

// The main actor controls the engine. The serial queue owns audio files and session metadata.
final class AudioCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "com.vesco.sleeptracker.analysis", qos: .utility)
    private let archive: NightArchive
    private let onFailure: (Error) -> Void
    private var night: Night
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var segmentID = UUID()
    private var frameCount: AVAudioFramePosition = 0
    private var tapInstalled = false
    private var failure: Error?

    init(night: Night, archive: NightArchive, onFailure: @escaping (Error) -> Void) {
        self.night = night
        self.archive = archive
        self.onFailure = onFailure
    }

    @MainActor
    func start() throws {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement)
            try session.setActive(true)
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw CaptureError.microphoneUnavailable
            }
            let converter = try Self.makeConverter(from: format)
            queue.sync { self.converter = converter }
            try archive.begin(night)
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
                self?.enqueue(buffer)
            }
            tapInstalled = true
            try engine.start()
        } catch {
            stopInput()
            queue.sync {}
            try? archive.delete(night)
            throw error
        }
    }

    @MainActor
    func finish(interrupted: Bool) async throws -> Night {
        engine.stop()
        removeTap()
        defer { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        // Finalize the last segment after all queued audio buffers have been written.
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.finishSegment()
                self.night.isComplete = true
                self.night.wasInterrupted = interrupted || self.failure != nil
                do {
                    try self.archive.save(self.night)
                    continuation.resume(returning: self.night)
                } catch {
                    continuation.resume(throwing: CaptureError.saveSession(error))
                }
            }
        }
    }

    @MainActor
    func lostInput(_ notification: Notification) -> Bool {
        notification.object as? AVAudioEngine === engine && !engine.isRunning
    }

    private func removeTap() {
        guard tapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
    }

    private func stopInput() {
        engine.stop()
        removeTap()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func enqueue(_ buffer: AVAudioPCMBuffer) {
        // Copy the tap buffer before handing it off to the recording queue.
        guard buffer.frameLength > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(source, destination) {
            if let fromData = from.mData, let toData = to.mData {
                memcpy(toData, fromData, Int(from.mDataByteSize))
            }
        }
        queue.async { self.consume(copy) }
    }

    private func consume(_ input: AVAudioPCMBuffer) {
        guard failure == nil, let converter else { return }
        do {
            let buffer = try Self.convert(input, using: converter)
            guard buffer.frameLength > 0 else { return }
            if file == nil {
                segmentID = UUID()
                let url = archive.clipURL(segmentID, in: night.id)
                // Apply protection before Core Audio opens the file, including when already locked.
                try Data().write(to: url, options: [.withoutOverwriting, .completeFileProtectionUntilFirstUserAuthentication])
                do {
                    var settings = buffer.format.settings
                    settings[AVLinearPCMBitDepthKey] = 16
                    settings[AVLinearPCMIsFloatKey] = false
                    file = try AVAudioFile(forWriting: url, settings: settings,
                                           commonFormat: buffer.format.commonFormat, interleaved: buffer.format.isInterleaved)
                } catch {
                    try? FileManager.default.removeItem(at: url)
                    throw error
                }
            }
            try file?.write(from: buffer)
            frameCount += AVAudioFramePosition(buffer.frameLength)
            if Double(frameCount) / buffer.format.sampleRate >= 8 { finishSegment() }
        } catch {
            reportFailure(CaptureError.writeClip(error))
        }
    }

    private static func makeConverter(from input: AVAudioFormat) throws -> AVAudioConverter {
        // Use 16 kHz mono to reduce overnight storage.
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
              let converter = AVAudioConverter(from: input, to: format) else {
            throw CaptureError.unsupportedAudioFormat
        }
        return converter
    }

    private static func convert(_ input: AVAudioPCMBuffer, using converter: AVAudioConverter) throws -> AVAudioPCMBuffer {
        let format = converter.outputFormat
        let expectedFrames = ceil(Double(input.frameLength) * format.sampleRate / input.format.sampleRate)
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(expectedFrames) + 256) else {
            throw CaptureError.unsupportedAudioFormat
        }
        var suppliedInput = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if suppliedInput {
                // More input will arrive with the next tap buffer.
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return input
        }
        if status == .error {
            if let error { throw error }
            throw CaptureError.unsupportedAudioFormat
        }
        return output
    }

    private func finishSegment() {
        guard let rate = file?.processingFormat.sampleRate else { return }
        file = nil
        let duration = Double(frameCount) / rate
        frameCount = 0
        let clip = SoundClip(id: segmentID, startedAt: night.endedAt, duration: duration)
        night.endedAt = night.endedAt.addingTimeInterval(duration)
        let url = archive.clipURL(clip, in: night)
        guard failure == nil, duration >= 1.5 else {
            do { try FileManager.default.removeItem(at: url) }
            catch { reportFailure(CaptureError.writeClip(error)) }
            return
        }
        night.pendingClips?.append(clip)
        // Checkpoint in batches to limit disk writes during long sessions.
        if let count = night.pendingClips?.count, count.isMultiple(of: 8) {
            do { try archive.save(night) }
            catch { reportFailure(CaptureError.saveSession(error)) }
        }
    }

    private func reportFailure(_ error: Error) {
        guard failure == nil else { return }
        failure = error
        onFailure(error)
    }
}


enum NightAnalysis {
    static func run(
        _ original: Night, archive: NightArchive,
        didSave: @Sendable (Night) async -> Void
    ) async throws {
        guard let pending = original.pendingClips, !pending.isEmpty else { return }
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        guard request.knownClassifications.contains("snoring") else {
            throw CaptureError.classifierUnavailable
        }

        var night = original
        var completed = Set<UUID>()
        var discarded: [SoundClip] = []
        var firstError: Error?
        let logger = Logger(subsystem: "com.vesco.sleeptracker", category: "analysis")
        var consecutiveFailures = 0

        for clip in pending {
            if Task.isCancelled { break }
            do {
                if try containsSnoring(at: archive.clipURL(clip, in: night), request: request) {
                    night.clips.append(clip)
                } else {
                    discarded.append(clip)
                }
                completed.insert(clip.id)
                consecutiveFailures = 0
            } catch {
                firstError = firstError ?? error
                consecutiveFailures += 1
                // Leave failed clips pending for retry. Stop this pass after repeated errors.
                if consecutiveFailures == 3 { break }
            }
            if completed.count >= 16 {
                try await checkpoint()
            }
        }
        try await checkpoint()
        if let firstError, !Task.isCancelled { throw CaptureError.analyzeClip(firstError) }

        func checkpoint() async throws {
            guard !completed.isEmpty else { return }
            night.pendingClips?.removeAll { completed.contains($0.id) }
            night.clips.sort { $0.startedAt < $1.startedAt }
            do { try archive.save(night) }
            catch { throw CaptureError.saveSession(error) }
            // Commit the archive before deleting audio it no longer references.
            for clip in discarded {
                do { try FileManager.default.removeItem(at: archive.clipURL(clip, in: night)) }
                catch { logger.error("Could not remove a processed audio segment: \(error.localizedDescription, privacy: .private)") }
            }
            completed.removeAll()
            discarded.removeAll()
            await didSave(night)
        }
    }

    private static func containsSnoring(at url: URL, request: SNClassifySoundRequest) throws -> Bool {
        let observer = SnoreObserver(label: "snoring")
        let analyzer = try SNAudioFileAnalyzer(url: url)
        try analyzer.add(request, withObserver: observer)
        analyzer.analyze()
        analyzer.removeAllRequests()
        return try observer.result()
    }
}
