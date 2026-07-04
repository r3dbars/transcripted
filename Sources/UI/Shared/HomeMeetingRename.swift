import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

struct HomeMeetingRenameResult: Equatable {
    let transcriptURL: URL
    let title: String
}

enum HomeMeetingRenameError: Error, Equatable {
    /// The new title was empty after normalization — callers should treat this as a cancel.
    case emptyTitle
    /// The transcript is not an app-owned meeting, so its filename is not ours to rewrite.
    case notOwnedMeeting
    case readFailed
    case writeFailed
}

/// Renames a saved meeting from the Home preview's editable title.
///
/// Rewrites the `title:` frontmatter value and the body `# ` heading, then moves the
/// Markdown file, retained `audio/<stem>_audio/` directory, and `<stem>.summary.md`
/// sidecar to the canonical `YYYY-MM-dd <title>` stem via `MeetingArtifactRenamer` —
/// the same mechanics the post-save restyle uses, so the two paths cannot drift.
///
/// Conservative by design: it only touches transcripts whose frontmatter marks them as
/// app-owned meetings (`capture_type: meeting` plus a valid identifier).
enum HomeMeetingRename {
    @discardableResult
    static func rename(
        transcriptAt url: URL,
        to rawTitle: String,
        fileManager: FileManager = .default
    ) throws -> HomeMeetingRenameResult {
        try MeetingTranscriptFileUpdateSerializer.sync {
            try renameSerialized(transcriptAt: url, to: rawTitle, fileManager: fileManager)
        }
    }

    private static func renameSerialized(
        transcriptAt url: URL,
        to rawTitle: String,
        fileManager: FileManager
    ) throws -> HomeMeetingRenameResult {
        guard let normalizedTitle = MeetingRecordingTitlePolicy.normalized(rawTitle) else {
            throw HomeMeetingRenameError.emptyTitle
        }
        guard let values = appOwnedMeetingValues(url, fileManager: fileManager) else {
            throw HomeMeetingRenameError.notOwnedMeeting
        }

        let raw: String
        do {
            raw = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw HomeMeetingRenameError.readFailed
        }

        let rewritten = rewriteTitle(in: raw, to: normalizedTitle)
        if rewritten != raw {
            do {
                try rewritten.write(to: url, atomically: true, encoding: .utf8)
                fileManager.restrictFileToOwnerOnly(at: url)
            } catch {
                throw HomeMeetingRenameError.writeFailed
            }
        }

        let recordedAt = TranscriptFrontmatter.recordedAt(values: values)
            ?? TranscriptFrontmatter.date(values: values)
            ?? creationDate(of: url, fileManager: fileManager)
            ?? Date()

        let preferredStem = MeetingArtifactRenamer.fileStem(
            date: recordedAt,
            title: normalizedTitle,
            fallback: url.deletingPathExtension().lastPathComponent
        )
        let finalURL = MeetingArtifactRenamer.rename(
            transcriptAt: url,
            toStem: preferredStem,
            fileManager: fileManager
        )

        return HomeMeetingRenameResult(transcriptURL: finalURL, title: normalizedTitle)
    }

    // MARK: - Frontmatter / heading rewrite

    /// Replace the `title:` frontmatter value and the first body `# ` heading. If the
    /// frontmatter has no `title:` line, one is inserted right after the opening `---`.
    static func rewriteTitle(in raw: String, to title: String) -> String {
        let escapedTitle = title.replacingOccurrences(of: "\"", with: "'")
        var lines = raw.components(separatedBy: "\n")

        var openingFenceIndex: Int?
        var inFrontmatter = false
        var frontmatterClosed = false
        var didReplaceTitle = false
        var didReplaceHeading = false

        for index in lines.indices {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)

            if trimmed == "---" {
                if openingFenceIndex == nil {
                    openingFenceIndex = index
                    inFrontmatter = true
                } else if inFrontmatter {
                    inFrontmatter = false
                    frontmatterClosed = true
                }
                continue
            }

            if inFrontmatter {
                if !didReplaceTitle, trimmed.hasPrefix("title:") {
                    lines[index] = "title: \"\(escapedTitle)\""
                    didReplaceTitle = true
                }
            } else if frontmatterClosed, !didReplaceHeading, trimmed.hasPrefix("# ") {
                lines[index] = "# \(title)"
                didReplaceHeading = true
            }
        }

        if !didReplaceTitle, let openingFenceIndex {
            lines.insert("title: \"\(escapedTitle)\"", at: openingFenceIndex + 1)
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Ownership

    private static func appOwnedMeetingValues(
        _ url: URL,
        fileManager: FileManager
    ) -> [String: String]? {
        guard fileManager.fileExists(atPath: url.path),
              let values = try? TranscriptFrontmatter.readValues(from: url),
              values["capture_type"]?.lowercased() == "meeting",
              isValidIdentifier(values["transcript_id"]) || isValidIdentifier(values["capture_id"]) else {
            return nil
        }
        return values
    }

    private static func isValidIdentifier(_ value: String?) -> Bool {
        guard let value else { return false }
        return UUID(uuidString: value) != nil
    }

    private static func creationDate(of url: URL, fileManager: FileManager) -> Date? {
        let resourceValues = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return resourceValues?.creationDate ?? resourceValues?.contentModificationDate
    }
}
