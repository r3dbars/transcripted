import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

enum MeetingStarError: Error, Equatable, LocalizedError {
    case notOwnedMeeting
    case readFailed
    case writeFailed
    case retranscriptionInProgress
    case currentLibraryUnavailable
    case identityUnresolved

    var errorDescription: String? {
        switch self {
        case .notOwnedMeeting:
            return "Only meetings saved by Transcripted can be starred."
        case .readFailed:
            return "The meeting transcript could not be read."
        case .writeFailed:
            return "The meeting transcript could not be updated."
        case .currentLibraryUnavailable:
            return "The current capture library is unavailable or read-only."
        case .identityUnresolved:
            return "That meeting moved or its identity is ambiguous. Refresh and try again."
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

    /// Stars the uniquely identified capture in the current authorized library.
    /// The cached URL is a hint only; it never authorizes the file now at that name.
    @discardableResult
    static func setStarred(
        _ starred: Bool,
        transcriptAt url: URL,
        expectedCaptureID: UUID,
        authorizedDirectory: @Sendable () -> URL?,
        fileManager: FileManager = .default
    ) throws -> URL {
        do {
            return try MeetingTranscriptFileUpdateSerializer.sync {
                // Resolve authority at execution, not when a cached row was built.
                guard let directory = authorizedDirectory(),
                      let properties = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      properties.isDirectory == true, properties.isSymbolicLink != true,
                      fileManager.isReadableFile(atPath: directory.path),
                      fileManager.isWritableFile(atPath: directory.path) else {
                    throw MeetingStarError.currentLibraryUnavailable
                }
                let resolved = try resolveCapture(expectedCaptureID, in: directory, fileManager: fileManager)
                return try MeetingTranscriptFileUpdateSerializer.sync(protecting: [resolved]) {
                    try setStarredSerialized(starred, transcriptAt: resolved, expectedCaptureID: expectedCaptureID, fileManager: fileManager)
                    return resolved
                }
            }
        } catch MeetingTranscriptFileUpdateError.replacementInProgress {
            throw MeetingStarError.retranscriptionInProgress
        }
    }

    /// One flat scan inside the currently authorized meetings folder only.
    /// A stale path never grants authority over whichever capture replaced it.
    private static func resolveCapture(_ id: UUID, in directory: URL, fileManager: FileManager) throws -> URL {
        let files: [URL]
        do {
            files = try fileManager.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
        } catch { throw MeetingStarError.currentLibraryUnavailable }
        var match: URL?
        for file in files where file.pathExtension.lowercased() == "md" {
            guard let properties = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
                throw MeetingStarError.readFailed
            }
            guard properties.isRegularFile == true, properties.isSymbolicLink != true else { continue }
            let values: [String: String]?
            do { values = try TranscriptFrontmatter.readValues(from: file) }
            catch { throw MeetingStarError.readFailed }
            guard let values, values["capture_type"]?.lowercased() == "meeting",
                  TranscriptFrontmatter.captureID(in: values) == id else { continue }
            guard match == nil, fileManager.isWritableFile(atPath: file.path) else {
                throw MeetingStarError.identityUnresolved
            }
            match = directory.appendingPathComponent(file.lastPathComponent)
        }
        guard let match else { throw MeetingStarError.identityUnresolved }
        return match
    }

    private static func setStarredSerialized(
        _ starred: Bool,
        transcriptAt url: URL,
        expectedCaptureID: UUID,
        fileManager: FileManager
    ) throws {
        guard let properties = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              properties.isRegularFile == true, properties.isSymbolicLink != true else {
            throw MeetingStarError.identityUnresolved
        }
        let raw: String
        do {
            raw = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw MeetingStarError.readFailed
        }
        guard let values = TranscriptFrontmatter.values(in: raw),
              values["capture_type"]?.lowercased() == "meeting",
              TranscriptFrontmatter.captureID(in: values) == expectedCaptureID else {
            throw MeetingStarError.identityUnresolved
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
}
