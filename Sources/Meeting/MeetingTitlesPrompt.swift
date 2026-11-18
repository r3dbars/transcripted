import Foundation

/// One speaker turn as the titles model sees it: consecutive lines by the
/// same speaker merged, filler and stutters cleaned out.
struct MeetingTitlesTurn: Equatable, Sendable {
    let speaker: String
    var text: String
    /// Seconds from the start of the recording, from the turn's first line.
    let startSeconds: Int
}

/// Turns a saved meeting's Markdown into the plain "Name: text" transcript the
/// titles model reads. The recorder (the mic track) is always "You"; voices
/// nobody named become "Unknown speaker".
enum MeetingTitlesTranscript {
    static let recorderName = "You"
    static let unknownSpeakerName = "Unknown speaker"

    /// Below this many words there's nothing worth labeling; the job writes
    /// nothing and never starts the model.
    static let minimumWords = 40

    static func turns(fromMeetingMarkdown markdown: String) -> [MeetingTitlesTurn] {
        let transcript = LocalMeetingTranscriptExtractor.transcriptText(from: markdown)
        var lines: [(label: String, seconds: Int, text: String)] = []
        for rawLine in transcript.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let header = parseHeader(line) {
                lines.append((header.label, header.seconds, header.inlineText))
            } else if !line.isEmpty, !lines.isEmpty {
                let last = lines.removeLast()
                let joined = last.text.isEmpty ? line : last.text + " " + line
                lines.append((last.label, last.seconds, joined))
            }
        }

