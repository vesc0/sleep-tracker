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

    var activeClips: [SoundClip] { clips.filter { $0.isDismissed != true } }

    var needsAnalysis: Bool { !(pendingClips ?? []).isEmpty }

    var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }

    var analysisProgress: Double {
        guard needsAnalysis, duration > 0 else { return needsAnalysis ? 0 : 1 }
        // Pending audio remains in the archive across pauses and retries.
        let remaining = pendingClips?.reduce(0) { $0 + $1.duration } ?? 0
        return min(0.99, max(0, 1 - remaining / duration))
    }
}

struct NightArchive {
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
        clipURL(clip.id, in: night.id)
    }

    func clipURL(_ clipID: UUID, in nightID: UUID) -> URL {
        folder(nightID).appendingPathComponent(clipID.uuidString).appendingPathExtension("caf")
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
                let retained = Set((night.clips + (night.pendingClips ?? [])).map { clipURL($0, in: night).lastPathComponent })
                for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                where url.pathExtension == "caf" && !retained.contains(url.lastPathComponent) {
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
