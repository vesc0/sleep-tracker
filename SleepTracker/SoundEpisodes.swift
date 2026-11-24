// Classification windows locate detected audio within each saved clip.
import Foundation

struct SoundWindow: Codable {
    let sound: NightSound
    let start: Double
    let end: Double
}

struct RecordingLevel: Codable {
    let start: Date
    let duration: Double
    let power: Double
    let peak: Double

    // Floor digital silence so labels and chart coordinates stay finite.
    static func decibels(_ power: Double) -> Double { 10 * log10(max(1e-12, power)) }

    static func average(_ levels: [Self]) -> Double {
        let duration = levels.reduce(0) { $0 + $1.duration }
        return decibels(levels.reduce(0) { $0 + $1.power * $1.duration } / max(duration, 1e-12))
    }

    static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        decibels(sorted[Int(Double(sorted.count - 1) * fraction)])
    }
}

struct SoundEpisode: Identifiable {
    let sound: NightSound
    let start: Date
    var end: Date
    var clips: [SoundClip]
    var detectedDuration: Double
    var id: String { "\(sound.rawValue)-\(start.timeIntervalSinceReferenceDate)" }
    var duration: Double { end.timeIntervalSince(start) }
}

extension Night {
    var episodes: [SoundEpisode] {
        let clips = activeClips.sorted { $0.startedAt < $1.startedAt }
        var episodes: [SoundEpisode] = []
        for sound in NightSound.allCases {
            // Initial gap allowances accommodate breaths, pauses in speech, and cough clusters.
            let gap: Double = switch sound { case .snoring: 12; case .speech: 4; case .cough: 3 }
            var current: SoundEpisode?
            for clip in clips where clip.labels.contains(sound) {
                var windows = clip.windows?.filter { $0.sound == sound } ?? []
                // Legacy and manually added labels have clip-level timing only.
                if windows.isEmpty { windows = [.init(sound: sound, start: 0, end: clip.duration)] }
                for window in windows.sorted(by: { $0.start < $1.start }) {
                    let start = clip.startedAt.addingTimeInterval(max(0, window.start))
                    let end = clip.startedAt.addingTimeInterval(min(clip.duration, window.end))
                    guard end > start else { continue }
                    if let previousEnd = current?.end, start.timeIntervalSince(previousEnd) <= gap {
                        // Count overlapping evidence once and exclude pauses from sound totals.
                        current?.detectedDuration += max(0, end.timeIntervalSince(max(previousEnd, start)))
                        current?.end = max(previousEnd, end)
                        if current?.clips.last?.id != clip.id { current?.clips.append(clip) }
                    } else {
                        if let current { episodes.append(current) }
                        current = SoundEpisode(sound: sound, start: start, end: end, clips: [clip],
                                               detectedDuration: end.timeIntervalSince(start))
                    }
                }
            }
            if let current { episodes.append(current) }
        }
        return episodes.sorted { $0.start < $1.start }
    }
}
