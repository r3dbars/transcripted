import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

enum MeetingTranscriptFileUpdateError: Error {
    case replacementInProgress
}

enum MeetingArtifactAudioLocation: String, Equatable {
    case notPresent
    case atSource
    case duplicated
    case atTarget
    case missing

    var isRetrySafe: Bool {
        self == .notPresent || self == .atSource
    }
}

struct MeetingArtifactRecoveryNotice: Equatable {
    let sourceTranscriptURL: URL
    let targetTranscriptURL: URL
}

enum MeetingArtifactRenameError: Error, Equatable {
    case audioMoveFailed(audioLocation: MeetingArtifactAudioLocation, targetTranscriptURL: URL)
    case transcriptMoveFailed(audioLocation: MeetingArtifactAudioLocation, targetTranscriptURL: URL)
    case recoveryPending(MeetingArtifactRecoveryNotice)

    var audioLocation: MeetingArtifactAudioLocation? {
        switch self {
        case .audioMoveFailed(let audioLocation, _),
             .transcriptMoveFailed(let audioLocation, _):
            return audioLocation
        case .recoveryPending:
            return nil
        }
    }

    var targetTranscriptURL: URL {
        switch self {
        case .audioMoveFailed(_, let targetTranscriptURL),
             .transcriptMoveFailed(_, let targetTranscriptURL):
            return targetTranscriptURL
        case .recoveryPending(let notice):
            return notice.targetTranscriptURL
        }
    }

    func recoveryNotice(sourceTranscriptURL: URL) -> MeetingArtifactRecoveryNotice? {
        if case .recoveryPending(let notice) = self { return notice }
        guard let audioLocation, !audioLocation.isRetrySafe else { return nil }
        return MeetingArtifactRecoveryNotice(
            sourceTranscriptURL: sourceTranscriptURL,
            targetTranscriptURL: targetTranscriptURL
        )
    }
}

enum MeetingTranscriptFileUpdateSerializer {
    private static let fallbackQueueSpecific = DispatchSpecificKey<Void>()
    private static let fallbackQueue: DispatchQueue = {
        let queue = DispatchQueue(label: "Transcripted.MeetingTranscriptFileUpdateSerializer", qos: .utility)
        queue.setSpecific(key: fallbackQueueSpecific, value: ())
        return queue
    }()

    static func sync<T>(_ update: () throws -> T) rethrows -> T {
        #if canImport(TranscriptedCore)
        return try TranscriptSaver.serializeTranscriptFileUpdate(update)
        #else
        if DispatchQueue.getSpecific(key: fallbackQueueSpecific) != nil {
            return try update()
        }
        return try fallbackQueue.sync(execute: update)
        #endif
    }

    static func sync<T>(
        protecting transcriptURLs: [URL],
        _ update: () throws -> T
    ) throws -> T {
        #if canImport(TranscriptedCore)
        do {
            return try TranscriptSaver.serializeTranscriptFileUpdate(
                protecting: transcriptURLs,
                update
            )
        } catch TranscriptFileUpdateError.replacementInProgress {
            throw MeetingTranscriptFileUpdateError.replacementInProgress
        }
        #else
        return try sync(update)
        #endif
    }
}

/// Shared rename mechanics for the on-disk artifacts that make up a saved meeting:
/// the Markdown transcript, its retained `audio/<stem>_audio/` directory, and the
/// legacy `<stem>.summary.md` sidecar left behind by the now-removed local AI
/// summarizer (kept in sync as hygiene, not as an active feature).
///
/// Both the post-save restyle (`MeetingTranscriptStyler`) and the manual title-edit
/// flow (`HomeMeetingRename`) route through here so the filename convention and
/// sidecar bookkeeping cannot drift between the two paths.
///
/// Filenames follow `YYYY-MM-dd <name>` so a plain directory sort is chronological.
/// The date comes from the meeting's recorded date; `<name>` is the sanitized title
/// with no date of its own (the date lives in the filename and in frontmatter).
enum MeetingArtifactRenamer {
    private static let formatterQueue = DispatchQueue(label: "Transcripted.MeetingArtifactRenamer.formatter")

    // MARK: - Stem building

