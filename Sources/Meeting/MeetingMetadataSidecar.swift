import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

/// Hidden pipeline metadata for one meeting:
/// `<meetings folder>/.meta/<capture_id>.json`.
///
/// The `format_version: 2` restyle moves engine and diagnostic keys
/// (`processing_time`, `transcription_engine`, healthy capture defaults, raw
/// gap events, ...) out of the Markdown and into this file, keyed by the
/// capture id so a title rename never orphans it. It holds no transcript
/// text, titles or names. Writes are best effort: a failure never fails the
/// transcript save. See docs/capture-format.md.
enum MeetingMetadataSidecar {
    static let directoryName = ".meta"
    static let schemaVersion = 1

    enum Value: Equatable, Codable {
        case string(String)
        case list([String])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let list = try? container.decode([String].self) {
                self = .list(list)
            } else {
                self = .string(try container.decode(String.self))
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let value): try container.encode(value)
            case .list(let values): try container.encode(values)
            }
        }
    }

    struct Payload: Equatable, Codable {
        var schemaVersion: Int
        var captureID: String
        var frontmatter: [String: Value]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case captureID = "capture_id"
            case frontmatter
        }
    }

    static func url(forTranscript transcriptURL: URL, captureID: UUID) -> URL {
        transcriptURL.deletingLastPathComponent()
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent("\(captureID.uuidString).json")
    }

    static func read(forTranscript transcriptURL: URL, captureID: UUID) -> Payload? {
        let url = url(forTranscript: transcriptURL, captureID: captureID)
        guard isRegularFile(url), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Payload.self, from: data)
    }

    /// Merges `values` into the meeting's sidecar (newer values win), so a
    /// second restyle with nothing left to move keeps what the first one
    /// wrote. Returns false (and logs) instead of throwing.
    @discardableResult
    static func merge(
        _ values: [String: Value],
        forTranscript transcriptURL: URL,
        captureID: UUID,
        fileManager: FileManager = .default
    ) -> Bool {
        guard !values.isEmpty else { return true }
        let directory = transcriptURL.deletingLastPathComponent()
            .appendingPathComponent(directoryName, isDirectory: true)
        let url = url(forTranscript: transcriptURL, captureID: captureID)
        do {
            if !isDirectory(directory) {
                // A symlink or file in the way is not ours to replace.
                guard (try? fileManager.destinationOfSymbolicLink(atPath: directory.path)) == nil,
                      !fileManager.fileExists(atPath: directory.path) else {
                    logFailure("meeting_metadata_sidecar_blocked")
                    return false
                }
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            var payload = read(forTranscript: transcriptURL, captureID: captureID)
                ?? Payload(schemaVersion: schemaVersion, captureID: captureID.uuidString, frontmatter: [:])
            payload.schemaVersion = schemaVersion
            payload.captureID = captureID.uuidString
            payload.frontmatter.merge(values) { _, new in new }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(payload)
            if (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil {
                logFailure("meeting_metadata_sidecar_blocked")
                return false
            }
            try data.write(to: url, options: [.atomic])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            logFailure("meeting_metadata_sidecar_write_failed")
            return false
        }
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values?.isRegularFile == true && values?.isSymbolicLink != true
    }

    private static func isDirectory(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values?.isDirectory == true && values?.isSymbolicLink != true
    }

    /// No paths or ids: the event name is the whole message.
    private static func logFailure(_ event: String) {
        fputs("⚠️ MEETING | \(event) | Meeting metadata sidecar not written\n", stderr)
    }
}
