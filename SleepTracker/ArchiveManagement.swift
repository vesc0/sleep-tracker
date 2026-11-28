// Audio cleanup keeps session metadata. Export snapshots it alongside optional recordings.
import Foundation

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
                try value.encode(date.formatted(.iso8601.time(includingFractionalSeconds: true)))
            }
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            for night in nights {
                let destination = source.appendingPathComponent(night.id.uuidString, isDirectory: true)
                try fm.createDirectory(at: destination, withIntermediateDirectories: true)
                try encoder.encode(night).write(to: destination.appendingPathComponent("night.json"))
                if audio {
                    for file in try audioFiles(in: night) {
                        let name = file.deletingPathExtension().lastPathComponent == night.id.uuidString ? "Full recording.\(file.pathExtension)" : file.lastPathComponent
                        try fm.linkItem(at: file, to: destination.appendingPathComponent(name))
                    }
                }
            }
            return source
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }
}