    /// `YYYY-MM-dd` prefix for the given recording date.
    static func datePrefix(for date: Date) -> String {
        formatterQueue.sync { DateFormattingHelper.formatDayStamp(date) }
    }

    /// Canonical file stem: `YYYY-MM-dd <sanitized title>`.
    static func fileStem(date: Date, title: String, fallback: String) -> String {
        "\(datePrefix(for: date)) \(sanitizedTitleStem(for: title, fallback: fallback))"
    }

    /// Sanitize a title into a filesystem-safe stem fragment (no date prefix).
    static func sanitizedTitleStem(for title: String, fallback: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let collapsedWhitespace = title
            .replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: invalidCharacters)
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let limited = String(collapsedWhitespace.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
        let visibleStem = String(limited.drop(while: { $0 == "." }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return visibleStem.isEmpty ? fallback : visibleStem
    }

    // MARK: - Artifact paths

    static func audioDirectoryURL(for transcriptURL: URL) -> URL {
        transcriptURL
            .deletingLastPathComponent()
            .appendingPathComponent("audio", isDirectory: true)
            .appendingPathComponent("\(transcriptURL.deletingPathExtension().lastPathComponent)_audio", isDirectory: true)
    }

    // MARK: - Rename

    /// Move the transcript and its sibling artifacts so the Markdown stem becomes
    /// `preferredStem`. Returns the final transcript URL.
    ///
    /// Fails closed: a no-op when the stem already matches. Any core transcript/audio
    /// move failure is thrown so callers cannot mistake a partial rename for success.
    @discardableResult
    static func rename(
        transcriptAt url: URL,
        toStem preferredStem: String,
        displayTitle: String? = nil,
        fileManager: FileManager = .default,
        moveItem: ((URL, URL) throws -> Void)? = nil,
        copyItem: ((URL, URL) throws -> Void)? = nil,
        removeItem: ((URL) throws -> Void)? = nil,
        recoveryStoreDirectory: URL? = nil,
        logFailure: @escaping (_ event: String, _ context: [String: String]) -> Void = { _, _ in }
    ) throws -> URL {
        do {
            if let pendingNotice = try MeetingArtifactRecoveryStore.pendingNotice(
                for: url,
                directory: recoveryStoreDirectory,
                fileManager: fileManager
            ) {
                throw MeetingArtifactRenameError.recoveryPending(pendingNotice)
            }
        } catch let error as MeetingArtifactRenameError {
            throw error
        } catch {
            logFailure(
                "meeting_artifact_recovery_journal_read_failed",
                ["errorType": "\(type(of: error))"]
            )
            MeetingArtifactRecoveryStore.notifyUnavailable(directory: recoveryStoreDirectory)
            throw error
        }

        let targetURL = uniqueTranscriptURL(
            in: url.deletingLastPathComponent(),
            preferredStem: preferredStem,
            originalURL: url,
            fileManager: fileManager
        )

        guard targetURL != url else { return url }

        let moveItem = moveItem ?? { sourceURL, targetURL in
            try fileManager.moveItem(at: sourceURL, to: targetURL)
        }
        let copyItem = copyItem ?? { sourceURL, targetURL in
            try fileManager.copyItem(at: sourceURL, to: targetURL)
        }
        let removeItem = removeItem ?? { targetURL in
            try fileManager.removeItem(at: targetURL)
        }
        return try MeetingArtifactRenameTransaction(
            sourceTranscriptURL: url,
            targetTranscriptURL: targetURL,
            displayTitle: displayTitle,
            fileManager: fileManager,
            moveItem: moveItem,
            copyItem: copyItem,
            removeItem: removeItem,
            recoveryStoreDirectory: recoveryStoreDirectory,
            logFailure: logFailure
        ).execute()
    }

    static func uniqueTranscriptURL(
        in directory: URL,
        preferredStem: String,
        originalURL: URL,
        fileManager: FileManager = .default
    ) -> URL {
        var candidateStem = preferredStem
        var suffix = 2
        let originalAudioDirectory = audioDirectoryURL(for: originalURL)

        while suffix <= 999 {
            let candidateURL = directory.appendingPathComponent(candidateStem).appendingPathExtension("md")
            let markdownTaken = candidateURL != originalURL && fileManager.fileExists(atPath: candidateURL.path)
            let candidateAudioDirectory = audioDirectoryURL(for: candidateURL)
            let audioTaken = candidateAudioDirectory != originalAudioDirectory
                && fileManager.fileExists(atPath: candidateAudioDirectory.path)

            if !markdownTaken && !audioTaken {
                return candidateURL
            }

            candidateStem = "\(preferredStem) \(suffix)"
            suffix += 1
        }
        return directory.appendingPathComponent("\(preferredStem) \(UUID().uuidString)").appendingPathExtension("md")
    }

    // MARK: - Legacy summary sidecar hygiene

    /// `<stem>.summary.md` next to the transcript. Matches the sidecar name the
    /// now-removed local AI summarizer used to write; kept only so those legacy
    /// artifacts stay alongside a renamed transcript instead of orphaning.
    static func legacySummarySidecarURL(for transcriptURL: URL) -> URL {
        let base = transcriptURL.deletingPathExtension()
        return base
            .deletingLastPathComponent()
            .appendingPathComponent("\(base.lastPathComponent).summary")
            .appendingPathExtension("md")
    }

    /// Move the legacy `<stem>.summary.md` sidecar alongside the renamed transcript
    /// and repoint its `source_transcript` (and, if present, `summary_title`)
    /// frontmatter at the new filename. Only an owned summary (`capture_type:
    /// meeting_summary` pointing back at the source transcript) is touched;
    /// anything else is left in place.
    static func renameSummarySidecarIfNeeded(
        from sourceTranscriptURL: URL,
        to targetTranscriptURL: URL,
        displayTitle: String?,
        fileManager: FileManager,
        logFailure: (_ event: String, _ context: [String: String]) -> Void
    ) {
        let sourceSummaryURL = legacySummarySidecarURL(for: sourceTranscriptURL)
        guard sourceSummaryURL != legacySummarySidecarURL(for: targetTranscriptURL),
              fileManager.fileExists(atPath: sourceSummaryURL.path),
              let values = try? TranscriptFrontmatter.readValues(from: sourceSummaryURL),
              values["capture_type"] == "meeting_summary",
              values["source_transcript"] == sourceTranscriptURL.lastPathComponent else {
            return
        }

        let targetSummaryURL = legacySummarySidecarURL(for: targetTranscriptURL)

        do {
            let renamedMeetingTitle = displayTitle
                ?? (try? TranscriptFrontmatter.readValues(from: targetTranscriptURL))?["title"]
            if let rewritten = rewriteSummarySource(
                at: sourceSummaryURL,
                from: sourceTranscriptURL.lastPathComponent,
                to: targetTranscriptURL.lastPathComponent,
                displayTitle: renamedMeetingTitle
            ) {
                try rewritten.write(to: sourceSummaryURL, atomically: true, encoding: .utf8)
                FileManager.default.restrictFileToOwnerOnly(at: sourceSummaryURL)
            }
            try fileManager.moveItem(at: sourceSummaryURL, to: targetSummaryURL)
        } catch {
            logFailure(
                "meeting_summary_sidecar_rename_failed",
                [
                    "sourceExists": "\(fileManager.fileExists(atPath: sourceSummaryURL.path))",
                    "targetExists": "\(fileManager.fileExists(atPath: targetSummaryURL.path))",
                    "errorType": "\(type(of: error))"
                ]
            )
        }
    }

    /// Rewrite the summary sidecar's `source_transcript` pointer line(s). Returns nil
    /// when nothing changed so callers can skip an unnecessary write.
    private static func rewriteSummarySource(
        at url: URL,
        from oldName: String,
        to newName: String,
        displayTitle: String?
    ) -> String? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }

        var didChange = false
        let escapedTitle = displayTitle?.replacingOccurrences(of: "\"", with: "'")
        let updatedLines = raw.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("source_transcript:") {
                didChange = true
                return line.replacingOccurrences(of: oldName, with: newName)
            }
            if let escapedTitle, trimmed.hasPrefix("summary_title:") {
                didChange = true
                return "summary_title: \"\(escapedTitle)\""
            }
            return line
        }

        return didChange ? updatedLines.joined(separator: "\n") : nil
    }
}
