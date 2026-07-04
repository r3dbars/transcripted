import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

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
}

/// Shared rename mechanics for the on-disk artifacts that make up a saved meeting:
/// the Markdown transcript, its retained `audio/<stem>_audio/` directory, and the
/// optional `<stem>.summary.md` sidecar.
///
/// Both the post-save restyle (`MeetingTranscriptStyler`) and the manual title-edit
/// flow (`HomeMeetingRename`) route through here so the filename convention and
/// sidecar bookkeeping cannot drift between the two paths.
///
/// Filenames follow `YYYY-MM-dd <name>` so a plain directory sort is chronological.
/// The date comes from the meeting's recorded date; `<name>` is the sanitized title
/// with no date of its own (the date lives in the filename and in frontmatter).
enum MeetingArtifactRenamer {
    private static let datePrefixFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let formatterQueue = DispatchQueue(label: "Transcripted.MeetingArtifactRenamer.formatter")

    // MARK: - Stem building

    /// `YYYY-MM-dd` prefix for the given recording date.
    static func datePrefix(for date: Date) -> String {
        formatterQueue.sync { datePrefixFormatter.string(from: date) }
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
    /// Fails closed: a no-op when the stem already matches, and on any move error the
    /// original URL is returned unchanged so callers never lose track of the file.
    @discardableResult
    static func rename(
        transcriptAt url: URL,
        toStem preferredStem: String,
        fileManager: FileManager = .default,
        logFailure: (_ event: String, _ context: [String: String]) -> Void = { _, _ in }
    ) -> URL {
        let targetURL = uniqueTranscriptURL(
            in: url.deletingLastPathComponent(),
            preferredStem: preferredStem,
            originalURL: url,
            fileManager: fileManager
        )

        guard targetURL != url else { return url }

        do {
            try fileManager.moveItem(at: url, to: targetURL)
        } catch {
            logFailure(
                "meeting_transcript_rename_failed",
                [
                    "sourceExists": "\(fileManager.fileExists(atPath: url.path))",
                    "targetExists": "\(fileManager.fileExists(atPath: targetURL.path))",
                    "errorType": "\(type(of: error))"
                ]
            )
            return url
        }

        renameAudioDirectoryIfNeeded(
            from: audioDirectoryURL(for: url),
            to: audioDirectoryURL(for: targetURL),
            fileManager: fileManager,
            logFailure: logFailure
        )
        renameSummarySidecarIfNeeded(
            from: url,
            to: targetURL,
            fileManager: fileManager,
            logFailure: logFailure
        )
        updateInlineSummarySourceIfNeeded(
            at: targetURL,
            from: url.lastPathComponent,
            to: targetURL.lastPathComponent,
            fileManager: fileManager,
            logFailure: logFailure
        )
        return targetURL
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

    private static func renameAudioDirectoryIfNeeded(
        from sourceURL: URL,
        to targetURL: URL,
        fileManager: FileManager,
        logFailure: (_ event: String, _ context: [String: String]) -> Void
    ) {
        guard sourceURL != targetURL, fileManager.fileExists(atPath: sourceURL.path) else { return }

        let finalURL = uniqueAudioDirectoryURL(preferredURL: targetURL, fileManager: fileManager)

        do {
            try fileManager.moveItem(at: sourceURL, to: finalURL)
        } catch {
            logFailure(
                "meeting_audio_directory_rename_failed",
                [
                    "sourceExists": "\(fileManager.fileExists(atPath: sourceURL.path))",
                    "targetExists": "\(fileManager.fileExists(atPath: finalURL.path))",
                    "errorType": "\(type(of: error))"
                ]
            )
        }
    }

    private static func uniqueAudioDirectoryURL(preferredURL: URL, fileManager: FileManager) -> URL {
        guard fileManager.fileExists(atPath: preferredURL.path) else { return preferredURL }

        let directory = preferredURL.deletingLastPathComponent()
        let stem = preferredURL.lastPathComponent
        var suffix = 2

        while suffix <= 999 {
            let candidate = directory.appendingPathComponent("\(stem) \(suffix)", isDirectory: true)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            suffix += 1
        }
        return directory.appendingPathComponent("\(stem) \(UUID().uuidString)", isDirectory: true)
    }

    /// Move the generated `<stem>.summary.md` sidecar alongside the renamed transcript
    /// and repoint its `local_summary_source_transcript` frontmatter at the new filename.
    /// Only an owned summary (`capture_type: meeting_summary` pointing back at the source
    /// transcript) is touched; anything else is left in place.
    private static func renameSummarySidecarIfNeeded(
        from sourceTranscriptURL: URL,
        to targetTranscriptURL: URL,
        fileManager: FileManager,
        logFailure: (_ event: String, _ context: [String: String]) -> Void
    ) {
        let sourceSummaryURL = LocalMeetingSummaryStore.summaryURL(for: sourceTranscriptURL)
        guard sourceSummaryURL != LocalMeetingSummaryStore.summaryURL(for: targetTranscriptURL),
              fileManager.fileExists(atPath: sourceSummaryURL.path),
              let values = try? TranscriptFrontmatter.readValues(from: sourceSummaryURL),
              values["capture_type"] == "meeting_summary",
              values["source_transcript"] == sourceTranscriptURL.lastPathComponent else {
            return
        }

        let targetSummaryURL = LocalMeetingSummaryStore.summaryURL(for: targetTranscriptURL)

        do {
            if let rewritten = rewriteSummarySource(
                at: sourceSummaryURL,
                from: sourceTranscriptURL.lastPathComponent,
                to: targetTranscriptURL.lastPathComponent
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

    private static func updateInlineSummarySourceIfNeeded(
        at transcriptURL: URL,
        from oldName: String,
        to newName: String,
        fileManager: FileManager,
        logFailure: (_ event: String, _ context: [String: String]) -> Void
    ) {
        guard oldName != newName,
              fileManager.fileExists(atPath: transcriptURL.path),
              let raw = try? String(contentsOf: transcriptURL, encoding: .utf8),
              let updated = LocalMeetingSummaryMarkdownUpdater.updatingSourceTranscriptFilename(
                in: raw,
                from: oldName,
                to: newName
              ) else {
            return
        }

        do {
            try updated.write(to: transcriptURL, atomically: true, encoding: .utf8)
            fileManager.restrictFileToOwnerOnly(at: transcriptURL)
        } catch {
            logFailure(
                "meeting_inline_summary_source_rename_failed",
                [
                    "transcriptExists": "\(fileManager.fileExists(atPath: transcriptURL.path))",
                    "errorType": "\(type(of: error))"
                ]
            )
        }
    }

    /// Rewrite the summary sidecar's `source_transcript` pointer line(s). Returns nil
    /// when nothing changed so callers can skip an unnecessary write.
    private static func rewriteSummarySource(at url: URL, from oldName: String, to newName: String) -> String? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }

        var didChange = false
        let updatedLines = raw.components(separatedBy: "\n").map { line -> String in
            guard line.trimmingCharacters(in: .whitespaces).hasPrefix("source_transcript:") else {
                return line
            }
            didChange = true
            return line.replacingOccurrences(of: oldName, with: newName)
        }

        return didChange ? updatedLines.joined(separator: "\n") : nil
    }
}
