// Night and SoundClip describe sessions and audio segments.
// NightArchive saves sessions on the device and recovers interrupted recordings.

import Foundation

enum NightSound: String, Codable, CaseIterable {
    case snoring
    case speech
    case cough

    var title: String {
        switch self {
        case .snoring: "Snoring"
        case .speech: "Sleep talking"
        case .cough: "Coughing"
        }
    }
}

struct SoundClip: Codable, Identifiable {
    let id: UUID
    let startedAt: Date
    let duration: TimeInterval
    var sounds: [NightSound]?
    var windows: [SoundWindow]?
    var isDismissed: Bool?

    var labels: [NightSound] { sounds ?? [.snoring] }

    // Saved clips from earlier versions were all labeled as snoring.
    var soundTitle: String {
        labels.map(\.title).joined(separator: " · ")
    }
}

enum NightTag: String, Codable, CaseIterable, Identifiable {
    case lateCaffeine = "Late caffeine"
    case congestion = "Congestion"
    case sideSleeping = "Side sleeping"
    case backSleeping = "Back sleeping"
    case stomachSleeping = "Stomach sleeping"

    var id: Self { self }
}

struct NightCheckIn: Codable {
    var restedRating: Int?
    var notes = ""
    var tags: Set<NightTag> = []
}

enum RecordingQuality: String, CaseIterable, Codable {
    case compact, standard, high, pcm16, pcm44

    var title: String {
        switch self {
        case .compact: "Compact (AAC 32 kbps)"
        case .standard: "Standard (AAC 64 kbps)"
        case .high: "High (AAC 128 kbps)"
        case .pcm16: "Raw (PCM 16 kHz)"
        case .pcm44: "Raw (PCM 44.1 kHz)"
        }
    }

    var sampleRate: Double { self == .pcm16 ? 16_000 : 44_100 }

    var aacBitRate: Int? {
        switch self {
        case .compact: 32_000
        case .standard: 64_000
        case .high: 128_000
        case .pcm16, .pcm44: nil
        }
    }

    var megabytesPerHour: Int {
        let bitsPerSecond = aacBitRate ?? Int(sampleRate) * 16
        return Int((Double(bitsPerSecond) * 3600 / 8_000_000).rounded())
    }

    static func preferred(in defaults: UserDefaults = .standard) -> Self {
        if let raw = defaults.string(forKey: "recordingQuality"), let quality = Self(rawValue: raw) {
            return quality
        }
        if let legacyHigh = defaults.object(forKey: "highQualityAudio") as? Bool {
            return legacyHigh ? .pcm44 : .pcm16
        }
        return .standard
    }
}

struct RecordingOptions: Codable {
    let quality: RecordingQuality?
    let sounds: [NightSound]
    let sampleRate: Double
    let keepFullAudio: Bool
    let autoResume: Bool

    init(defaults: UserDefaults = .standard) {
        sounds = NightSound.allCases.filter { defaults.object(forKey: "detect." + $0.rawValue) as? Bool ?? true }
        let selected = RecordingQuality.preferred(in: defaults)
        quality = selected
        sampleRate = selected.sampleRate
        keepFullAudio = defaults.bool(forKey: "keepFullAudio")
        autoResume = defaults.object(forKey: "autoResume") as? Bool ?? true
    }
}

struct RecordingGap: Codable {
    let start: Date
    var end: Date?
    let reason: String
}

struct Night: Codable, Identifiable {
    let id: UUID
    let startedAt: Date
    var endedAt: Date
    var isComplete = false
    var wasInterrupted = false
    var clips: [SoundClip] = []
    // Older session files omit this field.
    var pendingClips: [SoundClip]?

    var checkIn: NightCheckIn?
    var levels: [RecordingLevel]?
    var options: RecordingOptions?
    var gaps: [RecordingGap]?

    var fullRecording: SoundClip? {
        guard options?.keepFullAudio == true else { return nil }
        return SoundClip(id: id, startedAt: startedAt, duration: duration, sounds: [])
    }

    var activeClips: [SoundClip] { clips.filter { $0.isDismissed != true } }

    var needsAnalysis: Bool { !(pendingClips ?? []).isEmpty }

    var elapsed: TimeInterval { endedAt.timeIntervalSince(startedAt) }

    var duration: TimeInterval {
        let paused = (gaps ?? []).reduce(0) { $0 + ($1.end ?? endedAt).timeIntervalSince($1.start) }
        return max(0, elapsed - paused)
    }

    var analysisProgress: Double {
        guard needsAnalysis, duration > 0 else { return needsAnalysis ? 0 : 1 }
        // Pending audio remains in the archive across pauses and retries.
        let remaining = pendingClips?.reduce(0) { $0 + $1.duration } ?? 0
        return min(0.99, max(0, 1 - remaining / duration))
    }
}

struct NightArchive {
    static let audioExtensions: Set<String> = ["caf", "m4a"]
    let root: URL
    private static let protection = FileProtectionType.completeUntilFirstUserAuthentication

    init() throws {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        var folder = support.appendingPathComponent("SleepTracker", isDirectory: true)
        try Self.prepareDirectory(folder)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        root = folder
    }

    func folder(_ id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func clipURL(_ clip: SoundClip, in night: Night) -> URL {
        clipURL(clip.id, in: night)
    }

    func clipURL(_ clipID: UUID, in night: Night) -> URL {
        let ext = night.options?.quality?.aacBitRate == nil ? "caf" : "m4a"
        return folder(night.id).appendingPathComponent(clipID.uuidString).appendingPathExtension(ext)
    }

    func begin(_ night: Night) throws {
        try Self.prepareDirectory(folder(night.id))
        try save(night)
    }

    private static func prepareDirectory(_ directory: URL) throws {
        let attributes: [FileAttributeKey: Any] = [.protectionKey: protection]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: attributes)
        // An existing directory keeps its previous protection when createDirectory succeeds.
        try FileManager.default.setAttributes(attributes, ofItemAtPath: directory.path)
    }

    func save(_ night: Night) throws {
        let directory = folder(night.id)
        try JSONEncoder().encode(night).write(
            to: directory.appendingPathComponent("night.json"),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    func load() throws -> [Night] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
            .compactMap { directory -> Night? in
                let metadata = directory.appendingPathComponent("night.json")
                guard FileManager.default.fileExists(atPath: metadata.path) else { return nil }
                var night = try JSONDecoder().decode(Night.self, from: Data(contentsOf: metadata))
                // Recover the last checkpoint if recording ended before finalization.
                if !night.isComplete {
                    night.isComplete = true
                    night.wasInterrupted = true
                    try save(night)
                }
                var retained = Set((night.clips + (night.pendingClips ?? [])).map { clipURL($0, in: night).lastPathComponent })
                if let full = night.fullRecording { retained.insert(clipURL(full, in: night).lastPathComponent) }
                for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                where Self.audioExtensions.contains(url.pathExtension) && !retained.contains(url.lastPathComponent) {
                    try FileManager.default.removeItem(at: url)
                }
                return night
            }
            .sorted { $0.startedAt > $1.startedAt }
    }

    func delete(_ night: Night) throws {
        try FileManager.default.removeItem(at: folder(night.id))
    }
}
