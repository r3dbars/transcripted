import Foundation

/// Which saved meetings a dictionary correction would still change.
struct DictionaryPastMeetingScan: Equatable, Sendable {
    let meetingURLs: [URL]

    var meetingCount: Int { meetingURLs.count }
}

/// One meeting file a fix rewrote, kept so the fix can be undone.
struct DictionaryPastMeetingFileChange: Equatable, Sendable {
    let url: URL
    let originalMarkdown: String
    let updatedMarkdown: String
}

/// What "Fix them" changed for one correction.
struct DictionaryPastMeetingFixReceipt: Equatable, Sendable {
    let entry: CustomDictionaryEntry
    let changes: [DictionaryPastMeetingFileChange]
    /// Meetings that matched but were busy (being re-transcribed) or could not
    /// be read or written. They are left exactly as they were.
    let skippedCount: Int

    var fixedCount: Int { changes.count }
}

struct DictionaryPastMeetingUndoResult: Equatable, Sendable {
    let restoredURLs: [URL]
    /// Meetings that changed again after the fix (a rename, a re-transcribe,
    /// another fix), so undo left the newer version alone.
    let keptCount: Int
}

/// Copy for the line under a correction in Settings. Kept out of the SwiftUI
/// file so fast tests can pin it.
enum DictionaryPastMeetingFixCopy {
    static func found(_ meetings: Int) -> String {
        "Also in \(meetingPhrase(meetings))."
    }

    static let fixAction = "Fix them"
    static let fixing = "Fixing…"
    static let undoing = "Putting back…"
    static let undoAction = "Undo"

    static func fixed(_ receipt: DictionaryPastMeetingFixReceipt) -> String {
        guard receipt.fixedCount > 0 else {
            return "Couldn\u{2019}t fix those meetings right now. Try again in a moment."
        }
        let fixed = "Fixed \(receipt.fixedCount) \(receipt.fixedCount == 1 ? "meeting" : "meetings")."
        guard receipt.skippedCount > 0 else { return fixed }
        return fixed + " \(receipt.skippedCount) \(receipt.skippedCount == 1 ? "was" : "were") busy, so try again later."
    }

    static func undone(_ result: DictionaryPastMeetingUndoResult) -> String? {
        guard result.keptCount > 0 else { return nil }
        return "\(meetingPhrase(result.keptCount).capitalizedFirst) changed since, so \(result.keptCount == 1 ? "it was" : "they were") kept."
    }

    private static func meetingPhrase(_ count: Int) -> String {
        count == 1 ? "1 past meeting" : "\(count) past meetings"
    }
}

private extension String {
    var capitalizedFirst: String {
        prefix(1).uppercased() + dropFirst()
    }
}

/// Applies a Settings dictionary correction to meetings that were saved before
/// the correction existed. New meetings already get the dictionary at
/// transcription time; this is the same rule run over the saved Markdown.
///
/// Only spoken text changes. Frontmatter, headings, the "Recorded …" line, the
/// footer, timestamps and speaker labels are left alone (speaker names have
/// their own editor, which also keeps the speaker database in sync). Line
/// breaks are never added or removed.
enum DictionaryPastMeetingFix {
    private static let excludedMarkdownFilenames: Set<String> = ["AGENT.md", "CLAUDE.md"]

    // MARK: - Library

    /// Saved meeting transcripts directly in the meetings folder, newest name
    /// first. Mirrors the Home scanner's file filter.
    static func meetingTranscriptURLs(
        in directory: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls
            .filter { url in
                url.pathExtension == "md"
                    && !url.deletingPathExtension().lastPathComponent.hasSuffix(".summary")
                    && !excludedMarkdownFilenames.contains(url.lastPathComponent)
                    && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) != false
            }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// For each correction, the saved meetings it would still change. Each file
    /// is read once. Corrections with no matches are left out of the result.
    static func scan(
        entries: [CustomDictionaryEntry],
        in directory: URL,
        fileManager: FileManager = .default,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) -> [CustomDictionaryEntry: DictionaryPastMeetingScan] {
        let matchers = entries.compactMap { entry -> (CustomDictionaryEntry, NSRegularExpression, String)? in
            guard let regex = CustomDictionaryTextProcessor.matcher(for: entry.spoken),
                  let firstWord = entry.spoken.split(whereSeparator: \.isWhitespace).first else {
                return nil
            }
            return (entry, regex, String(firstWord))
        }
        guard !matchers.isEmpty else { return [:] }

        var found: [CustomDictionaryEntry: [URL]] = [:]
        for url in meetingTranscriptURLs(in: directory, fileManager: fileManager) {
            if isCancelled() { return [:] }
            guard let markdown = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let segments = spokenSegments(in: markdown)
            guard !segments.isEmpty else { continue }
            let spoken = segments.joined(separator: "\n")

            for (entry, regex, firstWord) in matchers {
                // Cheap prefilter so a long dictionary doesn't run every regex
                // over every meeting.
                guard spoken.range(of: firstWord, options: [.caseInsensitive, .diacriticInsensitive]) != nil else {
                    continue
                }
                if segments.contains(where: { countFixes(of: entry, regex: regex, in: $0) > 0 }) {
                    found[entry, default: []].append(url)
                }
            }
        }
        return found.mapValues(DictionaryPastMeetingScan.init(meetingURLs:))
    }

