import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

struct StyledMeetingTranscript {
    let url: URL
    let title: String
    let artifactRecoveryNotice: MeetingArtifactRecoveryNotice?
    let artifactPostProcessingBlocked: Bool
    /// True only when this pass generated `title` from the app's own rule
    /// (the file had no saved title), not when it kept a saved one.
    let titleWasGenerated: Bool

    init(
        url: URL,
        title: String,
        artifactRecoveryNotice: MeetingArtifactRecoveryNotice? = nil,
        artifactPostProcessingBlocked: Bool = false,
        titleWasGenerated: Bool = false
    ) {
        self.url = url
        self.title = title
        self.artifactRecoveryNotice = artifactRecoveryNotice
        self.artifactPostProcessingBlocked = artifactPostProcessingBlocked
        self.titleWasGenerated = titleWasGenerated
    }
}

private struct MeetingArtifactRenameOutcome {
    let url: URL
    let recoveryNotice: MeetingArtifactRecoveryNotice?
    let shouldPersistStyling: Bool
    let postProcessingBlocked: Bool
}

enum MeetingTranscriptStyler {
    private static let frontmatterPreviewByteLimit = 64 * 1024
    private static let emptyTranscriptPlaceholder = "_No transcript captured._"

    private static let titleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "'Meeting at' h:mm a"
        return formatter
    }()

    private static let formatterQueue = DispatchQueue(label: "Transcripted.MeetingTranscriptStyler.formatters")

    static func restyleTranscript(
        at url: URL,
        recoveryStoreDirectory: URL? = nil
    ) -> StyledMeetingTranscript {
        do {
            return try MeetingTranscriptFileUpdateSerializer.sync(protecting: [url]) {
                styledTranscript(
                    at: url,
                    persistChanges: true,
                    recoveryStoreDirectory: recoveryStoreDirectory
                )
            }
        } catch MeetingTranscriptFileUpdateError.replacementInProgress {
            logFailure(
                event: "meeting_transcript_restyle_replacement_conflict",
                message: "Skipped transcript restyle during replacement retranscription",
                context: ["file": url.lastPathComponent]
            )
            return blockedRestyleResult(at: url)
        } catch {
            return blockedRestyleResult(at: url)
        }
    }

    static func blockedRestyleResult(at url: URL) -> StyledMeetingTranscript {
        let styled = styledTranscript(at: url, persistChanges: false)
        return StyledMeetingTranscript(
            url: styled.url,
            title: styled.title,
            artifactRecoveryNotice: styled.artifactRecoveryNotice,
            artifactPostProcessingBlocked: true
        )
    }

    static func displayTranscript(at url: URL) -> StyledMeetingTranscript {
        styledTranscript(at: url, persistChanges: false)
    }

    static func displayTranscriptPreview(at url: URL) -> StyledMeetingTranscript? {
        readDisplayPreview(at: url)?.styled
    }

    static func readDisplayPreview(at url: URL) -> (styled: StyledMeetingTranscript, frontmatter: TranscriptFrontmatterDocument)? {
        let frontmatter: TranscriptFrontmatterDocument?
        do {
            frontmatter = try TranscriptFrontmatter.readDocument(
                from: url,
                byteLimit: frontmatterPreviewByteLimit
            )
        } catch {
            logFailure(
                event: "meeting_transcript_preview_read_failed",
                message: "Failed to read meeting transcript preview",
                context: [
                    "file": url.lastPathComponent,
                    "error": error.localizedDescription
                ]
            )
            return nil
        }

        guard let frontmatter,
              isMeetingTranscript(frontmatter) else { return nil }
        // An explicit saved title is also buildTitle's first choice. Avoid
        // parsing preview transcript turns that cannot change that result.
        if let title = explicitTitle(in: frontmatter.lines), !title.isEmpty {
            return (StyledMeetingTranscript(url: url, title: title), frontmatter)
        }
        guard let document = parseDocument(frontmatter, fallbackURL: url) else {
            return (StyledMeetingTranscript(url: url, title: fallbackTitle(for: url)), frontmatter)
        }

        return (StyledMeetingTranscript(url: url, title: buildTitle(for: document)), frontmatter)
    }

    private static func styledTranscript(
        at url: URL,
        persistChanges: Bool,
        recoveryStoreDirectory: URL? = nil
    ) -> StyledMeetingTranscript {
        if !persistChanges, let title = frontmatterTitle(at: url) {
            return StyledMeetingTranscript(url: url, title: title)
        }

        let raw: String
        do {
            raw = try String(contentsOf: url, encoding: .utf8)
        } catch {
            logFailure(
                event: "meeting_transcript_read_failed",
                message: "Failed to read meeting transcript",
                context: [
                    "file": url.lastPathComponent,
                    "error": error.localizedDescription
                ]
            )
            return StyledMeetingTranscript(url: url, title: fallbackTitle(for: url))
        }

        guard let frontmatter = TranscriptFrontmatter.document(in: raw) else {
            return StyledMeetingTranscript(
                url: url,
                title: fallbackTitle(for: url)
            )
        }
        guard isMeetingTranscript(frontmatter) else {
            let savedTitle = explicitTitle(in: frontmatter.lines)
            let title = savedTitle?.isEmpty == false
                ? savedTitle ?? fallbackTitle(for: url)
                : fallbackTitle(for: url)
            return StyledMeetingTranscript(
                url: url,
                title: title
            )
        }
        guard let document = parseDocument(frontmatter, fallbackURL: url) else {
            return StyledMeetingTranscript(
                url: url,
                title: fallbackTitle(for: url)
            )
        }

        let title = buildTitle(for: document)
        guard persistChanges else {
            return StyledMeetingTranscript(url: url, title: title)
        }

        if document.transcriptEntries.isEmpty, hasUnparsedTranscriptContent(in: frontmatter.body) {
            logFailure(
                event: "meeting_transcript_restyle_skipped",
                message: "Skipped restyle because the transcript body could not be parsed",
                context: ["file": url.lastPathComponent]
            )
            return StyledMeetingTranscript(url: url, title: title)
        }

        var renderedFrontmatter = renderFrontmatter(
            lines: document.frontmatterLines,
            title: title,
            keepsWriterTitleLine: document.explicitTitle?.isEmpty == false,
            recordedAt: document.recordedAt,
            prunePipelineKeys: true
        )
        let body = renderBody(document: document, title: title)
        var updated = renderedFrontmatter.text + "\n\n" + body + "\n"
        let renameOutcome = renameTranscriptArtifactsIfNeeded(
            at: url,
            title: title,
            recordedAt: document.recordedAt,
            recoveryStoreDirectory: recoveryStoreDirectory
        )
        let finalURL = renameOutcome.url

        if renameOutcome.shouldPersistStyling {
            // Write the sidecar BEFORE pruning pipeline keys from the Markdown;
            // if the sidecar cannot be written, keep those keys in frontmatter
            // so nothing is lost.
            if !renderedFrontmatter.movedValues.isEmpty {
                let sidecarWritten: Bool
                if let captureID = renderedFrontmatter.captureID {
                    sidecarWritten = MeetingMetadataSidecar.merge(
                        renderedFrontmatter.movedValues,
                        forTranscript: finalURL,
                        captureID: captureID
                    )
                } else {
                    sidecarWritten = false
                }
                if !sidecarWritten {
                    renderedFrontmatter = renderFrontmatter(
                        lines: document.frontmatterLines,
                        title: title,
                        keepsWriterTitleLine: document.explicitTitle?.isEmpty == false,
                        recordedAt: document.recordedAt,
                        prunePipelineKeys: false
                    )
                    updated = renderedFrontmatter.text + "\n\n" + body + "\n"
                }
            }
            if updated != raw {
                do {
                    try TranscriptFileRewrite.write(updated, to: finalURL)
                    FileManager.default.restrictFileToOwnerOnly(at: finalURL)
                } catch {
                    logFailure(
                        event: "meeting_transcript_write_failed",
                        message: "Failed to write styled meeting transcript",
                        context: [
                            "file": finalURL.lastPathComponent,
                            "error": error.localizedDescription
                        ]
                    )
                }
            }
        }

        return StyledMeetingTranscript(
            url: finalURL,
            title: title,
            artifactRecoveryNotice: renameOutcome.recoveryNotice,
            artifactPostProcessingBlocked: renameOutcome.postProcessingBlocked,
            titleWasGenerated: document.explicitTitle?.isEmpty != false
                && renameOutcome.shouldPersistStyling && updated != raw
        )
    }

    static func transcriptBody(at url: URL) -> String? {
        let raw: String
        do {
            raw = try String(contentsOf: url, encoding: .utf8)
        } catch {
            logFailure(
                event: "meeting_transcript_body_read_failed",
                message: "Failed to read meeting transcript body",
                context: [
                    "file": url.lastPathComponent,
                    "error": error.localizedDescription
                ]
            )
            return nil
        }
        return TranscriptFrontmatter.body(in: raw)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isMeetingTranscript(_ document: TranscriptFrontmatterDocument) -> Bool {
        let body = document.body.trimmingCharacters(in: .whitespacesAndNewlines)
        return document.values["capture_type"] == "meeting"
            || body.hasPrefix("## Full Transcript")
            || body.hasPrefix("## Transcript")
            || body.contains("\n## Full Transcript")
            || body.contains("\n## Transcript")
    }

    private static func parseDocument(_ raw: String, fallbackURL: URL) -> ParsedDocument? {
        guard let frontmatter = TranscriptFrontmatter.document(in: raw) else {
            return nil
        }
        return parseDocument(frontmatter, fallbackURL: fallbackURL)
    }

    private static func parseDocument(
        _ frontmatter: TranscriptFrontmatterDocument,
        fallbackURL: URL
    ) -> ParsedDocument? {
        let values = frontmatter.values

        let recordedAt = parseRecordedAt(values: values, fallbackURL: fallbackURL)
        let speakerChannels = TranscriptFrontmatterDialogue.speakerChannels(fromFrontmatterLines: frontmatter.lines)
        let transcriptEntries = extractTranscriptEntries(from: frontmatter.body, channels: speakerChannels)

        let duration = values["duration"] ?? "0:00"
        let words = Int(values["total_word_count"] ?? "") ?? 0
        // v2 files keep utterance counts in the sidecar; count turns instead.
        let utterances = values["mic_utterances"] == nil && values["system_utterances"] == nil
            ? transcriptEntries.count
            : (Int(values["mic_utterances"] ?? "") ?? 0) + (Int(values["system_utterances"] ?? "") ?? 0)

        return ParsedDocument(
            frontmatterLines: frontmatter.lines,
            explicitTitle: explicitTitle(in: frontmatter.lines),
            recordedAt: recordedAt,
            duration: duration,
            durationSeconds: TranscriptFrontmatter.durationSeconds(from: duration) ?? 0,
            totalWords: words,
            totalUtterances: utterances,
            microphoneAudioUnusable: values["microphone_audio_unusable"] == "true",
            transcriptEntries: transcriptEntries,
            speakerChannels: speakerChannels,
            preservedSummarySection: MeetingTitlesBody.summarySection(in: frontmatter.body),
            preservedTrailingSections: trailingBodySections(in: frontmatter.body)
        )
    }

    private static func frontmatterTitle(at url: URL) -> String? {
        guard let document = try? TranscriptFrontmatter.readDocument(
            from: url,
            byteLimit: frontmatterPreviewByteLimit
        ) else {
            return nil
        }

        let title = explicitTitle(in: document.lines)
        return title?.isEmpty == false ? title : nil
    }

    /// The writer's own `title:` line; like `TranscriptFrontmatter.values`,
    /// the last unindented one wins.
    private static func writerTitleLine(in lines: [String]) -> String? {
        lines.last { $0.hasPrefix("title:") }
    }

    /// The saved title as plain text, decoded the way Core reads it. A heading
    /// or filename can't hold a line break or tab, so those become spaces.
    private static func explicitTitle(in lines: [String]) -> String? {
        guard let line = writerTitleLine(in: lines) else { return nil }
        let raw = String(line.dropFirst("title:".count))
        return TranscriptFrontmatter.unquoteYAMLScalar(raw)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseRecordedAt(values: [String: String], fallbackURL: URL) -> Date {
        if let parsed = TranscriptFrontmatter.recordedAt(values: values) {
            return parsed
        }

        let resourceValues = try? fallbackURL.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return resourceValues?.creationDate ?? resourceValues?.contentModificationDate ?? Date()
    }

    private static func extractTranscriptEntries(
        from body: String,
        channels: TranscriptFrontmatterDialogue.SpeakerChannels
    ) -> [MeetingTranscriptTurn] {
        for block in transcriptBlocks(in: body) {
            let entries = parseTranscriptEntries(from: block, channels: channels)
            if !entries.isEmpty { return entries }
        }

        return parseTranscriptEntries(from: body.trimmingCharacters(in: .whitespacesAndNewlines), channels: channels)
    }

    private static func transcriptBlocks(in body: String) -> [String] {
        let markers = ["## Full Transcript\n\n", "## Transcript\n\n"]

        var blocks: [String] = []
        for marker in markers {
            guard let start = body.range(of: marker) else { continue }
            let remaining = String(body[start.upperBound...])
            let endMarkers = ["\n---\n", "\n*Generated by ", "\n## "]
            let endIndex = endMarkers
                .compactMap { remaining.range(of: $0)?.lowerBound }
                .min() ?? remaining.endIndex
            blocks.append(String(remaining[..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return blocks
    }

    /// Keep unknown sections after the transcript intact. Older meeting files
    /// may contain generated summary sections; the app no longer creates or
    /// displays them, but restyling must not erase user-owned Markdown.
    private static func trailingBodySections(in body: String) -> String? {
        let transcriptMarkers = ["\n## Full Transcript\n\n", "\n## Transcript\n\n"]
        for marker in transcriptMarkers {
            guard let transcriptStart = body.range(of: marker) else { continue }
            let remaining = body[transcriptStart.upperBound...]
            guard let sectionStart = remaining.range(of: "\n## ") else { continue }
            let suffix = String(remaining[sectionStart.lowerBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return suffix.isEmpty ? nil : suffix
        }
        return nil
    }

    /// True when the body carries transcript text the entry parser could not
    /// understand. Rewriting such a body would replace real content with the
    /// empty-transcript placeholder, so persisting must fail closed instead.
    private static func hasUnparsedTranscriptContent(in body: String) -> Bool {
        let blocks = transcriptBlocks(in: body)
        guard blocks.isEmpty else {
            return blocks.contains(where: blockHasTranscriptContent)
        }

        return blockHasTranscriptContent(body)
    }

    private static func blockHasTranscriptContent(_ block: String) -> Bool {
        block
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .contains { line in
                !line.isEmpty
                    && line != "---"
                    && line != emptyTranscriptPlaceholder
                    && !line.hasPrefix("*Generated by ")
            }
    }

    private struct RenderedFrontmatter {
        let text: String
        let movedValues: [String: MeetingMetadataSidecar.Value]
        let captureID: UUID?
    }

    private static func renderFrontmatter(
        lines: [String],
        title: String,
        keepsWriterTitleLine: Bool,
        recordedAt: Date,
        prunePipelineKeys: Bool = true
    ) -> RenderedFrontmatter {
        // `title:` comes first: the writer's line verbatim for a saved title,
        // else the generated title. The body is now in the v2 grammar, so the
        // header says `format_version: 2` and `transcript_style: styled`
        // (filter-then-emit keeps them from duplicating on repeat passes).
        // Unknown keys pass through; pipeline plumbing and healthy defaults
        // move to the `.meta/<capture_id>.json` sidecar when writable.
        // See docs/capture-format.md.
        let titleLine = (keepsWriterTitleLine ? writerTitleLine(in: lines) : nil)
            ?? "title: \(TranscriptFrontmatter.quotedYAMLScalar(title))"
        let output = MeetingTranscriptV2Frontmatter.render(
            lines: lines,
            titleLine: titleLine,
            recordedAt: recordedAt,
            prunePipelineKeys: prunePipelineKeys
        )
        return RenderedFrontmatter(
            text: (["---"] + output.lines + ["---"]).joined(separator: "\n"),
            movedValues: output.movedValues,
            captureID: output.captureID
        )
    }

    private static func renderBody(document: ParsedDocument, title: String) -> String {
        var detailParts = [
            "Recorded \(detailString(from: document.recordedAt))",
            formatDuration(document.durationSeconds, fallback: document.duration)
        ]
        if document.totalWords > 0 {
            detailParts.append("\(document.totalWords) \(document.totalWords == 1 ? "word" : "words")")
        }
        let unmergeable = MeetingTranscriptDialogue.duplicateSpeakerKeys(
            fromFrontmatterLines: document.frontmatterLines
        )
        let turns = MeetingTranscriptDialogue.merged(document.transcriptEntries, unmergeable: unmergeable)
        if !turns.isEmpty {
            detailParts.append("\(turns.count) \(turns.count == 1 ? "turn" : "turns")")
        }

        let transcriptBlock = turns.isEmpty
            ? emptyTranscriptPlaceholder
            : MeetingTranscriptDialogue.render(turns, channels: document.speakerChannels)

        let headingTitle = MeetingTitlesBody.headingTitle(frontmatterLines: document.frontmatterLines, savedTitle: title)
        var rendered = """
        # \(headingTitle)

        \(detailParts.joined(separator: "  •  "))
        """
        if document.microphoneAudioUnusable {
            rendered += "\n\n> **Recording note:** The microphone track was missing or could not be transcribed, so this meeting contains system audio only."
        }
        if let summary = document.preservedSummarySection {
            rendered += "\n\n\(summary)"
        }
        rendered += """


        ## Transcript

        \(transcriptBlock)
        """
        if let preservedTrailingSections = document.preservedTrailingSections {
            rendered += "\n\n\(preservedTrailingSections)"
        }
        return rendered
    }

    private static func buildTitle(for document: ParsedDocument) -> String {
        if let explicitTitle = document.explicitTitle,
           !explicitTitle.isEmpty {
            return explicitTitle
        }
        return ruleTitle(for: document)
    }

    /// The title the app would give this meeting on its own, ignoring any
    /// saved `title:`. Nil when the Markdown isn't a meeting transcript.
    static func ruleTitle(forMeetingMarkdown raw: String, fallbackURL: URL) -> String? {
        guard let frontmatter = TranscriptFrontmatter.document(in: raw),
              isMeetingTranscript(frontmatter),
              let document = parseDocument(frontmatter, fallbackURL: fallbackURL) else { return nil }
        return ruleTitle(for: document)
    }

    /// True when `title` is the app's own rule title for a file whose rule
    /// gives `ruleTitle` today. "Meeting with <names>" counts only when the
    /// names are exactly the ones the rule takes from the file's speakers, so
    /// a typed or calendar "Meeting with Legal" never matches. "Quick notes"
    /// and "Meeting at <time>" (in any clock format: 12 or 24 hour, any AM/PM
    /// marker) count by shape, so naming the speakers later or a time-zone or
    /// locale change doesn't hide that the app made them.
    static func matchesRuleTitle(_ title: String, ruleTitle: String?) -> Bool {
        let normalized = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if let ruleTitle, normalized == ruleTitle.split(whereSeparator: \.isWhitespace).joined(separator: " ") {
            return true
        }
        if normalized == "Quick notes" { return true }
        return normalized.range(of: ruleTimeTitlePattern, options: .regularExpression) != nil
    }

    private static let ruleTimeTitlePattern = #"^Meeting at (?:[^\d\s]{1,8} ?)?\d{1,2}[:.h]\d{2}(?: ?[^\d\s]{1,8})?$"#

    private static func ruleTitle(for document: ParsedDocument) -> String {
        let namedRemoteParticipants = Array(
            LinkedSet(document.transcriptEntries.compactMap { entry -> String? in
                guard entry.channel == .system else { return nil }
                let name = entry.name
                guard !name.hasPrefix("Speaker "), name != "Remote", !name.isEmpty else { return nil }
                return name
            }).elements
        )

        if namedRemoteParticipants.count == 1 {
            return "Meeting with \(namedRemoteParticipants[0])"
        }

        if namedRemoteParticipants.count == 2 {
            return "Meeting with \(namedRemoteParticipants[0]) and \(namedRemoteParticipants[1])"
        }

        if document.durationSeconds <= 45 || document.totalUtterances <= 2 {
            return "Quick notes"
        }

        return titleString(from: document.recordedAt)
    }

    private static func titleString(from date: Date) -> String {
        formatterQueue.sync {
            titleFormatter.string(from: date)
        }
    }

    private static func detailString(from date: Date) -> String {
        formatterQueue.sync {
            DateFormattingHelper.formatDisplay(date)
        }
    }

    private static func parseTranscriptEntries(
        from block: String,
        channels: TranscriptFrontmatterDialogue.SpeakerChannels
    ) -> [MeetingTranscriptTurn] {
        let chunks = block
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var entries: [MeetingTranscriptTurn] = []
        for chunk in chunks {
            if let entry = parseTranscriptEntry(from: chunk, channels: channels) {
                entries.append(entry)
            }
        }
        return entries
    }

    private static let transcriptTimestampRegex = try? NSRegularExpression(pattern: #"^\[?([0-9:]+)\]?\s+"#)

    private static func parseTranscriptEntry(
        from chunk: String,
        channels: TranscriptFrontmatterDialogue.SpeakerChannels
    ) -> MeetingTranscriptTurn? {
        let lines = chunk
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard let firstLine = lines.first else { return nil }
        // v2 `[MM:SS] **Speaker:** text`, so a second restyle reads its own output.
        if TranscriptFrontmatterDialogue.parseLine(firstLine) != nil {
            return MeetingTranscriptDialogue.turn(
                fromDialogueLine: firstLine,
                continuation: Array(lines.dropFirst()),
                channels: channels
            )
        }
        let normalizedHeader = firstLine
            .replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let regex = transcriptTimestampRegex else {
            return nil
        }

        let nsHeader = normalizedHeader as NSString
        let range = NSRange(location: 0, length: nsHeader.length)
        guard let match = regex.firstMatch(in: normalizedHeader, range: range),
              match.numberOfRanges >= 2 else {
            return nil
        }

        let timestamp = nsHeader.substring(with: match.range(at: 1))
        let headerTailStart = normalizedHeader.index(
            normalizedHeader.startIndex,
            offsetBy: match.range.location + match.range.length
        )
        guard let parsedLabel = parseBracketedSpeakerLabel(in: String(normalizedHeader[headerTailStart...])) else {
            return nil
        }

        let label = parsedLabel.label
        let inlineTail = parsedLabel.tail.trimmingCharacters(in: .whitespaces)
        let textLines = (inlineTail.isEmpty ? Array(lines.dropFirst()) : [inlineTail] + Array(lines.dropFirst()))
        let text = textLines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return MeetingTranscriptDialogue.turn(timestamp: timestamp, qualifiedLabel: label, text: text)
    }

    private static func parseBracketedSpeakerLabel(in value: String) -> (label: String, tail: String)? {
        let characters = Array(value)
        guard characters.first == "[" else { return nil }

        var label = ""
        var index = 1
        var wikiLinkDepth = 0

        while index < characters.count {
            let character = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : nil

            if character == "[", next == "[" {
                wikiLinkDepth += 1
                label.append(character)
                label.append(next!)
                index += 2
                continue
            }

            if character == "]", next == "]", wikiLinkDepth > 0 {
                wikiLinkDepth -= 1
                label.append(character)
                label.append(next!)
                index += 2
                continue
            }

            if character == "]", wikiLinkDepth == 0 {
                let tail = String(characters.dropFirst(index + 1))
                return (label, tail)
            }

            label.append(character)
            index += 1
        }

        return nil
    }

    private static func formatDuration(_ seconds: Int, fallback: String) -> String {
        guard seconds > 0 else { return fallback }

        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .short
        formatter.zeroFormattingBehavior = .dropAll
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : (seconds >= 60 ? [.minute, .second] : [.second])

        return formatter.string(from: TimeInterval(seconds)) ?? fallback
    }

    private static func renameTranscriptArtifactsIfNeeded(
        at url: URL,
        title: String,
        recordedAt: Date,
        recoveryStoreDirectory: URL?
    ) -> MeetingArtifactRenameOutcome {
        let preferredStem = MeetingArtifactRenamer.fileStem(
            date: recordedAt,
            title: title,
            fallback: url.deletingPathExtension().lastPathComponent
        )
        do {
            let finalURL = try MeetingArtifactRenamer.rename(
                transcriptAt: url,
                toStem: preferredStem,
                displayTitle: title,
                recoveryStoreDirectory: recoveryStoreDirectory,
                logFailure: { event, context in
                    logFailure(event: event, message: "Failed to rename styled transcript artifact", context: context)
                }
            )
            return MeetingArtifactRenameOutcome(
                url: finalURL,
                recoveryNotice: nil,
                shouldPersistStyling: true,
                postProcessingBlocked: false
            )
        } catch let error as MeetingArtifactRenameError {
            let recoveryNotice = error.recoveryNotice(sourceTranscriptURL: url)
            if recoveryNotice != nil {
                logFailure(
                    event: "meeting_transcript_artifact_recovery_required",
                    message: "Transcript artifacts need manual recovery after restyle",
                    context: ["audioLocation": error.audioLocation?.rawValue ?? "pending"]
                )
            }
            return MeetingArtifactRenameOutcome(
                url: url,
                recoveryNotice: recoveryNotice,
                shouldPersistStyling: false,
                postProcessingBlocked: recoveryNotice != nil
            )
        } catch {
            return MeetingArtifactRenameOutcome(
                url: url,
                recoveryNotice: nil,
                shouldPersistStyling: false,
                postProcessingBlocked: true
            )
        }
    }

    private static func fallbackTitle(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ")
    }

    private static func logFailure(event: String, message: String, context: [String: String]) {
        let contextString = context
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        fputs("⚠️ MEETING | \(event) | \(message) | \(contextString)\n", stderr)
    }
}

private struct ParsedDocument {
    let frontmatterLines: [String]
    let explicitTitle: String?
    let recordedAt: Date
    let duration: String
    let durationSeconds: Int
    let totalWords: Int
    let totalUtterances: Int
    let microphoneAudioUnusable: Bool
    let transcriptEntries: [MeetingTranscriptTurn]
    let speakerChannels: TranscriptFrontmatterDialogue.SpeakerChannels
    let preservedSummarySection: String?
    let preservedTrailingSections: String?
}

private struct LinkedSet<Element: Hashable> {
    private(set) var elements: [Element] = []
    private var seen: Set<Element> = []

    init<S: Sequence>(_ sequence: S) where S.Element == Element {
        for element in sequence where seen.insert(element).inserted {
            elements.append(element)
        }
    }
}