        var turns: [MeetingTitlesTurn] = []
        for entry in lines {
            let text = clean(entry.text.split(whereSeparator: \.isWhitespace).joined(separator: " "))
            guard !text.isEmpty else { continue }
            let name = speakerName(forLabel: entry.label)
            if let last = turns.last, last.speaker == name {
                turns[turns.count - 1].text += " " + text
            } else {
                turns.append(MeetingTitlesTurn(speaker: name, text: text, startSeconds: entry.seconds))
            }
        }
        return turns
    }

    static func render(_ turns: [MeetingTitlesTurn]) -> String {
        turns.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
    }

    static func wordCount(_ turns: [MeetingTitlesTurn]) -> Int {
        turns.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
    }

    /// The part after the channel prefix, with Obsidian link brackets
    /// dropped. On the mic, the primary voice (no name, or "You") is the
    /// recorder, "You"; a named person split out on the mic keeps their
    /// name, and another unnamed mic voice is "Unknown speaker". Elsewhere,
    /// generic labels name nobody.
    static func speakerName(forLabel rawLabel: String) -> String {
        let label = rawLabel.trimmingCharacters(in: .whitespaces)
        let isMic = label.hasPrefix("Mic")
        var name = label
        if let slash = label.firstIndex(of: "/") {
            name = String(label[label.index(after: slash)...])
        }
        name = name
            .replacingOccurrences(of: "[[", with: "")
            .replacingOccurrences(of: "]]", with: "")
            .trimmingCharacters(in: .whitespaces)
        if let pipe = name.firstIndex(of: "|") {
            name = String(name[name.index(after: pipe)...]).trimmingCharacters(in: .whitespaces)
        }
        if isMic {
            // The primary mic voice (unlabelled or "You") is the recorder;
            // another unnamed voice split out on the mic is someone else.
            if name == label || name.isEmpty || name.lowercased() == "you" { return recorderName }
            return isGenericName(name) ? unknownSpeakerName : name
        }
        if name.isEmpty || isGenericName(name) { return unknownSpeakerName }
        return name
    }

    private static let genericNames: Set<String> = ["remote", "remote participant", "unknown speaker", "review later"]

    private static func isGenericName(_ name: String) -> Bool {
        if genericNames.contains(name.lowercased()) { return true }
        return name.range(of: #"^(?i)speaker\s*\d+$"#, options: .regularExpression) != nil
    }

    // MARK: - Cleaning

    private static let filler = try! NSRegularExpression(
        pattern: #"\b(?:um+|uh+|uh-huh|mm-hmm|mhm|erm|hmm+|you know|i mean)\b[,.]?\s*"#,
        options: [.caseInsensitive]
    )
    private static let stutter = try! NSRegularExpression(
        pattern: #"\b(\w+)(?:[ ,]+\1\b)+"#,
        options: [.caseInsensitive]
    )
    private static let spaceBeforePunctuation = try! NSRegularExpression(pattern: #"\s+([,.?!])"#)
    private static let repeatedSpaces = try! NSRegularExpression(pattern: #"\s{2,}"#)
    private static let leadingPunctuation = try! NSRegularExpression(pattern: #"^[,.\s]+"#)

    /// Drops filler words and repeated words, tidies spacing, and capitalizes
    /// the first letter.
    static func clean(_ text: String) -> String {
        var cleaned = replace(filler, in: text, with: "")
        cleaned = replace(stutter, in: cleaned, with: "$1")
        cleaned = replace(spaceBeforePunctuation, in: cleaned, with: "$1")
        cleaned = replace(repeatedSpaces, in: cleaned, with: " ")
        cleaned = replace(leadingPunctuation, in: cleaned, with: "")
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = cleaned.first else { return cleaned }
        return first.uppercased() + cleaned.dropFirst()
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    // MARK: - Transcript lines

    /// Reads both saved shapes: styled `**00:01**  [System/Maya]` (text on
    /// the next lines) and raw `[00:01] [System/Maya] text`.
    private static func parseHeader(_ line: String) -> (label: String, seconds: Int, inlineText: String)? {
        var rest = Substring(line)
        let timestamp: Substring
        if rest.hasPrefix("**") {
            rest = rest.dropFirst(2)
            guard let close = rest.range(of: "**") else { return nil }
            timestamp = rest[..<close.lowerBound]
            rest = rest[close.upperBound...]
        } else if rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else { return nil }
            timestamp = rest[rest.index(after: rest.startIndex)..<close]
            rest = rest[rest.index(after: close)...]
        } else {
            return nil
        }
        let stamp = timestamp.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        guard let seconds = seconds(fromTimestamp: stamp) else { return nil }
        rest = rest.drop(while: { $0 == " " || $0 == "\t" })
        guard let label = bracketedLabel(in: rest) else { return nil }
        let inline = rest[label.end...].trimmingCharacters(in: .whitespaces)
        return (label.value, seconds, inline)
    }

    /// `[label]` where the label may hold `[[wiki links]]`.
    private static func bracketedLabel(in text: Substring) -> (value: String, end: Substring.Index)? {
        guard text.first == "[" else { return nil }
        var depth = 0
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "[" {
                depth += 1
            } else if character == "]" {
                depth -= 1
                if depth == 0 {
                    let value = String(text[text.index(after: text.startIndex)..<index])
                    return value.isEmpty ? nil : (value, text.index(after: index))
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    static func seconds(fromTimestamp stamp: String) -> Int? {
        let parts = stamp.split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        var total = 0
        for part in parts {
            guard let value = Int(part), value >= 0 else { return nil }
            total = total * 60 + value
        }
        return total
    }
}

/// The tested request: system prompt, user wrapper, sampling, and schema.
enum MeetingTitlesPrompt {
    static let system = "You label recorded meetings for the person who recorded them, shown in the transcript as \"You\". You read the transcript and reply with JSON only.\n\n"
        + "title: 2 to 5 words naming what the meeting was about, like a file name a person would pick. "
        + "Name the topic, not the people, unless the whole point was meeting one outside person or company. "
        + "Skip small talk. Never use the words Meeting, Call, Discussion, Updates, Summary, or a date. No quotes, no period, no commas, no \"and\" lists.\n"
        + "line: one or two plain sentences, 30 words at most in total, saying what was decided or worked out. "
        + "Lead with the outcome. Say what was decided or found, not who will do what next. Do not start with \"The meeting\", \"The team discussed\" or \"Discussion\".\n"
        + "summary: 2 or 3 short sentences on what was talked about and where it landed. Plain words. "
        + "Do not list tasks and do not say who owes what.\n\n"
        + "Only say what the transcript supports. The transcript comes from speech recognition, so ignore garbled words and keep names exactly as written."

    static func user(transcript: String) -> String {
        "<transcript>\n\(transcript)\n</transcript>\n\nReply with the JSON now."
    }

    static let maxTokens = 400

    /// `/v1/chat/completions` body as fixed bytes. Greedy decoding, thinking
    /// off, and a strict JSON schema so the reply is always `{title, line,
    /// summary}`. Written out by hand, not through a dictionary: llama-server
    /// builds its grammar in the schema's property order, and a dictionary's
    /// order changes from run to run. Keys are in the tested order.
    static func chatRequestBody(transcript: String) -> Data {
        let body = "{"
            + #""messages":[{"role":"system","content":"# + jsonString(system) + "},"
            + #"{"role":"user","content":"# + jsonString(user(transcript: transcript)) + "}],"
            + #""max_tokens":\#(maxTokens),"#
            + #""response_format":{"type":"json_schema","json_schema":{"name":"label","strict":true,"schema":"# + schemaJSON + "}},"
            + #""temperature":0,"top_k":40,"top_p":0.9,"repeat_penalty":1.0,"#
            + #""chat_template_kwargs":{"enable_thinking":false},"cache_prompt":false"#
            + "}"
        return Data(body.utf8)
    }

    /// The reply schema, properties in the tested order: title, line, summary.
    static let schemaJSON = #"{"type":"object","properties":{"title":{"type":"string"},"line":{"type":"string"},"summary":{"type":"string"}},"required":["title","line","summary"],"additionalProperties":false}"#

    /// A JSON string literal for `value`, quotes included.
    static func jsonString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes]),
              let literal = String(data: data, encoding: .utf8) else { return "\"\"" }
        return literal
    }
}

/// Fits a transcript into the model's prompt budget. The whole meeting goes in
/// whenever it fits; clipping a long meeting's middle made titles drift to side
/// topics. Only past the budget are turns dropped, evenly across the middle,
/// keeping the first and last few minutes whole.
enum MeetingTitlesFit {
    /// Prompt tokens for system + user. The server runs with a 40,960 context,
    /// which leaves room for this plus the 400-token reply.
    static let promptTokenBudget = 36_000
    /// Room for the chat template and the user wrapper around the transcript.
    static let templateOverheadTokens = 450
    /// Minutes kept whole at each end when turns must be dropped.
    static let protectedEdgeSeconds = 180

    struct Result: Equatable {
        let transcript: String
        let tokenCount: Int
        let droppedTurns: Int
    }

    /// `countTokens` is the model's own tokenizer in production.
    static func fit(
        _ turns: [MeetingTitlesTurn],
        systemTokens: Int,
        budget: Int = promptTokenBudget,
        countTokens: (String) async throws -> Int
    ) async throws -> Result {
        let available = budget - systemTokens - templateOverheadTokens
        let full = MeetingTitlesTranscript.render(turns)
        var count = try await countTokens(full)
        if count <= available {
            return Result(transcript: full, tokenCount: count, droppedTurns: 0)
        }

        var edgeSeconds = protectedEdgeSeconds
        var keptMiddle: Int? = nil
        for _ in 0..<24 {
            let split = splitEdges(turns, edgeSeconds: edgeSeconds)
            let middleCount = split.middle.count
            let fraction = 0.9 * Double(available) / Double(max(count, 1))
            let target = max(0, Int(Double(keptMiddle ?? middleCount) * fraction))
            let kept = evenlySpaced(split.middle, keeping: min(target, middleCount))
            let chosen = split.head + kept + split.tail
            let text = MeetingTitlesTranscript.render(chosen)
            count = try await countTokens(text)
            if count <= available {
                return Result(transcript: text, tokenCount: count, droppedTurns: turns.count - chosen.count)
            }
            if target == 0 {
                // The edges alone are too long: shrink them and try again.
                guard edgeSeconds > 0 else { break }
                edgeSeconds /= 2
                keptMiddle = nil
            } else {
                keptMiddle = target
            }
        }

        // Last resort: first and last turn, cut to fit by length.
        let ends = turns.count > 1 ? [turns[0], turns[turns.count - 1]] : Array(turns.prefix(1))
        var text = MeetingTitlesTranscript.render(ends)
        count = try await countTokens(text)
        if count > available, available > 0 {
            let ratio = 0.9 * Double(available) / Double(count)
            text = String(text.prefix(max(0, Int(Double(text.count) * ratio))))
            count = try await countTokens(text)
        }
        return Result(transcript: text, tokenCount: count, droppedTurns: turns.count - ends.count)
    }

    static func splitEdges(
        _ turns: [MeetingTitlesTurn],
        edgeSeconds: Int
    ) -> (head: [MeetingTitlesTurn], middle: [MeetingTitlesTurn], tail: [MeetingTitlesTurn]) {
        guard let first = turns.first, let last = turns.last else { return ([], [], []) }
        let headEnd = first.startSeconds + edgeSeconds
        let tailStart = last.startSeconds - edgeSeconds
        var head: [MeetingTitlesTurn] = []
        var middle: [MeetingTitlesTurn] = []
        var tail: [MeetingTitlesTurn] = []
        for (index, turn) in turns.enumerated() {
            if index == 0 || turn.startSeconds < headEnd && middle.isEmpty && tail.isEmpty {
                head.append(turn)
            } else if index == turns.count - 1 || turn.startSeconds > tailStart {
                tail.append(turn)
            } else {
                middle.append(turn)
            }
        }
        return (head, middle, tail)
    }

    /// `count` items picked at even spacing, in their original order.
    static func evenlySpaced<T>(_ items: [T], keeping count: Int) -> [T] {
        guard count > 0, !items.isEmpty else { return [] }
        guard count < items.count else { return items }
        let step = Double(items.count) / Double(count)
        return (0..<count).map { items[min(items.count - 1, Int(Double($0) * step + step / 2))] }
    }
}
