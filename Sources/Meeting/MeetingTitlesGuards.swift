import Foundation

/// What the titles model wrote for one meeting, after the guards. Any field
/// can be missing; a missing title keeps the app's own title.
struct MeetingTitlesLabel: Equatable, Sendable {
    let title: String?
    let line: String?
    let summary: String?

    var isEmpty: Bool { title == nil && line == nil && summary == nil }
}

/// Deterministic checks on the model's reply. Small models drift: they echo
/// the prompt, pad titles, run long, and get who-owes-what wrong, so every
/// field is trimmed or dropped here before anything is saved.
enum MeetingTitlesGuards {
    static let maxTitleWords = 6
    static let maxLineSentences = 2
    static let maxLineWords = 45
    static let maxSummarySentences = 3
    /// Caps for text written without spaces (Chinese, Japanese), where a
    /// word count means nothing.
    static let maxUnspacedTitleCharacters = 20
    static let maxUnspacedLineCharacters = 90

    /// Parses `{title, line, summary}` and runs every guard. Nil when the
    /// reply isn't that JSON object.
    static func label(fromModelReply reply: String) -> MeetingTitlesLabel? {
        guard let fields = parseReply(reply) else { return nil }
        let summary = self.summary(fields.summary)
        return MeetingTitlesLabel(
            title: title(fields.title),
            line: line(fields.line, summaryFallback: fields.summary),
            summary: summary
        )
    }

    static func parseReply(_ reply: String) -> (title: String, line: String, summary: String)? {
        var text = reply
        if let thinkEnd = text.range(of: "</think>") {
            text = String(text[thinkEnd.upperBound...])
        }
        guard let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close,
              let data = String(text[open...close]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = object["title"] as? String,
              let line = object["line"] as? String,
              let summary = object["summary"] as? String else { return nil }
        return (title, line, summary)
    }

    // MARK: - Title

    private static let quoteCharacters = CharacterSet(charactersIn: "\"'`“”‘’«»*#_")
    private static let trailingPunctuation = CharacterSet(charactersIn: ".,;:!?…-–—")
    private static let danglingWords: Set<String> = [
        "and", "or", "of", "the", "a", "an", "to", "for", "with", "in", "on", "at", "&", "vs",
    ]
    /// A title made only of these says nothing about the meeting.
    private static let emptyTitleWords: Set<String> = [
        "meeting", "meetings", "call", "calls", "summary", "discussion", "discussions",
        "update", "updates", "sync", "notes", "transcript", "title", "untitled", "recording",
        "conversation", "chat", "session", "the", "a", "an", "and", "of", "with", "weekly",
        "daily", "quick", "team", "general", "misc", "miscellaneous", "today",
    ]
    /// Pieces of the prompt or the reply format showing up in the title.
    private static let promptEchoes = [
        "<transcript", "transcript>", "json", "reply with", "2 to 5 words", "file name",
        "label recorded", "title:", "line:", "summary:", "speech recognition", "{", "}",
    ]

    static func title(_ raw: String) -> String? {
        var title = collapsedWhitespace(raw)
        if title.lowercased().hasPrefix("title:") {
            title = String(title.dropFirst("title:".count))
        }
        title = trimmedTitleEdges(title)
        if isUnspaced(title), title.count > maxUnspacedTitleCharacters {
            title = trimmedTitleEdges(String(title.prefix(maxUnspacedTitleCharacters)))
        }
        var words = title.split(separator: " ").map(String.init)
        if words.count > maxTitleWords {
            words = Array(words.prefix(maxTitleWords))
            while let last = words.last, danglingWords.contains(last.lowercased()) {
                words.removeLast()
            }
            title = trimmedTitleEdges(words.joined(separator: " "))
            words = title.split(separator: " ").map(String.init)
        }
        guard !title.isEmpty else { return nil }
        let lowered = title.lowercased()
        if promptEchoes.contains(where: { lowered.contains($0) }) { return nil }
        let meaningful = words.contains { word in
            let bare = word.lowercased().trimmingCharacters(in: .punctuationCharacters)
            return !bare.isEmpty && !emptyTitleWords.contains(bare)
        }
        return meaningful ? title : nil
    }

    private static func trimmedTitleEdges(_ raw: String) -> String {
        var title = raw
        while true {
            let next = title
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: quoteCharacters)
                .trimmingCharacters(in: .whitespaces)
            let withoutTrailing = String(next.reversed().drop(while: { character in
                character.unicodeScalars.allSatisfy { trailingPunctuation.contains($0) || $0 == " " }
            }).reversed())
            if withoutTrailing == title { return title }
            title = withoutTrailing
        }
    }

    // MARK: - Line and summary

    /// At most two whole sentences and about 45 words; sentences that hand
    /// the recorder a task are dropped. Falls back to the summary's first
    /// clean sentence, then to nothing.
    static func line(_ raw: String, summaryFallback: String?) -> String? {
        var kept: [String] = []
        var words = 0
        for sentence in cleanSentences(raw) {
            guard kept.count < maxLineSentences else { break }
            let count = lineLength(sentence)
            guard words + count <= lineLimit(sentence) else { break }
            kept.append(sentence)
            words += count
        }
        if !kept.isEmpty { return joined(kept) }
        guard let summaryFallback,
              let first = cleanSentences(summaryFallback).first,
              lineLength(first) <= lineLimit(first) else { return nil }
        return first
    }