    // MARK: - File updates

    /// Rewrites every listed meeting that still has something to fix. A meeting
    /// that is being re-transcribed, or can't be read or written, is skipped and
    /// counted, never half-written.
    static func fix(
        _ entry: CustomDictionaryEntry,
        meetingsAt urls: [URL],
        fileManager: FileManager = .default
    ) -> DictionaryPastMeetingFixReceipt {
        var changes: [DictionaryPastMeetingFileChange] = []
        var skipped = 0

        for url in urls {
            do {
                let change: DictionaryPastMeetingFileChange? = try MeetingTranscriptFileUpdateSerializer.sync(protecting: [url]) { () throws -> DictionaryPastMeetingFileChange? in
                    let raw = try String(contentsOf: url, encoding: .utf8)
                    let result = replacing(entry, in: raw)
                    guard result.count > 0, result.markdown != raw else { return nil }
                    try result.markdown.write(to: url, atomically: true, encoding: .utf8)
                    fileManager.restrictFileToOwnerOnly(at: url)
                    return DictionaryPastMeetingFileChange(
                        url: url,
                        originalMarkdown: raw,
                        updatedMarkdown: result.markdown
                    )
                }
                if let change {
                    changes.append(change)
                }
            } catch {
                skipped += 1
            }
        }

        return DictionaryPastMeetingFixReceipt(entry: entry, changes: changes, skippedCount: skipped)
    }

    /// Puts each meeting back exactly as it was, but only when nothing else has
    /// written it since the fix. Otherwise undo would silently throw that work away.
    static func undo(
        _ receipt: DictionaryPastMeetingFixReceipt,
        fileManager: FileManager = .default
    ) -> DictionaryPastMeetingUndoResult {
        var restored: [URL] = []
        var kept = 0

        for change in receipt.changes {
            do {
                let didRestore: Bool = try MeetingTranscriptFileUpdateSerializer.sync(protecting: [change.url]) { () throws -> Bool in
                    let current = try String(contentsOf: change.url, encoding: .utf8)
                    guard current == change.updatedMarkdown else { return false }
                    try change.originalMarkdown.write(to: change.url, atomically: true, encoding: .utf8)
                    fileManager.restrictFileToOwnerOnly(at: change.url)
                    return true
                }
                if didRestore {
                    restored.append(change.url)
                } else {
                    kept += 1
                }
            } catch {
                kept += 1
            }
        }

        return DictionaryPastMeetingUndoResult(restoredURLs: restored, keptCount: kept)
    }

    // MARK: - Pure text

    /// How many spots in a meeting's spoken text the correction would change.
    static func fixCount(of entry: CustomDictionaryEntry, in markdown: String) -> Int {
        guard let regex = CustomDictionaryTextProcessor.matcher(for: entry.spoken) else { return 0 }
        return spokenSegments(in: markdown).reduce(0) { total, segment in
            total + countFixes(of: entry, regex: regex, in: segment)
        }
    }

    static func replacing(
        _ entry: CustomDictionaryEntry,
        in markdown: String
    ) -> (markdown: String, count: Int) {
        guard let regex = CustomDictionaryTextProcessor.matcher(for: entry.spoken) else {
            return (markdown, 0)
        }
        var count = 0
        let rewritten = forEachSpokenSegment(in: markdown) { segment in
            let ranges = fixRanges(of: entry, regex: regex, in: segment)
            guard !ranges.isEmpty else { return nil }
            count += ranges.count
            let mutable = NSMutableString(string: segment)
            for range in ranges.reversed() {
                mutable.replaceCharacters(in: range, with: entry.replacement)
            }
            return mutable as String
        }
        return (rewritten, count)
    }

    private static func countFixes(
        of entry: CustomDictionaryEntry,
        regex: NSRegularExpression,
        in segment: String
    ) -> Int {
        fixRanges(of: entry, regex: regex, in: segment).count
    }

