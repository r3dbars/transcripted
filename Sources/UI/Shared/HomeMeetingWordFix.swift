import Foundation

/// How "Fix a word" matches. The defaults are the safe ones: a misheard
/// word is usually a name or a term, so "Al" should not also rewrite
/// "Alex", and a correction to "Cloud" should not touch "cloud".
struct HomeMeetingWordFixOptions: Equatable, Sendable {
    var matchCase: Bool = true
    var wholeWords: Bool = true
}

/// What a completed fix changed, kept so the user can undo it.
struct HomeMeetingWordFixReceipt: Equatable, Sendable {
    let transcriptURL: URL
    let find: String
    let replacement: String
    let count: Int
    let originalMarkdown: String
    let updatedMarkdown: String
}

enum HomeMeetingWordFixAction: Equatable, Sendable {
    case replace(find: String, replacement: String, options: HomeMeetingWordFixOptions)
    case undo(HomeMeetingWordFixReceipt)
}

enum HomeMeetingWordFixOutcome: Equatable, Sendable {
    case replaced(HomeMeetingWordFixReceipt)
    case undone(HomeMeetingWordFixReceipt)
    case failed(HomeMeetingWordFixError)
}

enum HomeMeetingWordFixError: Error, Equatable, LocalizedError, Sendable {
    case emptyWord
    case emptyReplacement
    case noMatches
    case readFailed
    case writeFailed
    case changedSinceFix
    case meetingClosed
    case retranscriptionInProgress

    var errorDescription: String? {
        switch self {
        case .emptyWord:
            return "Type the word to fix."
        case .emptyReplacement:
            return "Type what it should say."
        case .noMatches:
            return "That word isn't in this transcript."
        case .readFailed:
            return "The meeting transcript could not be read."
        case .writeFailed:
            return "The meeting transcript could not be updated."
        case .changedSinceFix:
            return "The transcript changed after that fix, so Transcripted left it as is."
        case .meetingClosed:
            return "Open the meeting again and retry."
        case .retranscriptionInProgress:
            return "That meeting is being re-transcribed. Try again when it finishes."
        }
    }
}

/// Copy for the "Fix a word" bar, kept out of the SwiftUI file so fast
/// tests can pin it.
enum HomeMeetingWordFixCopy {
    static func matchCount(_ count: Int) -> String {
        switch count {
        case 0: return "No matches"
        case 1: return "1 match"
        default: return "\(count) matches"
        }
    }

    static func fixed(_ receipt: HomeMeetingWordFixReceipt) -> String {
        let spots = receipt.count == 1 ? "1 spot" : "\(receipt.count) spots"
        return "Changed \u{201C}\(receipt.find)\u{201D} to \u{201C}\(receipt.replacement)\u{201D} in \(spots)."
    }

    static func undone(_ receipt: HomeMeetingWordFixReceipt) -> String {
        "Put back \u{201C}\(receipt.find)\u{201D}."
    }
}

/// Find-and-replace for one saved meeting transcript, from the Home
/// expansion's "Fix a word" bar.
///
/// Only the spoken text changes. Frontmatter, headings, the "Recorded …"
/// line, the footer, timestamps and speaker labels are left alone (speaker
/// names have their own editor, which also keeps the speaker database in
/// sync). Line breaks are never added or removed, so the transcript keeps
/// the same paragraphs it had before.
enum HomeMeetingWordFix {
    // MARK: - File updates

    static func perform(
        _ action: HomeMeetingWordFixAction,
        transcriptAt url: URL,
        fileManager: FileManager = .default
    ) -> HomeMeetingWordFixOutcome {
        do {
            switch action {
            case .replace(let find, let replacement, let options):
                return .replaced(try apply(
                    find: find,
                    replacement: replacement,
                    options: options,
                    transcriptAt: url,
                    fileManager: fileManager
                ))
            case .undo(let receipt):
                try undo(receipt, fileManager: fileManager)
                return .undone(receipt)
            }
        } catch let error as HomeMeetingWordFixError {
            return .failed(error)
        } catch {
            return .failed(.writeFailed)
        }
    }

    @discardableResult
    static func apply(
        find rawFind: String,
        replacement rawReplacement: String,
        options: HomeMeetingWordFixOptions = HomeMeetingWordFixOptions(),
        transcriptAt url: URL,
        fileManager: FileManager = .default
    ) throws -> HomeMeetingWordFixReceipt {
        let find = normalized(rawFind)
        let replacement = normalized(rawReplacement)
        guard !find.isEmpty else { throw HomeMeetingWordFixError.emptyWord }
        guard !replacement.isEmpty else { throw HomeMeetingWordFixError.emptyReplacement }

        do {
            return try MeetingTranscriptFileUpdateSerializer.sync(protecting: [url]) {
                let raw: String
                do {
                    raw = try String(contentsOf: url, encoding: .utf8)
                } catch {
                    throw HomeMeetingWordFixError.readFailed
                }

                let result = replacing(find, with: replacement, in: raw, options: options)
                guard result.count > 0 else { throw HomeMeetingWordFixError.noMatches }

                if result.markdown != raw {
                    do {
                        try result.markdown.write(to: url, atomically: true, encoding: .utf8)
                        fileManager.restrictFileToOwnerOnly(at: url)
                    } catch {
                        throw HomeMeetingWordFixError.writeFailed
                    }
                }
                return HomeMeetingWordFixReceipt(
                    transcriptURL: url,
                    find: find,
                    replacement: replacement,
                    count: result.count,
                    originalMarkdown: raw,
                    updatedMarkdown: result.markdown
                )
            }
        } catch MeetingTranscriptFileUpdateError.replacementInProgress {
            throw HomeMeetingWordFixError.retranscriptionInProgress
        }
    }

