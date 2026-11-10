import Foundation

/// Find the same per-embedder filename family Core writes, without making each
/// QA command keep its own list of database filenames.
struct SpeakerDatabaseArtifact {
    let url: URL

    var identifier: String? {
        let stem = url.deletingPathExtension().lastPathComponent
        return stem == "speakers" ? nil : String(stem.dropFirst("speakers_".count))
    }

    var displayName: String {
        switch identifier {
        case nil: return "WeSpeaker"
        case "eres2net": return "ERes2Net"
        case "redimnet2-b4": return "ReDimNet2"
        case let identifier?: return identifier
        }
    }

    var embeddingByteCount: Int? {
        switch identifier {
        case nil: return 256 * MemoryLayout<Float>.size
        case "eres2net", "redimnet2-b4": return 192 * MemoryLayout<Float>.size
        default: return nil
        }
    }

    static func existing(in directory: URL) throws -> [Self] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
            .filter {
                let name = $0.lastPathComponent
                return (name == "speakers.sqlite" || (name.hasPrefix("speakers_") && $0.pathExtension == "sqlite"))
                    && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { Self(url: $0) }
    }
}