    /// Matches that would actually change something. A match is skipped when
    /// the text around it already reads as the replacement: "PostHog" already
    /// cased right, or "Claude Code" for a "claude -> Claude Code" rule. That
    /// keeps a fix from stacking ("Claude Code Code") and makes a second run
    /// find nothing, so the Settings line goes away once a meeting is fixed.
    private static func fixRanges(
        of entry: CustomDictionaryEntry,
        regex: NSRegularExpression,
        in segment: String
    ) -> [NSRange] {
        let text = segment as NSString
        let replacement = entry.replacement as NSString
        return regex
            .matches(in: segment, range: NSRange(location: 0, length: text.length))
            .map(\.range)
            .filter { !isAlreadyReplacement($0, in: text, replacement: replacement) }
    }

    private static func isAlreadyReplacement(
        _ match: NSRange,
        in text: NSString,
        replacement: NSString
    ) -> Bool {
        let length = replacement.length
        guard length >= match.length else { return false }
        let earliest = max(0, NSMaxRange(match) - length)
        let latest = min(match.location, text.length - length)
        guard earliest <= latest else { return false }
        for start in earliest...latest {
            if text.substring(with: NSRange(location: start, length: length)) == replacement as String {
                return true
            }
        }
        return false
    }

    static func spokenSegments(in markdown: String) -> [String] {
        var segments: [String] = []
        forEachSpokenSegment(in: markdown) { segment in
            segments.append(segment)
            return nil
        }
        return segments
    }

    /// Walks the spoken-text part of every transcript line. `transform` returns
    /// replacement text for a segment, or nil to keep it. Only files with a
    /// `## Transcript` / `## Full Transcript` heading are touched: everything
    /// after that heading, up to the footer.
    @discardableResult
    private static func forEachSpokenSegment(
        in markdown: String,
        _ transform: (String) -> String?
    ) -> String {
        var lines = markdown.components(separatedBy: "\n")

        var bodyStart = 0
        if lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" {
            guard let closing = lines.indices.dropFirst().first(where: {
                lines[$0].trimmingCharacters(in: .whitespacesAndNewlines) == "---"
            }) else {
                // Unterminated frontmatter: nothing is safely spoken text.
                return markdown
            }
            bodyStart = closing + 1
        }

        guard let heading = lines.indices.dropFirst(bodyStart).first(where: {
            let trimmed = lines[$0].trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed == "## Full Transcript" || trimmed == "## Transcript"
        }) else {
            return markdown
        }

        var changed = false
        for index in lines.indices.dropFirst(heading + 1) {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "---"
                || trimmed.hasPrefix("*Generated by Transcripted")
                || trimmed.hasPrefix("**Participants:**") {
                break
            }
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("Recorded ") {
                continue
            }

            let textStart = spokenTextStart(in: line)
            let segment = String(line[textStart...])
            guard !segment.isEmpty, let replaced = transform(segment) else { continue }
            lines[index] = String(line[..<textStart]) + replaced
            changed = true
        }

        return changed ? lines.joined(separator: "\n") : markdown
    }

    /// Where the spoken words begin on a line. Turn headers look like
    /// `**00:12**  [Mic/Linus]` (styled) or `[00:01] [System/[[Alex]]] Hello`
    /// (legacy); both the time and the speaker label are skipped. Any other
    /// line is spoken text from its first character.
    private static func spokenTextStart(in line: String) -> String.Index {
        guard let first = line.firstIndex(where: { !$0.isWhitespace }) else { return line.endIndex }
        var cursor: String.Index

        if line[first...].hasPrefix("**") {
            let timeStart = line.index(first, offsetBy: 2)
            guard let close = line.range(of: "**", range: timeStart..<line.endIndex),
                  looksLikeTimestamp(line[timeStart..<close.lowerBound]) else {
                return line.startIndex
            }
            cursor = close.upperBound
        } else if line[first] == "[" {
            let timeStart = line.index(after: first)
            guard let close = line[timeStart...].firstIndex(of: "]"),
                  looksLikeTimestamp(line[timeStart..<close]) else {
                return line.startIndex
            }
            cursor = line.index(after: close)
        } else {
            return line.startIndex
        }

        while cursor < line.endIndex, line[cursor].isWhitespace {
            cursor = line.index(after: cursor)
        }
        if cursor < line.endIndex, line[cursor] == "[",
           let labelEnd = matchingClosingBracket(in: line, from: cursor) {
            cursor = line.index(after: labelEnd)
        }
        return cursor
    }

    /// Outer closing bracket, so `[System/[[Alex]]]` doesn't stop inside the link.
    private static func matchingClosingBracket(in line: String, from start: String.Index) -> String.Index? {
        var depth = 0
        var index = start
        while index < line.endIndex {
            switch line[index] {
            case "[":
                depth += 1
            case "]":
                depth -= 1
                if depth == 0 { return index }
            default:
                break
            }
            index = line.index(after: index)
        }
        return nil
    }

    private static func looksLikeTimestamp(_ value: Substring) -> Bool {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return false }
        return parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }
}
