import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

enum MeetingStarError: Error, Equatable, LocalizedError {
    case notOwnedMeeting
    case readFailed
    case writeFailed
    case retranscriptionInProgress

    var errorDescription: String? {
        switch self {
        case .notOwnedMeeting:
            return "Only meetings saved by Transcripted can be starred."
        case .readFailed:
            return "The meeting transcript could not be read."
        case .writeFailed:
            return "The meeting transcript could not be updated."
        case .retranscriptionInProgress:
            return "That meeting is being re-transcribed. Try again when it finishes."
        }
    }
}

/// A saved meeting's star: one `starred: true` line in its Markdown
/// frontmatter. Living in the file keeps it agent-readable and lets it move
/// with the capture library. Automatic meeting-audio deletion
/// (`MeetingAudioStorageManager.pruneRetainedAudio`) skips starred meetings.
///
/// Writes go through `MeetingTranscriptFileUpdateSerializer`, like title
/// renames, so a star can't be lost to a concurrent restyle or speaker edit.
/// Re-transcribing rebuilds the file from scratch; Core's replacement save
/// (`TranscriptSaver.saveTranscript(targetURL:)`) reads the star from the file
/// it overwrites, under the same serializer, and writes it into the new one.
enum MeetingStarFrontmatter {
    static let key = TranscriptFrontmatter.starredKey

    static func isStarred(values: [String: String]) -> Bool {
        TranscriptFrontmatter.isStarred(values: values)
    }

    /// The same Markdown with the star set or cleared, or nil when it has no
    /// frontmatter. Starring replaces an existing unindented `starred:` line
    /// in place, or adds `starred: true` as the last frontmatter line;
    /// unstarring removes every unindented `starred:` line. Nothing else in
    /// the file changes.
    static func rewrite(_ raw: String, starred: Bool) -> String? {
        let openingFence = "---\n"
        guard raw.hasPrefix(openingFence) else { return nil }
        let frontmatterStart = raw.index(raw.startIndex, offsetBy: openingFence.count)
        guard let closingFence = raw.range(of: "\n---\n", range: frontmatterStart..<raw.endIndex) else {
            return nil
        }

        var lines = raw[frontmatterStart..<closingFence.lowerBound].components(separatedBy: "\n")
        let starLine = "\(key): true"
        if starred {
            if let first = lines.firstIndex(where: isStarKeyLine) {
                lines[first] = starLine
                lines = lines.enumerated()
                    .filter { $0.offset == first || !isStarKeyLine($0.element) }
                    .map(\.element)
            } else {
                lines.append(starLine)
            }
        } else {
            lines.removeAll(where: isStarKeyLine)
        }

        return openingFence + lines.joined(separator: "\n") + String(raw[closingFence.lowerBound...])
    }

    /// Stars or unstars the meeting saved at `url`. Only app-owned meetings
    /// (`capture_type: meeting` plus a UUID id) can be starred.
    static func setStarred(
        _ starred: Bool,
        transcriptAt url: URL,
        fileManager: FileManager = .default
    ) throws {
        do {
            try MeetingTranscriptFileUpdateSerializer.sync(protecting: [url]) {
                try setStarredSerialized(starred, transcriptAt: url, fileManager: fileManager)
            }
        } catch MeetingTranscriptFileUpdateError.replacementInProgress {
            throw MeetingStarError.retranscriptionInProgress
        }
    }

    private static func setStarredSerialized(
        _ starred: Bool,
        transcriptAt url: URL,
        fileManager: FileManager
    ) throws {
        guard isAppOwnedMeeting(url, fileManager: fileManager) else {
            throw MeetingStarError.notOwnedMeeting
        }
        let raw: String
        do {
            raw = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw MeetingStarError.readFailed
        }
        guard let rewritten = rewrite(raw, starred: starred) else {
            throw MeetingStarError.notOwnedMeeting
        }
        guard rewritten != raw else { return }
        do {
            try TranscriptFileRewrite.write(rewritten, to: url, fileManager: fileManager)
            fileManager.restrictFileToOwnerOnly(at: url)
        } catch {
            throw MeetingStarError.writeFailed
        }
    }

    private static func isStarKeyLine(_ line: String) -> Bool {
        guard line.first?.isWhitespace != true,
              let colon = line.firstIndex(of: ":") else { return false }
        return line[..<colon].trimmingCharacters(in: .whitespaces) == key
    }

    private static func isAppOwnedMeeting(_ url: URL, fileManager: FileManager) -> Bool {
        guard fileManager.fileExists(atPath: url.path),
              let values = try? TranscriptFrontmatter.readValues(from: url),
              values["capture_type"]?.lowercased() == "meeting" else {
            return false
        }
        return isUUID(values["transcript_id"]) || isUUID(values["capture_id"])
    }

    private static func isUUID(_ value: String?) -> Bool {
        value.flatMap(UUID.init(uuidString:)) != nil
    }
}
