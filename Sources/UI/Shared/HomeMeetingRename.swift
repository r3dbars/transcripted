import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

struct HomeMeetingRenameResult: Equatable {
    let transcriptURL: URL
    let title: String
}

enum HomeMeetingSpeakerRenameError: Error, Equatable, LocalizedError {
    case emptyName
    case speakerNotFound
    case ambiguousSpeaker
    case readFailed
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .emptyName:
            return "Enter a speaker name."
        case .speakerNotFound:
            return "That speaker label changed before the rename could be saved."
        case .ambiguousSpeaker:
            return "Two different voices use the same transcript label, so Transcripted left them unchanged."
        case .readFailed:
            return "The meeting transcript could not be read."
        case .writeFailed:
            return "The meeting transcript could not be updated."
        }
    }
}

/// Transcript-scoped fallback for older meetings that do not have a saved
/// speaker profile. Identified speakers use `SpeakerIdentityMutationService`
/// through the Settings view model instead, so the database and every linked
/// transcript stay in sync.
enum HomeMeetingSpeakerRename {
    @discardableResult
    static func rename(
        transcriptAt url: URL,
        identity: HomeMeetingSpeakerIdentity,
        to rawName: String,
        linkingTo targetProfileID: UUID? = nil,
        fileManager: FileManager = .default
    ) throws -> String {
        let assignment = HomeMeetingSpeakerAssignment(
            identity: identity,
            newName: rawName,
            targetProfileID: targetProfileID
        )
        return try renameMany(
            transcriptAt: url,
            assignments: [assignment],
            fileManager: fileManager
        ).first ?? rawName
    }

    /// Applies every transcript-local correction against one snapshot and
    /// writes once. Placeholder tokens prevent cascading replacements when,
    /// for example, Alex becomes Jordan while Jordan becomes Morgan.
    @discardableResult
    static func renameMany(
        transcriptAt url: URL,
        assignments: [HomeMeetingSpeakerAssignment],
        fileManager: FileManager = .default
    ) throws -> [String] {
        try MeetingTranscriptFileUpdateSerializer.sync {
            let normalizedAssignments = try assignments.map { assignment -> HomeMeetingSpeakerAssignment in
                guard let name = normalizedName(assignment.newName) else {
                    throw HomeMeetingSpeakerRenameError.emptyName
                }
                return HomeMeetingSpeakerAssignment(
                    identity: assignment.identity,
                    newName: name,
                    targetProfileID: assignment.targetProfileID,
                    removesPersistentSpeakerLink: assignment.removesPersistentSpeakerLink
                )
            }
            guard !normalizedAssignments.isEmpty else { return [] }

            let raw: String
            do {
                raw = try String(contentsOf: url, encoding: .utf8)
            } catch {
                throw HomeMeetingSpeakerRenameError.readFailed
            }

            var lines = raw.components(separatedBy: "\n")
            var metadataChangedByID: [String: Bool] = [:]
            var replacements: [String: String] = [:]

            for assignment in normalizedAssignments {
                let oldToken = "[\(assignment.identity.rawLabel)]"
                let newRawLabel = replacementRawLabel(
                    for: assignment.identity,
                    newName: assignment.newName
                )
                let newToken = "[\(newRawLabel)]"
                if let existing = replacements[oldToken], existing != newToken {
                    throw HomeMeetingSpeakerRenameError.ambiguousSpeaker
                }
                replacements[oldToken] = newToken
                metadataChangedByID[assignment.identity.stableID] = rewriteFrontmatterSpeaker(
                    in: &lines,
                    identity: assignment.identity,
                    newName: assignment.newName,
                    targetProfileID: assignment.targetProfileID,
                    removesPersistentSpeakerLink: assignment.removesPersistentSpeakerLink
                )
            }

            var rewritten = lines.joined(separator: "\n")
            var placeholders: [(token: String, replacement: String)] = []
            var bodyChangedTokens: Set<String> = []
            for (offset, pair) in replacements.sorted(by: { $0.key < $1.key }).enumerated() {
                guard rewritten.contains(pair.key) else { continue }
                let placeholder = "[TRANSCRIPTED_SPEAKER_RENAME_\(offset)_\(UUID().uuidString)]"
                rewritten = rewritten.replacingOccurrences(of: pair.key, with: placeholder)
                placeholders.append((placeholder, pair.value))
                bodyChangedTokens.insert(pair.key)
            }
            for placeholder in placeholders {
                rewritten = rewritten.replacingOccurrences(
                    of: placeholder.token,
                    with: placeholder.replacement
                )
            }

            for assignment in normalizedAssignments {
                let oldToken = "[\(assignment.identity.rawLabel)]"
                let metadataChanged = metadataChangedByID[assignment.identity.stableID] ?? false
                guard metadataChanged || bodyChangedTokens.contains(oldToken) else {
                    throw HomeMeetingSpeakerRenameError.speakerNotFound
                }
            }

            do {
                try rewritten.write(to: url, atomically: true, encoding: .utf8)
                fileManager.restrictFileToOwnerOnly(at: url)
            } catch {
                throw HomeMeetingSpeakerRenameError.writeFailed
            }
            return normalizedAssignments.map(\.newName)
        }
    }

    private static func normalizedName(_ raw: String) -> String? {
        let normalized = raw
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return normalized.isEmpty ? nil : normalized
    }

