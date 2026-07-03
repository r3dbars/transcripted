import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

struct StyledMeetingTranscript {
    let url: URL
    let title: String
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

    private static let detailFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
    private static let formatterQueue = DispatchQueue(label: "Transcripted.MeetingTranscriptStyler.formatters")

    static func restyleTranscript(at url: URL) -> StyledMeetingTranscript {
        MeetingTranscriptFileUpdateSerializer.sync {
            styledTranscript(at: url, persistChanges: true)
        }
    }

    static func displayTranscript(at url: URL) -> StyledMeetingTranscript {
        styledTranscript(at: url, persistChanges: false)
    }

    static func displayTranscriptPreview(at url: URL) -> StyledMeetingTranscript? {
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
        guard let document = parseDocument(frontmatter, fallbackURL: url) else {
            return StyledMeetingTranscript(url: url, title: fallbackTitle(for: url))
        }

        return StyledMeetingTranscript(url: url, title: buildTitle(for: document))
    }

    private static func styledTranscript(at url: URL, persistChanges: Bool) -> StyledMeetingTranscript {
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
            let explicitTitle = frontmatter.values["title"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let title = explicitTitle?.isEmpty == false
                ? explicitTitle ?? fallbackTitle(for: url)
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

        let renderedFrontmatter = renderFrontmatter(lines: document.frontmatterLines, title: title)
        let body = renderBody(document: document, title: title)
        let updated = renderedFrontmatter + "\n\n" + body + "\n"
        let finalURL = renameTranscriptArtifactsIfNeeded(at: url, title: title, recordedAt: document.recordedAt)

        if updated != raw {
            do {
                try updated.write(to: finalURL, atomically: true, encoding: .utf8)
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

        return StyledMeetingTranscript(url: finalURL, title: title)
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
        let transcriptEntries = extractTranscriptEntries(from: frontmatter.body)

        let duration = values["duration"] ?? "0:00"
        let words = Int(values["total_word_count"] ?? "") ?? 0
        let utterances = (Int(values["mic_utterances"] ?? "") ?? 0) + (Int(values["system_utterances"] ?? "") ?? 0)

        return ParsedDocument(
            frontmatterLines: frontmatter.lines,
            explicitTitle: values["title"]?.trimmingCharacters(in: .whitespacesAndNewlines),
            recordedAt: recordedAt,
            duration: duration,
            durationSeconds: TranscriptFrontmatter.durationSeconds(from: duration) ?? 0,
            totalWords: words,
            totalUtterances: utterances,
            transcriptEntries: transcriptEntries,
            localSummaryBlock: LocalMeetingSummaryMarkdownUpdater.localSummaryBlock(in: frontmatter.body)
        )
    }

    private static func frontmatterTitle(at url: URL) -> String? {
        guard let values = try? TranscriptFrontmatter.readValues(
            from: url,
            byteLimit: frontmatterPreviewByteLimit
        ) else {
            return nil
        }

        let title = values["title"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title?.isEmpty == false ? title : nil
    }

    private static func parseRecordedAt(values: [String: String], fallbackURL: URL) -> Date {
        if let parsed = TranscriptFrontmatter.recordedAt(values: values) {
            return parsed
        }

        let resourceValues = try? fallbackURL.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return resourceValues?.creationDate ?? resourceValues?.contentModificationDate ?? Date()
    }

    private static func extractTranscriptEntries(from body: String) -> [TranscriptEntry] {
        for block in transcriptBlocks(in: body) {
            let entries = parseTranscriptEntries(from: block)
            if !entries.isEmpty { return entries }
        }

        return parseTranscriptEntries(from: body.trimmingCharacters(in: .whitespacesAndNewlines))
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

    private static func renderFrontmatter(lines: [String], title: String) -> String {
        // Preserve every writer key except `title:` (re-emitted first with the
        // styled title) and `transcript_style:`. The persisted restyle rewrites
        // the body into the styled grammar, so the style marker is replaced with
        // `styled` — filter-then-append keeps it from duplicating on repeat
        // passes. `format_version` passes through untouched.
        // See docs/capture-format.md.
        var filtered = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.hasPrefix("title:") && !trimmed.hasPrefix("transcript_style:")
        }
        filtered.append("transcript_style: styled")
        let escapedTitle = title.replacingOccurrences(of: "\"", with: "'")
        return ([
            "---",
            "title: \"\(escapedTitle)\""
        ] + filtered + ["---"]).joined(separator: "\n")
    }

    private static func renderBody(document: ParsedDocument, title: String) -> String {
        var detailParts = [
            "Recorded \(detailString(from: document.recordedAt))",
            formatDuration(document.durationSeconds, fallback: document.duration)
        ]
        if document.totalWords > 0 {
            detailParts.append("\(document.totalWords) \(document.totalWords == 1 ? "word" : "words")")
        }
        if document.totalUtterances > 0 {
            detailParts.append("\(document.totalUtterances) \(document.totalUtterances == 1 ? "turn" : "turns")")
        }

        let transcriptBlock = document.transcriptEntries.isEmpty
            ? emptyTranscriptPlaceholder
            : document.transcriptEntries.map { entry in
                """
                **\(entry.timestamp)**  [\(entry.label)]
                \(entry.text)
                """
            }.joined(separator: "\n\n")

        var rendered = """
        # \(title)

        \(detailParts.joined(separator: "  •  "))

        ## Transcript

        \(transcriptBlock)
        """
        if let localSummaryBlock = document.localSummaryBlock {
            rendered += "\n\n\(localSummaryBlock)"
        }
        return rendered
    }

    private static func buildTitle(for document: ParsedDocument) -> String {
        if let explicitTitle = document.explicitTitle,
           !explicitTitle.isEmpty {
            return explicitTitle
        }

        let namedRemoteParticipants = Array(
            LinkedSet(document.transcriptEntries.compactMap { entry -> String? in
                guard entry.label.hasPrefix("System/") else { return nil }
                let name = String(entry.label.dropFirst("System/".count))
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
            detailFormatter.string(from: date)
        }
    }

    private static func parseTranscriptEntries(from block: String) -> [TranscriptEntry] {
        let chunks = block
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var entries: [TranscriptEntry] = []
        for chunk in chunks {
            if let entry = parseTranscriptEntry(from: chunk) {
                entries.append(entry)
            }
        }
        return entries
    }

    private static let transcriptTimestampRegex = try? NSRegularExpression(pattern: #"^\[?([0-9:]+)\]?\s+"#)

    private static func parseTranscriptEntry(from chunk: String) -> TranscriptEntry? {
        let lines = chunk
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard let firstLine = lines.first else { return nil }
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
        return TranscriptEntry(timestamp: timestamp, label: label, text: text)
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

    private static func renameTranscriptArtifactsIfNeeded(at url: URL, title: String, recordedAt: Date) -> URL {
        let preferredStem = MeetingArtifactRenamer.fileStem(
            date: recordedAt,
            title: title,
            fallback: url.deletingPathExtension().lastPathComponent
        )
        return MeetingArtifactRenamer.rename(
            transcriptAt: url,
            toStem: preferredStem,
            logFailure: { event, context in
                logFailure(event: event, message: "Failed to rename styled transcript artifact", context: context)
            }
        )
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
    let transcriptEntries: [TranscriptEntry]
    let localSummaryBlock: String?
}

private struct TranscriptEntry {
    let timestamp: String
    let label: String
    let text: String
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
