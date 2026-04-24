import Foundation

struct StyledMeetingTranscript {
    let url: URL
    let title: String
}

enum MeetingTranscriptStyler {
    private static let parseFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static let titleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "MMM d 'at' h:mm a"
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
        styledTranscript(at: url, persistChanges: true)
    }

    static func displayTranscript(at url: URL) -> StyledMeetingTranscript {
        styledTranscript(at: url, persistChanges: false)
    }

    private static func styledTranscript(at url: URL, persistChanges: Bool) -> StyledMeetingTranscript {
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

        guard let document = parseDocument(raw, fallbackURL: url) else {
            return StyledMeetingTranscript(
                url: url,
                title: fallbackTitle(for: url)
            )
        }

        let title = buildTitle(for: document)
        guard persistChanges else {
            return StyledMeetingTranscript(url: url, title: title)
        }

        let frontmatter = renderFrontmatter(lines: document.frontmatterLines, title: title)
        let body = renderBody(document: document, title: title)
        let updated = frontmatter + "\n\n" + body + "\n"
        let finalURL = renameTranscriptArtifactsIfNeeded(at: url, title: title)

        if updated != raw {
            do {
                try updated.write(to: finalURL, atomically: true, encoding: .utf8)
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
        return stripFrontmatter(from: raw)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseDocument(_ raw: String, fallbackURL: URL) -> ParsedDocument? {
        guard let body = stripFrontmatter(from: raw),
              raw.hasPrefix("---\n"),
              let endRange = raw.range(
                of: "\n---\n",
                range: raw.index(raw.startIndex, offsetBy: 4)..<raw.endIndex
              ) else {
            return nil
        }

        let frontmatterText = String(raw[raw.index(raw.startIndex, offsetBy: 4)..<endRange.lowerBound])
        let frontmatterLines = frontmatterText.components(separatedBy: "\n")

        var values: [String: String] = [:]
        for line in frontmatterLines {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            values[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }

        let recordedAt = parseRecordedAt(values: values, fallbackURL: fallbackURL)
        let transcriptEntries = extractTranscriptEntries(from: body)

        let duration = values["duration"] ?? "0:00"
        let words = Int(values["total_word_count"] ?? "") ?? 0
        let utterances = (Int(values["mic_utterances"] ?? "") ?? 0) + (Int(values["system_utterances"] ?? "") ?? 0)

        return ParsedDocument(
            frontmatterLines: frontmatterLines,
            explicitTitle: values["title"]?.trimmingCharacters(in: .whitespacesAndNewlines),
            recordedAt: recordedAt,
            duration: duration,
            durationSeconds: parseDurationSeconds(duration),
            totalWords: words,
            totalUtterances: utterances,
            transcriptEntries: transcriptEntries
        )
    }

    private static func parseRecordedAt(values: [String: String], fallbackURL: URL) -> Date {
        if let date = values["date"],
           let time = values["time"],
           let parsed = parsedRecordedAt(from: "\(date) \(time)") {
            return parsed
        }

        let resourceValues = try? fallbackURL.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return resourceValues?.creationDate ?? resourceValues?.contentModificationDate ?? Date()
    }

    private static func extractTranscriptEntries(from body: String) -> [TranscriptEntry] {
        let markers = ["## Full Transcript\n\n", "## Transcript\n\n"]

        for marker in markers {
            guard let start = body.range(of: marker) else { continue }
            let remaining = String(body[start.upperBound...])
            let endMarkers = ["\n---\n", "\n*Generated by ", "\n## "]
            let endIndex = endMarkers
                .compactMap { remaining.range(of: $0)?.lowerBound }
                .min() ?? remaining.endIndex
            let block = String(remaining[..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            let entries = parseTranscriptEntries(from: block)
            if !entries.isEmpty { return entries }
        }

        return parseTranscriptEntries(from: body.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func renderFrontmatter(lines: [String], title: String) -> String {
        let filtered = lines.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("title:") }
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
            ? "_No transcript captured._"
            : document.transcriptEntries.map { entry in
                """
                **\(entry.timestamp)**  [\(entry.label)]
                \(entry.text)
                """
            }.joined(separator: "\n\n")

        return """
        # \(title)

        \(detailParts.joined(separator: "  •  "))

        ## Transcript

        \(transcriptBlock)
        """
    }

    private static func stripFrontmatter(from raw: String) -> String? {
        guard raw.hasPrefix("---\n"),
              let endRange = raw.range(
                of: "\n---\n",
                range: raw.index(raw.startIndex, offsetBy: 4)..<raw.endIndex
              ) else {
            return nil
        }

        return String(raw[endRange.upperBound...])
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

    private static func parsedRecordedAt(from value: String) -> Date? {
        formatterQueue.sync {
            parseFormatter.date(from: value)
        }
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

    private static func parseDurationSeconds(_ duration: String) -> Int {
        let components = duration.split(separator: ":").compactMap { Int($0) }
        guard !components.isEmpty else { return 0 }
        if components.count == 2 {
            return components[0] * 60 + components[1]
        }
        if components.count == 3 {
            return components[0] * 3600 + components[1] * 60 + components[2]
        }
        return components[0]
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

    private static let transcriptEntryRegex = try? NSRegularExpression(pattern: #"^\[?([0-9:]+)\]?\s+\[(.+?)\](.*)$"#)

    private static func parseTranscriptEntry(from chunk: String) -> TranscriptEntry? {
        let lines = chunk
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard let firstLine = lines.first else { return nil }
        let normalizedHeader = firstLine
            .replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let regex = transcriptEntryRegex else {
            return nil
        }

        let nsHeader = normalizedHeader as NSString
        let range = NSRange(location: 0, length: nsHeader.length)
        guard let match = regex.firstMatch(in: normalizedHeader, range: range),
              match.numberOfRanges >= 4 else {
            return nil
        }

        let timestamp = nsHeader.substring(with: match.range(at: 1))
        let label = nsHeader.substring(with: match.range(at: 2))
        let inlineTail = nsHeader.substring(with: match.range(at: 3)).trimmingCharacters(in: .whitespaces)
        let textLines = (inlineTail.isEmpty ? Array(lines.dropFirst()) : [inlineTail] + Array(lines.dropFirst()))
        let text = textLines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return TranscriptEntry(timestamp: timestamp, label: label, text: text)
    }

    private static func formatDuration(_ seconds: Int, fallback: String) -> String {
        guard seconds > 0 else { return fallback }

        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .short
        formatter.zeroFormattingBehavior = .dropAll
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : (seconds >= 60 ? [.minute, .second] : [.second])

        return formatter.string(from: TimeInterval(seconds)) ?? fallback
    }

    private static func renameTranscriptArtifactsIfNeeded(at url: URL, title: String) -> URL {
        let sanitizedStem = sanitizedFileStem(
            for: title,
            fallback: url.deletingPathExtension().lastPathComponent
        )
        let targetURL = uniqueTranscriptURL(
            in: url.deletingLastPathComponent(),
            preferredStem: sanitizedStem,
            originalURL: url
        )

        guard targetURL != url else { return url }

        let fm = FileManager.default

        do {
            try fm.moveItem(at: url, to: targetURL)
            renameAudioDirectoryIfNeeded(
                from: audioDirectoryURL(for: url),
                to: audioDirectoryURL(for: targetURL)
            )
            return targetURL
        } catch {
            logFailure(
                event: "meeting_transcript_rename_failed",
                message: "Failed to rename styled transcript",
                context: [
                    "from": url.lastPathComponent,
                    "to": targetURL.lastPathComponent,
                    "error": error.localizedDescription
                ]
            )
            return url
        }
    }

    private static func audioDirectoryURL(for transcriptURL: URL) -> URL {
        transcriptURL
            .deletingLastPathComponent()
            .appendingPathComponent("audio", isDirectory: true)
            .appendingPathComponent("\(transcriptURL.deletingPathExtension().lastPathComponent)_audio", isDirectory: true)
    }

    private static func renameAudioDirectoryIfNeeded(from sourceURL: URL, to targetURL: URL) {
        let fm = FileManager.default
        guard sourceURL != targetURL, fm.fileExists(atPath: sourceURL.path) else { return }

        let finalURL = uniqueAudioDirectoryURL(preferredURL: targetURL)

        do {
            try fm.moveItem(at: sourceURL, to: finalURL)
        } catch {
            logFailure(
                event: "meeting_audio_directory_rename_failed",
                message: "Failed to rename retained meeting audio",
                context: [
                    "from": sourceURL.lastPathComponent,
                    "to": finalURL.lastPathComponent,
                    "error": error.localizedDescription
                ]
            )
        }
    }

    private static func uniqueAudioDirectoryURL(preferredURL: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: preferredURL.path) else { return preferredURL }

        let directory = preferredURL.deletingLastPathComponent()
        let stem = preferredURL.lastPathComponent
        var suffix = 2

        while suffix <= 999 {
            let candidate = directory.appendingPathComponent("\(stem) \(suffix)", isDirectory: true)
            if !fm.fileExists(atPath: candidate.path) {
                return candidate
            }
            suffix += 1
        }
        return directory.appendingPathComponent("\(stem) \(UUID().uuidString)", isDirectory: true)
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

    private static func sanitizedFileStem(for title: String, fallback: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let collapsedWhitespace = title
            .replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: invalidCharacters)
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let limited = String(collapsedWhitespace.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
        return limited.isEmpty ? fallback : limited
    }

    private static func uniqueTranscriptURL(in directory: URL, preferredStem: String, originalURL: URL) -> URL {
        let fm = FileManager.default
        var candidateStem = preferredStem
        var suffix = 2

        while suffix <= 999 {
            let candidateURL = directory.appendingPathComponent(candidateStem).appendingPathExtension("md")
            let markdownTaken = candidateURL != originalURL && fm.fileExists(atPath: candidateURL.path)

            if !markdownTaken {
                return candidateURL
            }

            candidateStem = "\(preferredStem) \(suffix)"
            suffix += 1
        }
        return directory.appendingPathComponent("\(preferredStem) \(UUID().uuidString)").appendingPathExtension("md")
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