    /// Puts the transcript back exactly as it was before `receipt`, but only
    /// when nothing else (a speaker rename, a re-transcribe, another fix) has
    /// written the file since. Otherwise undo would silently throw that work away.
    static func undo(
        _ receipt: HomeMeetingWordFixReceipt,
        fileManager: FileManager = .default
    ) throws {
        do {
            try MeetingTranscriptFileUpdateSerializer.sync(protecting: [receipt.transcriptURL]) { () throws -> Void in
                let current: String
                do {
                    current = try String(contentsOf: receipt.transcriptURL, encoding: .utf8)
                } catch {
                    throw HomeMeetingWordFixError.readFailed
                }
                guard current == receipt.updatedMarkdown else {
                    throw HomeMeetingWordFixError.changedSinceFix
                }
                guard current != receipt.originalMarkdown else { return }
                do {
                    try receipt.originalMarkdown.write(to: receipt.transcriptURL, atomically: true, encoding: .utf8)
                    fileManager.restrictFileToOwnerOnly(at: receipt.transcriptURL)
                } catch {
                    throw HomeMeetingWordFixError.writeFailed
                }
            }
        } catch MeetingTranscriptFileUpdateError.replacementInProgress {
            throw HomeMeetingWordFixError.retranscriptionInProgress
        }
    }

    // MARK: - Pure text

    /// Single-line and trimmed. A newline in either field would split a
    /// transcript turn, which is the one thing this must never do.
    static func normalized(_ raw: String) -> String {
        raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func matchCount(
        of rawFind: String,
        in markdown: String,
        options: HomeMeetingWordFixOptions = HomeMeetingWordFixOptions()
    ) -> Int {
        let find = normalized(rawFind)
        guard !find.isEmpty, let regex = matcher(for: find, options: options) else { return 0 }
        var count = 0
        forEachTranscriptTextSegment(in: markdown) { segment in
            count += regex.numberOfMatches(
                in: segment,
                range: NSRange(segment.startIndex..., in: segment)
            )
            return nil
        }
        return count
    }

    static func replacing(
        _ rawFind: String,
        with rawReplacement: String,
        in markdown: String,
        options: HomeMeetingWordFixOptions = HomeMeetingWordFixOptions()
    ) -> (markdown: String, count: Int) {
        let find = normalized(rawFind)
        let replacement = normalized(rawReplacement)
        guard !find.isEmpty, let regex = matcher(for: find, options: options) else {
            return (markdown, 0)
        }
        let template = NSRegularExpression.escapedTemplate(for: replacement)
        var count = 0
        let rewritten = forEachTranscriptTextSegment(in: markdown) { segment in
            let range = NSRange(segment.startIndex..., in: segment)
            let matches = regex.numberOfMatches(in: segment, range: range)
            guard matches > 0 else { return nil }
            count += matches
            return regex.stringByReplacingMatches(in: segment, range: range, withTemplate: template)
        }
        return (rewritten, count)
    }

    private static func matcher(
        for find: String,
        options: HomeMeetingWordFixOptions
    ) -> NSRegularExpression? {
        var pattern = NSRegularExpression.escapedPattern(for: find)
        if options.wholeWords {
            // Letters and digits in any script count as word characters, so
            // "Al" skips "Alex" and "café" works. Punctuation (including an
            // apostrophe) ends a word, so "Linus" still fixes "Linus's".
            pattern = #"(?<![\p{L}\p{N}_])"# + pattern + #"(?![\p{L}\p{N}_])"#
        }
        return try? NSRegularExpression(
            pattern: pattern,
            options: options.matchCase ? [] : [.caseInsensitive]
        )
    }

    /// Walks the spoken-text part of every transcript line. `transform`
    /// returns replacement text for a segment, or nil to keep it. The same
    /// sections the Home preview reads are in scope: everything after the
    /// `## Transcript` / `## Full Transcript` heading (or after the
    /// frontmatter when there is no heading), up to the footer.
    @discardableResult
    private static func forEachTranscriptTextSegment(
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

        var start = bodyStart
        if let heading = lines.indices.dropFirst(bodyStart).first(where: {
            let trimmed = lines[$0].trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed == "## Full Transcript" || trimmed == "## Transcript"
        }) {
            start = heading + 1
        }

        var changed = false
        for index in lines.indices.dropFirst(start) {
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
            guard let replaced = transform(segment) else { continue }
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
