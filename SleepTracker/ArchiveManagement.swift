// Audio cleanup keeps session metadata. Export snapshots it alongside optional recordings.
import Foundation

private struct ExportedNight: Encodable {
    let night: Night
    let audioFileIDs: [String: String]

    private enum CodingKeys: String, CodingKey { case audioFileIDs }

    func encode(to encoder: Encoder) throws {
        try night.encode(to: encoder)
        var metadata = encoder.container(keyedBy: CodingKeys.self)
        try metadata.encode(audioFileIDs, forKey: .audioFileIDs)
    }
}

extension NightArchive {
    private func audioFiles(in night: Night) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: folder(night.id), includingPropertiesForKeys: [.fileSizeKey])
            .filter { Self.audioExtensions.contains($0.pathExtension) }
    }

    func measureAudio(_ nights: [Night], removingBefore cutoff: Date?) throws -> Int64 {
        var bytes: Int64 = 0
        for night in nights {
            let expired = cutoff.map { night.isComplete && !night.needsAnalysis && night.endedAt <= $0 } ?? false
            for url in try audioFiles(in: night) {
                if expired {
                    try FileManager.default.removeItem(at: url)
                } else {
                    bytes += Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
                }
            }
        }
        return bytes
    }

    func export(_ nights: [Night], audio: Bool) throws -> URL {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = temp.appendingPathComponent("Sleep tracker", isDirectory: true)
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .custom { date, encoder in
                var value = encoder.singleValueContainer()
                try value.encode(date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            }
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let folderDate = Self.exportFormatter("yyyy-MM-dd HH-mm")
            let clipTime = Self.exportFormatter("HH-mm-ss")
            for night in nights {
                let destination = Self.availableURL(in: source, name: folderDate.string(from: night.startedAt))
                try fm.createDirectory(at: destination, withIntermediateDirectories: true)
                let ids = audio ? try exportAudio(in: night, to: destination, clock: clipTime) : [:]
                let metadata = ExportedNight(night: night, audioFileIDs: ids)
                try encoder.encode(metadata).write(to: destination.appendingPathComponent("night.json"))
            }
            return source
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }

    private func exportAudio(in night: Night, to directory: URL, clock: DateFormatter) throws -> [String: String] {
        var names = [String: String]()
        for clip in night.pendingClips ?? [] {
            names[clip.id.uuidString] = "Pending clip \(clock.string(from: clip.startedAt))"
        }
        for clip in night.clips {
            let label = clip.soundTitle.isEmpty ? "Clip" : clip.soundTitle
            names[clip.id.uuidString] = "\(label) \(clock.string(from: clip.startedAt))"
        }
        names[night.id.uuidString] = "Full recording"

        var ids = [String: String]()
        for file in try audioFiles(in: night).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let id = file.deletingPathExtension().lastPathComponent
            let url = Self.availableURL(in: directory, name: names[id] ?? "Audio", ext: file.pathExtension)
            try FileManager.default.linkItem(at: file, to: url)
            ids[url.lastPathComponent] = id
        }
        return ids
    }

    private static func exportFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = format
        return formatter
    }

    private static func availableURL(in directory: URL, name: String, ext: String? = nil) -> URL {
        var number = 1
        while true {
            let stem = number == 1 ? name : "\(name) (\(number))"
            let filename = ext.map { "\(stem).\($0)" } ?? stem
            let url = directory.appendingPathComponent(filename, isDirectory: ext == nil)
            if !FileManager.default.fileExists(atPath: url.path) { return url }
            number += 1
        }
    }
}
