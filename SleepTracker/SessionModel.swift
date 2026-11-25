// Coordinates recording, analysis, and playback on the main actor.
// Publishes session history, progress, and errors for the SwiftUI screens.

import AVFoundation
import SwiftUI

@MainActor
final class SessionModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var nights: [Night] = []
    @Published private(set) var startedAt: Date?
    @Published private(set) var isBusy = false
    @Published private(set) var playingID: UUID?
    @Published private(set) var analyzingID: UUID?
    @Published private(set) var analysisProgress: Double = 0
    @Published private(set) var analysisProblems: [UUID: String] = [:]
    @Published var problem: String?
    @Published var showMicrophoneSettings = false

    #if DEBUG
    @Published private(set) var sampleNights: [Night] = []
    #endif

    var historyNights: [Night] {
        #if DEBUG
        return (nights + sampleNights).sorted { $0.startedAt > $1.startedAt }
        #else
        return nights
        #endif
    }

    func isSampleNight(_ id: UUID) -> Bool {
        #if DEBUG
        return sampleNights.contains { $0.id == id }
        #else
        return false
        #endif
    }

    #if DEBUG
    func addSampleData(now: Date = .now, calendar: Calendar = .current) {
        guard sampleNights.isEmpty else { return }

        // Leave gaps and vary session lengths and sound labels to exercise the charts.
        let today = calendar.startOfDay(for: now)
        sampleNights = (1...60).compactMap { offset in
            guard !offset.isMultiple(of: 9),
                  let date = calendar.date(byAdding: .day, value: -offset, to: today),
                  let start = calendar.date(bySettingHour: 22 + offset % 2,
                                            minute: (offset * 13) % 60, second: 0, of: date) else { return nil }

            let duration = TimeInterval((330 + (offset * 47) % 210) * 60)
            let end = start.addingTimeInterval(duration)
            guard end <= now else { return nil }

            let clipCount = (offset * 11) % 19
            let clips = (0..<clipCount).map { index in
                let group = index / 3
                let position = duration * Double(group + 1) / Double(clipCount / 3 + 2) + Double(index % 3) * 8
                let sound = NightSound.allCases[(offset + group) % NightSound.allCases.count]
                let sounds: [NightSound] = index.isMultiple(of: 5) && sound == .snoring
                    ? [.snoring, .speech] : [sound]
                return SoundClip(id: UUID(), startedAt: start.addingTimeInterval(position),
                                 duration: 8, sounds: sounds)
            }
            let tags: Set<NightTag> = offset.isMultiple(of: 3) ? [.lateCaffeine, .backSleeping] : [.sideSleeping]
            let checkIn = NightCheckIn(restedRating: offset.isMultiple(of: 4) ? nil : 1 + offset % 5, tags: tags)
            // Sparse background samples keep the debug dataset small.
            let background = stride(from: 0.0, to: duration, by: 60).map { position in
                let power = 0.00001 * (2 + sin(position / 600))
                return RecordingLevel(start: start.addingTimeInterval(position), duration: 8,
                                      power: power, peak: 3 * sqrt(power))
            }
            let detected = clips.map { RecordingLevel(start: $0.startedAt, duration: $0.duration,
                                                       power: 0.001, peak: 0.12) }
            return Night(id: UUID(), startedAt: start, endedAt: end, isComplete: true, clips: clips,
                         checkIn: checkIn, levels: (background + detected).sorted { $0.start < $1.start })
        }
    }

    func clearSampleData() {
        sampleNights.removeAll()
    }
    #endif

    @Published private(set) var pausedReason: String?
    @Published private(set) var managingAudio = false
    @Published private(set) var storageBytes: Int64 = 0
    private var waitingForSystem = false
    private var resumeTask: Task<Void, Never>?
    private var autoResume = true
    private var archive: NightArchive?
    private var capture: AudioCapture?
    private var player: AVAudioPlayer?
    private var analysisTask: Task<Void, Never>?

    override init() {
        super.init()
        do {
            let archive = try NightArchive()
            self.archive = archive
            nights = try archive.load()
        } catch {
            problem = error.localizedDescription
        }
    }

    func start() async {
        guard capture == nil, !isBusy, !managingAudio, analyzingID == nil else { return }
        stopPlayback()
        isBusy = true
        defer { isBusy = false }
        guard await AVAudioApplication.requestRecordPermission() else {
            showMicrophoneSettings = true
            return
        }
        do {
            let archive = try self.archive ?? NightArchive()
            self.archive = archive
            let now = Date()
            let options = RecordingOptions()
            autoResume = options.autoResume
            let night = Night(id: UUID(), startedAt: now, endedAt: now, pendingClips: [], options: options)
            let capture = AudioCapture(night: night, archive: archive) { [weak self] error in
                Task { @MainActor in
                    await self?.finish(interrupted: true)
                    self?.problem = error.localizedDescription
                }
            }
            try capture.start()
            self.capture = capture
            waitingForSystem = false
            startedAt = now
        } catch {
            problem = error.localizedDescription
        }
    }

    @discardableResult
    func finish(interrupted: Bool = false) async -> Night? {
        guard let capture, !isBusy else { return nil }
        isBusy = true
        resumeTask?.cancel()
        pausedReason = nil
        waitingForSystem = false
        defer {
            startedAt = nil
            self.capture = nil
            isBusy = false
        }
        do {
            let night = try await capture.finish(interrupted: interrupted)
            nights.insert(night, at: 0)
            return night
        } catch {
            problem = error.localizedDescription
            return nil
        }
    }

    func handleInterruption(_ notification: Notification) async {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .began {
            stopPlayback()
            waitingForSystem = true
            resumeTask?.cancel()
            let rawReason = notification.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt
            let reason: String = switch rawReason.flatMap(AVAudioSession.InterruptionReason.init(rawValue:)) {
            case .default: "Another audio session interrupted recording"
            case .builtInMicMuted: "The built-in microphone was muted"
            case .routeDisconnected: "The microphone disconnected"
            default: "iOS interrupted microphone access"
            }
            await pauseCapture(reason)
        } else if type == .ended {
            waitingForSystem = false
            scheduleResume()
        }
    }

    func handleEngineChange(_ notification: Notification) async {
        guard capture?.lostInput(notification) == true, pausedReason == nil else { return }
        await pauseCapture("The microphone input changed")
        if !waitingForSystem { scheduleResume() }
    }

    private func pauseCapture(_ reason: String) async {
        guard let capture, !isBusy, pausedReason == nil else { return }
        do {
            try capture.pause(reason: reason)
            pausedReason = reason
            if !autoResume { await finish(interrupted: true) }
        } catch {
            await finish(interrupted: true)
            problem = error.localizedDescription
        }
    }

    func becameActive() async {
        // iOS can suspend the app before it receives the end notification.
        if autoResume, pausedReason != nil { _ = resumeRecording(manual: false) }
        await maintainAudio()
    }

    private func scheduleResume() {
        guard autoResume, pausedReason != nil, !waitingForSystem else { return }
        resumeTask?.cancel()
        resumeTask = Task {
            // Audio routes can take time to become available after an interruption.
            var delay = 2
            while !Task.isCancelled, pausedReason != nil, !waitingForSystem {
                if resumeRecording(manual: false) { return }
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                delay = min(60, delay * 2)
            }
        }
    }

    @discardableResult
    func resumeRecording(manual: Bool = true) -> Bool {
        guard let capture, pausedReason != nil, !isBusy else { return false }
        do {
            try capture.start(resuming: true)
            pausedReason = nil
            waitingForSystem = false
            return true
        } catch {
            if manual { problem = error.localizedDescription }
            return false
        }
    }

    func analyze(_ id: UUID) {
        guard analyzingID == nil, capture == nil, !isBusy, !managingAudio,
              let archive, let night = nights.first(where: { $0.id == id }), night.needsAnalysis else { return }
        analysisProblems[id] = nil
        analysisProgress = night.analysisProgress
        analyzingID = id
        // Prevent auto-lock while Sound Analysis runs.
        UIApplication.shared.isIdleTimerDisabled = true
        analysisTask = Task.detached(priority: .utility) { [weak self] in
            var problem: String?
            do {
                try await NightAnalysis.run(night, archive: archive, didProgress: { [weak self] progress in
                    await self?.updateAnalysisProgress(progress)
                }) { [weak self] updated in
                    await self?.updateNight(updated)
                }
            } catch {
                if !Task.isCancelled { problem = error.localizedDescription }
            }
            await self?.endAnalysis(id: id, problem: problem)
        }
    }

    func pauseAnalysis() {
        guard let analysisTask else { return }
        UIApplication.shared.isIdleTimerDisabled = false
        analysisTask.cancel()
    }

    private func updateNight(_ night: Night) {
        if let index = nights.firstIndex(where: { $0.id == night.id }) {
            nights[index] = night
        }
    }

    private func updateAnalysisProgress(_ progress: Double) {
        analysisProgress = progress
    }

    private func endAnalysis(id: UUID, problem: String?) {
        UIApplication.shared.isIdleTimerDisabled = false
        analyzingID = nil
        analysisTask = nil
        analysisProblems[id] = problem
        Task { await maintainAudio() }
    }

    @discardableResult
    func editNight(_ id: UUID, _ edit: (inout Night) -> Void) -> Bool {
        guard analyzingID != id else { return false }
        #if DEBUG
        if let index = sampleNights.firstIndex(where: { $0.id == id }) {
            edit(&sampleNights[index])
            return true
        }
        #endif
        guard let archive, let index = nights.firstIndex(where: { $0.id == id }) else { return false }
        var updated = nights[index]
        edit(&updated)
        do {
            try archive.save(updated)
            nights[index] = updated
            return true
        } catch {
            problem = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func editClip(_ clipID: UUID, in nightID: UUID, _ edit: (inout SoundClip) -> Void) -> Bool {
        let saved = editNight(nightID) { night in
            guard let index = night.clips.firstIndex(where: { $0.id == clipID }) else { return }
            edit(&night.clips[index])
        }
        if playingID == clipID,
           nights.first(where: { $0.id == nightID })?.activeClips.contains(where: { $0.id == clipID }) == false {
            stopPlayback()
        }
        return saved
    }

    func delete(_ night: Night) {
        #if DEBUG
        if isSampleNight(night.id) {
            sampleNights.removeAll { $0.id == night.id }
            return
        }
        #endif
        guard analyzingID != night.id, !managingAudio else { return }
        stopPlayback()
        do {
            try archive?.delete(night)
            nights.removeAll { $0.id == night.id }
            analysisProblems[night.id] = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    func play(_ clip: SoundClip, in night: Night, from fraction: Double = 0) {
        guard !isSampleNight(night.id), capture == nil, !isBusy, !managingAudio, let url = audioURL(for: clip, in: night) else { return }
        let alreadyPlaying = playingID == clip.id
        stopPlayback()
        guard !alreadyPlaying else { return }
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playback, mode: .default)
            try audio.setActive(true)
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            self.player = player
            player.currentTime = min(fraction * player.duration, max(0, player.duration - 0.01))
            guard player.play() else { throw CocoaError(.fileReadUnknown) }
            playingID = clip.id
        } catch {
            stopPlayback()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            problem = "The clip could not be played."
        }
    }

    func playbackFraction(for clipID: UUID) -> Double? {
        guard playingID == clipID, let player, player.duration > 0 else { return nil }
        return player.currentTime / player.duration
    }

    func seekPlayback(_ clipID: UUID, to fraction: Double) {
        guard playingID == clipID, let player else { return }
        player.currentTime = min(fraction * player.duration, max(0, player.duration - 0.01))
    }

    func audioURL(for clip: SoundClip, in night: Night) -> URL? {
        guard !isSampleNight(night.id) else { return nil }
        guard let url = archive?.clipURL(clip, in: night), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    func maintainAudio(clearOlderThan days: Int? = nil) async {
        guard let archive, !managingAudio, !isBusy, analyzingID == nil, capture == nil else { return }
        managingAudio = true
        defer { managingAudio = false }
        let retention = UserDefaults.standard.integer(forKey: "retentionDays")
        let cutoff = (days ?? (retention > 0 ? retention : nil)).flatMap {
            Calendar.current.date(byAdding: .day, value: -$0, to: Date())
        }
        let sessions = nights
        if let cutoff, let playingID, sessions.contains(where: {
            !$0.needsAnalysis && $0.endedAt <= cutoff && ($0.id == playingID || $0.clips.contains { $0.id == playingID })
        }) { stopPlayback() }
        do {
            storageBytes = try await Task.detached(priority: .utility) {
                try archive.measureAudio(sessions, removingBefore: cutoff)
            }.value
        } catch { problem = error.localizedDescription }
    }

    func export(id: UUID?, audio: Bool) async throws -> URL {
        guard let archive, !managingAudio, !isBusy, capture == nil, analyzingID == nil else {
            throw CocoaError(.fileLocking)
        }
        let sessions = nights.filter { id == nil || $0.id == id }
        guard !sessions.isEmpty else { throw CocoaError(.fileNoSuchFile) }
        managingAudio = true
        defer { managingAudio = false }
        return try await Task.detached(priority: .utility) {
            try archive.export(sessions, audio: audio)
        }.value
    }

    func stopPlayback() {
        guard let player else { return }
        player.stop()
        self.player = nil
        playingID = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            // Ignore callbacks from a player that has already been replaced.
            if self.player === player { stopPlayback() }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            guard self.player === player else { return }
            stopPlayback()
            problem = "The clip could not be played."
        }
    }
}