    /// Words, or characters for text written without spaces.
    private static func lineLength(_ sentence: String) -> Int {
        isUnspaced(sentence) ? sentence.count : wordCount(sentence)
    }

    private static func lineLimit(_ sentence: String) -> Int {
        isUnspaced(sentence) ? maxUnspacedLineCharacters : maxLineWords
    }

    private static func joined(_ sentences: [String]) -> String {
        sentences.joined(separator: sentences.allSatisfy(isUnspaced) ? "" : " ")
    }

    /// Chinese or Japanese text: mostly ideographs or kana, so no spaces
    /// between words.
    static func isUnspaced(_ text: String) -> Bool {
        let cjk = text.unicodeScalars.filter { scalar in
            switch scalar.value {
            case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF66...0xFF9F: return true
            default: return false
            }
        }.count
        return cjk >= 2 && cjk * 3 >= text.count
    }

    /// At most three sentences, with the same recorder-task rule.
    static func summary(_ raw: String) -> String? {
        let kept = Array(cleanSentences(raw).prefix(maxSummarySentences))
        return kept.isEmpty ? nil : joined(kept)
    }

    /// "You will…", "You and Priya will…", "After the call, you'll…",
    /// "Your next step is…". "You'll see/notice/hear/find…" reads as a
    /// description, not a task, and is kept. Erring toward dropping is safe.
    private static let recorderTask = try! NSRegularExpression(
        pattern: #"^(?:(?:so|and|also|then|next|after that|afterwards|finally|meanwhile)\b,?\s+|[^,.!?;:]{1,40},\s+)?you(?:\s+and\s+\S+(?:\s+\S+)?)?(?:\s+will|'ll|’ll|\s+need\s+to|\s+are\s+going\s+to|'re\s+going\s+to|’re\s+going\s+to|\s+have\s+to|\s+must|\s+should|\s+agreed\s+to|\s+are\s+to)\b(?!\s+(?:see|notice|hear|find)\b)|^your\s+(?:next\s+steps?|action\s+items?|tasks?|to-dos?)\b"#,
        options: [.caseInsensitive]
    )

    /// True for a sentence that assigns a task to the recorder ("You will…",
    /// "You'll…", "You need to…"). Small models often get ownership wrong.
    static func assignsTaskToRecorder(_ sentence: String) -> Bool {
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        return recorderTask.firstMatch(in: trimmed, range: range) != nil
    }

    static func cleanSentences(_ raw: String) -> [String] {
        sentences(in: collapsedWhitespace(raw)).filter { !assignsTaskToRecorder($0) }
    }

    private static let abbreviations: Set<String> = [
        "e.g", "i.e", "dr", "mr", "mrs", "ms", "vs", "etc", "st", "jr", "sr", "u.s", "inc", "u.k", "a.m", "p.m",
    ]

    /// Splits at `.`, `!`, `?` or `…` followed by a space and a capital,
    /// digit or opening quote. Common abbreviations don't end a sentence.
    static func sentences(in text: String) -> [String] {
        let characters = Array(text)
        var result: [String] = []
        var current = ""
        var index = 0
        while index < characters.count {
            let character = characters[index]
            current.append(character)
            if "。！？".contains(character) {
                var lookahead = index + 1
                while lookahead < characters.count, "」』）\"”’".contains(characters[lookahead]) {
                    current.append(characters[lookahead])
                    lookahead += 1
                }
                appendSentence(current, to: &result)
                current = ""
                index = lookahead
                continue
            }
            if ".!?…".contains(character) {
                var lookahead = index + 1
                while lookahead < characters.count, "\"”’)".contains(characters[lookahead]) {
                    current.append(characters[lookahead])
                    lookahead += 1
                }
                index = lookahead
                guard lookahead < characters.count, characters[lookahead] == " " else { continue }
                var next = lookahead
                while next < characters.count, characters[next] == " " { next += 1 }
                let startsSentence = next < characters.count
                    && (characters[next].isUppercase || characters[next].isNumber || "\"“‘(".contains(characters[next]))
                // "No." is an abbreviation only before a number ("No. 5").
                let numberAbbreviation = character == "." && next < characters.count && characters[next].isNumber
                    && lastWordBeforePeriod(current) == "no"
                if startsSentence, !(character == "." && (endsWithAbbreviation(current) || numberAbbreviation)) {
                    appendSentence(current, to: &result)
                    current = ""
                    index = next
                }
                continue
            }
            index += 1
        }
        appendSentence(current, to: &result)
        return result
    }

    private static func lastWordBeforePeriod(_ sentence: String) -> String {
        (sentence.dropLast().split(separator: " ").last.map(String.init) ?? "").lowercased()
    }

    private static func endsWithAbbreviation(_ sentence: String) -> Bool {
        let lastWord = sentence.dropLast().split(separator: " ").last.map(String.init) ?? ""
        // A lone capital is an initial ("J. Smith", the "U." of "U.S.").
        if lastWord.count == 1, lastWord.first?.isUppercase == true { return true }
        return abbreviations.contains(lastWord.lowercased())
    }

    private static func appendSentence(_ sentence: String, to result: inout [String]) {
        let trimmed = sentence.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { result.append(trimmed) }
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    private static func collapsedWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