    private static func replacementRawLabel(
        for identity: HomeMeetingSpeakerIdentity,
        newName: String
    ) -> String {
        guard let slash = identity.rawLabel.firstIndex(of: "/") else {
            let linked = identity.rawLabel.hasPrefix("[[") && identity.rawLabel.hasSuffix("]]")
            return linked ? "[[\(newName)]]" : newName
        }

        let prefix = identity.rawLabel[...slash]
        let oldName = identity.rawLabel[identity.rawLabel.index(after: slash)...]
        let linked = oldName.hasPrefix("[[") && oldName.hasSuffix("]]")
        return "\(prefix)\(linked ? "[[\(newName)]]" : newName)"
    }

    /// Updates a single matching `speakers:` row when legacy metadata exists.
    /// Body labels are still the source of truth for older files, so failure to
    /// find a metadata row does not block an otherwise exact label rewrite.
    private static func rewriteFrontmatterSpeaker(
        in lines: inout [String],
        identity: HomeMeetingSpeakerIdentity,
        newName: String,
        targetProfileID: UUID?,
        removesPersistentSpeakerLink: Bool
    ) -> Bool {
        guard let diarizerID = identity.diarizerSpeakerID else { return false }

        var inFrontmatter = false
        var inSpeakers = false
        var entryStarts: [Int] = []
        for index in lines.indices {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed == "---" {
                if !inFrontmatter {
                    inFrontmatter = true
                } else {
                    break
                }
                continue
            }
            guard inFrontmatter else { continue }
            if trimmed == "speakers:" {
                inSpeakers = true
                continue
            }
            guard inSpeakers else { continue }
            if !lines[index].hasPrefix("  "), !trimmed.isEmpty {
                break
            }
            if trimmed.hasPrefix("- ") {
                entryStarts.append(index)
            }
        }

        var matches: [(nameIndex: Int, sourceIndex: Int?, dbIDIndex: Int?, endIndex: Int)] = []
        for (offset, start) in entryStarts.enumerated() {
            let end = offset + 1 < entryStarts.count ? entryStarts[offset + 1] : frontmatterEntryEnd(after: start, in: lines)
            var values: [String: String] = [:]
            var nameIndex: Int?
            var sourceIndex: Int?
            var dbIDIndex: Int?

            for index in start..<end {
                let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
                let keyValue = trimmed.hasPrefix("- ") ? String(trimmed.dropFirst(2)) : trimmed
                let parts = keyValue.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let value = normalizeFrontmatterValue(parts[1])
                values[key] = value
                if key == "name" { nameIndex = index }
                if key == "source" { sourceIndex = index }
                if key == "db_id" { dbIDIndex = index }
            }

            let rowChannel = HomeMeetingSpeakerChannel(rawValue: values["channel"] ?? "system")
            let persistentID = values["db_id"].flatMap(UUID.init(uuidString:))
            guard values["id"] == diarizerID,
                  identity.channel == nil || rowChannel == identity.channel,
                  identity.persistentSpeakerID == nil || persistentID == identity.persistentSpeakerID,
                  let nameIndex else { continue }
            matches.append((nameIndex, sourceIndex, dbIDIndex, end))
        }

        guard matches.count == 1, let match = matches.first else { return false }
        let nameIndent = lines[match.nameIndex].prefix(while: { $0 == " " })
        lines[match.nameIndex] = "\(nameIndent)name: \"\(escapeYAML(newName))\""
        if let sourceIndex = match.sourceIndex {
            let sourceIndent = lines[sourceIndex].prefix(while: { $0 == " " })
            lines[sourceIndex] = "\(sourceIndent)source: user_manual"
        } else {
            lines.insert("    source: user_manual", at: match.endIndex)
        }
        if let targetProfileID {
            if let dbIDIndex = match.dbIDIndex {
                let dbIndent = lines[dbIDIndex].prefix(while: { $0 == " " })
                lines[dbIDIndex] = "\(dbIndent)db_id: \"\(targetProfileID.uuidString)\""
            } else {
                // Insert after the name. This remains inside the exact matched
                // speaker row even when the row originally had no source/db id.
                lines.insert("    db_id: \"\(targetProfileID.uuidString)\"", at: match.nameIndex + 1)
            }
        } else if removesPersistentSpeakerLink,
                  let dbIDIndex = match.dbIDIndex {
            // A local assignment with an existing db_id is the stale-profile
            // recovery path. Remove the dead link along with correcting the
            // visible name so the next edit does not hit the same failure.
            lines.remove(at: dbIDIndex)
        }
        return true
    }

    private static func frontmatterEntryEnd(after start: Int, in lines: [String]) -> Int {
        guard start + 1 < lines.count else { return lines.count }
        for index in (start + 1)..<lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed == "---" || (!lines[index].hasPrefix("  ") && !trimmed.isEmpty) {
                return index
            }
        }
        return lines.count
    }

    private static func normalizeFrontmatterValue(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    private static func escapeYAML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
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
/// Markdown file, retained `audio/<stem>_audio/` directory, and legacy
/// `<stem>.summary.md` sidecar (if one exists) to the canonical
/// `YYYY-MM-dd <title>` stem via `MeetingArtifactRenamer` —
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
            displayTitle: normalizedTitle,
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
