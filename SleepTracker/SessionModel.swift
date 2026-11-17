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
                let position = duration * Double(index + 1) / Double(clipCount + 1)
                let sound = NightSound.allCases[(offset + index) % NightSound.allCases.count]
                let sounds: [NightSound] = index.isMultiple(of: 5) && sound == .snoring
                    ? [.snoring, .speech] : [sound]
                return SoundClip(id: UUID(), startedAt: start.addingTimeInterval(position),
                                 duration: 8, sounds: sounds)
            }
            let tags: Set<NightTag> = offset.isMultiple(of: 3) ? [.lateCaffeine, .backSleeping] : [.sideSleeping]
            let checkIn = NightCheckIn(restedRating: offset.isMultiple(of: 4) ? nil : 1 + offset % 5, tags: tags)
            return Night(id: UUID(), startedAt: start, endedAt: end, isComplete: true, clips: clips, checkIn: checkIn)
        }
    }

    func clearSampleData() {
        sampleNights.removeAll()
    }
    #endif

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
        guard capture == nil, !isBusy, analyzingID == nil else { return }
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
            let night = Night(id: UUID(), startedAt: now, endedAt: now, pendingClips: [])
            let capture = AudioCapture(night: night, archive: archive) { [weak self] error in
                Task { @MainActor in
                    await self?.finish(interrupted: true)
                    self?.problem = error.localizedDescription
                }
            }
            try capture.start()
            self.capture = capture
            startedAt = now
        } catch {
            problem = error.localizedDescription
        }
    }

    @discardableResult
    func finish(interrupted: Bool = false) async -> Night? {
        guard let capture, !isBusy else { return nil }
        isBusy = true
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
        guard notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            == AVAudioSession.InterruptionType.began.rawValue else { return }
        stopPlayback()
        await finish(interrupted: true)
    }

    func handleEngineChange(_ notification: Notification) async {
        guard capture?.lostInput(notification) == true else { return }
        await finish(interrupted: true)
    }

    func analyze(_ id: UUID) {
        guard analyzingID == nil, capture == nil, !isBusy,
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
        guard analyzingID != night.id else { return }
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
        guard !isSampleNight(night.id), capture == nil, !isBusy, let archive else { return }
        let alreadyPlaying = playingID == clip.id
        stopPlayback()
        guard !alreadyPlaying else { return }
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playback, mode: .default)
            try audio.setActive(true)
            let player = try AVAudioPlayer(contentsOf: archive.clipURL(clip, in: night))
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
        return archive?.clipURL(clip, in: night)
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
