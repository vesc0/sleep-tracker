// AudioCapture writes short microphone segments, including while the phone is locked.
// NightAnalysis checks them for snoring, speech, and coughing when the app is open.

import Accelerate
import AVFoundation
import SoundAnalysis
import OSLog

enum CaptureError: LocalizedError {
    case microphoneUnavailable, classifierUnavailable, unsupportedAudioFormat
    case writeClip(Error), analyzeClip(Error), saveSession(Error)

    var errorDescription: String? {
        switch self {
        case .microphoneUnavailable: "No microphone input is available."
        case .classifierUnavailable: "Sound detection is unavailable on this device."
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

private final class NightSoundObserver: NSObject, SNResultsObserving {
    private let lock = NSLock()
    private var detected: [SoundWindow] = []
    private var failure: Error?

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult, let classification = result.classifications.first,
              classification.confidence >= 0.55,
              let sound = NightSound(rawValue: classification.identifier) else { return }
        let range = result.timeRange
        lock.withLock { detected.append(.init(sound: sound, start: range.start.seconds, end: range.end.seconds)) }
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        lock.withLock { failure = error }
    }

    func requestDidComplete(_ request: SNRequest) {}

    func result() throws -> [SoundWindow] {
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
    private var fullFile: AVAudioFile?
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var segmentID = UUID()
    private var energy = 0.0
    private var peak: Float = 0
    private var frameCount: AVAudioFramePosition = 0
    private var tapInstalled = false
    private var failure: Error?

    init(night: Night, archive: NightArchive, onFailure: @escaping (Error) -> Void) {
        self.night = night
        self.archive = archive
        self.onFailure = onFailure
    }

    @MainActor
    func start(resuming: Bool = false) throws {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement)
            try session.setActive(true)
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw CaptureError.microphoneUnavailable
            }
            let converter = try Self.makeConverter(from: format, rate: night.options?.sampleRate ?? 16_000)
            queue.sync { self.converter = converter }
            if !resuming { try archive.begin(night) }
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
                self?.enqueue(buffer)
            }
            tapInstalled = true
            try engine.start()
        } catch {
            stopInput()
            queue.sync {}
            if !resuming { try? archive.delete(night) }
            throw error
        }
    }

    @MainActor
    func pause(reason: String) throws {
        engine.stop()
        removeTap()
        try queue.sync {
            finishSegment()
            converter = nil
            if let gap = night.gaps?.last, gap.end == nil { return }
            if night.gaps == nil { night.gaps = [] }
            let gap = RecordingGap(start: night.endedAt, reason: reason)
            night.gaps?.append(gap)
            try archive.save(night)
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
                self.fullFile = nil
                self.closeGap(at: Date())
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

    // Keep clip timestamps on wall time, excluding the pause from recording duration.
    private func closeGap(at time: Date) {
        guard let last = night.gaps?.last, last.end == nil, let count = night.gaps?.count else { return }
        let end = max(last.start, time)
        night.gaps?[count - 1].end = end
        night.endedAt = end
    }

    private func openFile(_ id: UUID, format: AVAudioFormat) throws -> AVAudioFile {
        let url = archive.clipURL(id, in: night)
        try Data().write(to: url, options: [.withoutOverwriting, .completeFileProtectionUntilFirstUserAuthentication])
        var settings = format.settings
        if let bitRate = night.options?.quality?.aacBitRate {
            settings = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: bitRate
            ]
        } else {
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
        }
        do {
            return try AVAudioFile(forWriting: url, settings: settings, commonFormat: format.commonFormat,
                                   interleaved: format.isInterleaved)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private func consume(_ input: AVAudioPCMBuffer) {
        guard failure == nil, let converter else { return }
        do {
            let buffer = try Self.convert(input, using: converter)
            guard buffer.frameLength > 0 else { return }
            if file == nil {
                segmentID = UUID()
                file = try openFile(segmentID, format: buffer.format)
                closeGap(at: Date().addingTimeInterval(-Double(buffer.frameLength) / buffer.format.sampleRate))
            }
            if night.options?.keepFullAudio == true {
                if fullFile == nil { fullFile = try openFile(night.id, format: buffer.format) }
                try fullFile?.write(from: buffer)
            }
            try file?.write(from: buffer)
            if let samples = buffer.floatChannelData?[0] {
                let count = vDSP_Length(buffer.frameLength)
                var sum: Float = 0
                var maximum: Float = 0
                vDSP_svesq(samples, 1, &sum, count)
                vDSP_maxmgv(samples, 1, &maximum, count)
                energy += Double(sum)
                peak = max(peak, maximum)
            }
            frameCount += AVAudioFramePosition(buffer.frameLength)
            if Double(frameCount) / buffer.format.sampleRate >= 8 { finishSegment() }
        } catch {
            reportFailure(CaptureError.writeClip(error))
        }
    }

    private static func makeConverter(from input: AVAudioFormat, rate: Double) throws -> AVAudioConverter {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
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
        let clip = SoundClip(id: segmentID, startedAt: night.endedAt, duration: duration)
        if frameCount > 0 {
            if night.levels == nil { night.levels = [] }
            night.levels?.append(.init(start: clip.startedAt, duration: duration,
                                       power: energy / Double(frameCount), peak: Double(peak)))
        }
        energy = 0
        peak = 0
        frameCount = 0
        night.endedAt = night.endedAt.addingTimeInterval(duration)
        let url = archive.clipURL(clip, in: night)
        if failure != nil || duration < 1.5 || night.options?.sounds.isEmpty == true {
            do { try FileManager.default.removeItem(at: url) }
            catch { reportFailure(CaptureError.writeClip(error)) }
        } else {
            night.pendingClips?.append(clip)
        }
        // Checkpoint in batches to limit disk writes during long sessions.
        if let count = night.levels?.count, count.isMultiple(of: 8) {
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
        didProgress: @Sendable (Double) async -> Void,
        didSave: @Sendable (Night) async -> Void
    ) async throws {
        guard let pending = original.pendingClips, !pending.isEmpty else { return }
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        guard Set(NightSound.allCases.map(\.rawValue)).isSubset(of: Set(request.knownClassifications)) else {
            throw CaptureError.classifierUnavailable
        }

        let enabled = Set(original.options?.sounds ?? NightSound.allCases)
        var night = original
        var completed = Set<UUID>()
        var discarded: [SoundClip] = []
        var firstError: Error?
        let logger = Logger(subsystem: "com.vesco.sleeptracker", category: "analysis")
        var consecutiveFailures = 0
        var remaining = pending.reduce(0) { $0 + $1.duration }
        var lastPercent = Int((original.analysisProgress * 100).rounded())

        for clip in pending {
            if Task.isCancelled { break }
            do {
                let sounds = try detectSounds(at: archive.clipURL(clip, in: night), request: request)
                    .filter { enabled.contains($0.sound) }
                if sounds.isEmpty {
                    discarded.append(clip)
                } else {
                    // Several distinct sounds can occur in a single recording segment.
                    var labeledClip = clip
                    labeledClip.windows = sounds
                    labeledClip.sounds = NightSound.allCases.filter { label in sounds.contains { $0.sound == label } }
                    night.clips.append(labeledClip)
                }
                completed.insert(clip.id)
                consecutiveFailures = 0
                remaining -= clip.duration
                // Publish whole-percent changes without adding disk checkpoints.
                if original.duration > 0 {
                    let progress = min(0.99, max(0, 1 - remaining / original.duration))
                    let percent = Int((progress * 100).rounded())
                    if percent != lastPercent {
                        lastPercent = percent
                        await didProgress(progress)
                    }
                }
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

    private static func detectSounds(at url: URL, request: SNClassifySoundRequest) throws -> [SoundWindow] {
        let observer = NightSoundObserver()
        let analyzer = try SNAudioFileAnalyzer(url: url)
        try analyzer.add(request, withObserver: observer)
        analyzer.analyze()
        analyzer.removeAllRequests()
        return try observer.result()
    }
}
