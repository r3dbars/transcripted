import Foundation

/// Pure pieces of Next Sentence: which words to search for, how to phrase the request, and how to
/// read the answer. No I/O, so tests pin them.
enum NextSentencePrompt {
    enum Tone: String, CaseIterable, Sendable {
        case casual, direct, warm
        /// Left to right on the mood pad and the ← → keys: more direct, neutral, warmer.
        static let padOrder: [Tone] = [.direct, .casual, .warm]
    }

    /// Five lengths, shortest to longest. The streamed and quick passes write the middle one.
    static let lengthNames = ["Tiny", "Short", "Medium", "Long", "Full"]
    static let mediumLength = 2

    struct Source: Equatable, Sendable {
        let id: String
        let kind: String
        let date: String
        let title: String
        let quote: String
    }

    // MARK: Search terms

    private static let stopWords: Set<String> = Set("""
    about above after again against also and anything are because been before being below between both but can could \
    did does doing down during each everyone few for from further get going gonna got had has have having her here hers \
    herself him himself his how into its itself just last let like maybe more most myself need needs next nor not now off \
    once only other our ours out over own please really same she should some something still such sure than thank thanks \
    that that's the their theirs them then there there's these they thing things think this those through time today \
    tomorrow too under until very want wants was week were what what's when where which while who whom why will with \
    would yeah yes yesterday you you're your yours okay hey
    """.split(whereSeparator: \.isWhitespace).map(String.init))

    /// The words most likely to find related context. The keyword search needs every word to match,
    /// so each is searched on its own. Later words count more: in a chat, the newest message is last.
    static func searchTerms(in text: String, limit: Int = 5) -> [String] {
        let tail = String(text.suffix(1_500))
        let words = tail.split { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == "-") }.map(String.init)
        var seen = Set<String>()
        var scored: [(Double, String)] = []
        for (index, word) in words.enumerated() {
            let key = word.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "'-"))
            guard key.count >= 4, !stopWords.contains(key), !seen.contains(key) else { continue }
            seen.insert(key)
            let capitalized = index > 0 && (word.first?.isUppercase ?? false)
            let recency = Double(index) / Double(max(1, words.count)) * 4
            scored.append((Double(key.count) + (capitalized ? 3 : 0) + recency, key))
        }
        return scored.sorted { $0.0 > $1.0 }.prefix(limit).map(\.1)
    }

    // MARK: The request

    struct Request: Sendable {
        var appName: String
        var windowTitle: String
        var screenText: String
        var draft: String
        var hasScreenshot: Bool
        var sources: [Source]
        var voiceExamples: [String]
        var steer: String = ""
    }

    /// Shared body. `json` asks for structured output with facts marked; otherwise plain text.
    static func body(_ r: Request, json: Bool) -> String {
        var lines: [String] = []
        lines.append("You write the next thing the user would type, in their own voice.\(json ? " Output JSON only." : "")")
        lines.append("")
        lines.append("WHERE THEY ARE")
        lines.append("App: \(r.appName.isEmpty ? "unknown" : r.appName)   Window: \(r.windowTitle.isEmpty ? "unknown" : r.windowTitle)")
        if r.hasScreenshot {
            lines.append("")
            lines.append("A screenshot of the window they're typing in is attached. Use it to understand the conversation: who said what, which message is newest, what they're replying to. Don't describe it.")
        }
        lines.append("")
        lines.append("WINDOW TEXT (read through Accessibility; may be partial or noisy; newest at the end)")
        lines.append("<<<\n\(String(r.screenText.suffix(4_000)))\n>>>")
        lines.append("")
        lines.append("WHAT THEY'VE TYPED SO FAR IN THE BOX (may be empty)")
        lines.append("<<<\n\(r.draft)\n>>>")
        lines.append("")
        lines.append("If the box is empty, write their reply. If it has text, write ONLY the next sentence or two that continue it, without repeating it.")
        lines.append("")
        lines.append("THEIR CONTEXT (their own meetings, dictations and writing; may be irrelevant; ids in brackets)")
        if r.sources.isEmpty {
            lines.append("(nothing found)")
        } else {
            for s in r.sources { lines.append("[\(s.id)] \(s.kind) \(s.date) \(s.title): \(s.quote)") }
        }
        lines.append("")
        lines.append("Use a fact from their context ONLY if it clearly answers or helps with what's on screen. Never invent dates, numbers, names or commitments that aren't on screen or in their context.")
        if json {
            lines.append("For each reply, list the facts from their context it uses in \"facts\": \"phrase\" = the exact words in the reply that state it, \"source\" = the [S#] it came from.")
        }
        if !r.steer.isEmpty { lines.append("They asked for this change: \(r.steer)") }
        lines.append("")
        lines.append("THEIR VOICE")
        if r.voiceExamples.isEmpty {
            lines.append("(no examples)")
        } else {
            lines.append("Things they've said or written before:")
            for example in r.voiceExamples { lines.append("- \(example)") }
        }
        lines.append("Plain words, no em dashes, no AI-speak, no greetings or sign-offs unless the thread uses them.")
        return lines.joined(separator: "\n")
    }

    static func streamPrompt(_ r: Request, tone: Tone) -> String {
        body(r, json: false) + "\n\nWrite the reply they're most likely to send, in \"\(tone.rawValue)\" tone, medium length (one or two sentences). Output only the message text itself: no quotes, no labels, no JSON."
    }

    /// Three different replies (different intents), current tone, medium. Quick, so ↑/↓ works early.
    static func guessesPrompt(_ r: Request, tone: Tone) -> String {
        body(r, json: true) + "\n\n" + guessRule + " For each, write only the \"\(tone.rawValue)\" tone, medium length (one or two sentences), as \"text\"."
    }

    /// The same three replies in every tone and length. Slower; fills in while they read.
    static func fullPrompt(_ r: Request) -> String {
        body(r, json: true) + "\n\n" + guessRule + " For each, write three tones, \"casual\", \"direct\" and \"warm\", each as exactly 5 lengths: [tiny, short, medium, long, full]. Tiny is two to four words. Short is one short sentence. Medium is one or two sentences. Long is two or three. Full is at most four sentences and adds a useful detail from their context. Each length should read as a natural message, not a cut-off version of the next."
    }

    private static let guessRule = "Write exactly 3 different replies they might send, as \"guesses\": the most likely first, then two with a genuinely different intent (for example agree, push back, ask a question). \"label\" names each intent in 2-4 plain words."

    /// Replacements for a word, or rephrasings for a longer selection, that fit back into the text.
    static func alternativesPrompt(text: String, selection: String) -> String {
        let isWord = !selection.trimmingCharacters(in: .whitespaces).contains(" ")
        return """
        Here is a message someone is about to send:
        <<<
        \(text)
        >>>
        \(isWord ? "Give 4 replacements for the word" : "Give 3 rephrasings of the part") "\(selection)" that fit back into the message exactly where it is, keep the meaning close, and sound like the rest of it. Plain words, no em dashes. Return JSON {"options": [...]}, each option only the replacement text.
        """
    }

    /// Rewrites the message on the card. A spoken change ("mention the beta", "say no but nicely") or,
    /// with no instruction, a fresh take: same meaning and length, new wording.
    static func rewritePrompt(_ r: Request, current: String, instruction: String) -> String {
        let ask = instruction.isEmpty
            ? "Write a fresh take on it: the same meaning, intent and length, in completely different words. Don't reuse its phrases."
            : """
            They said this about it, out loud, so it may be loose or rambling: "\(instruction)"
            Work out what they want changed and change only that. If they want something added or mentioned, work it in where it fits naturally, the way they'd have written it themselves, not tacked on the end. Keep the length close unless they asked for longer or shorter.
            """
        return body(r, json: false) + """


        THE MESSAGE ON THEIR CARD RIGHT NOW
        <<<
        \(current)
        >>>
        \(ask)
        It has to read like they wrote it: their words, their rhythm, no new formality. Output only the new message text: no quotes, no labels.
        """
    }

    /// Up to 10 words in the message worth swapping, each with a few replacements, so hovering a word
    /// shows options without waiting.
    static func swapsPrompt(text: String) -> String {
        """
        Here is a message someone is about to send:
        <<<
        \(text)
        >>>
        Pick up to 10 single words in it a person might want to swap for a different word: verbs, adjectives, adverbs, filler and casual words. Skip names, dates, numbers, and words that state a fact. For each, give 4 single-word or two-word replacements that fit exactly where it is and sound like the rest of the message, the closest in meaning first. "word" is the word exactly as it appears. Plain words, no em dashes.
        """
    }

    static var swapsSchema: [String: Any] {
        let swap = object(["word": ["type": "string"], "options": ["type": "array", "items": ["type": "string"]]], required: ["word", "options"])
        return object(["swaps": ["type": "array", "items": swap, "maxItems": 10]], required: ["swaps"])
    }

    /// Lowercased word -> replacements, closest first.
    static func parseSwaps(_ object: [String: Any]) -> [String: [String]] {
        var swaps: [String: [String]] = [:]
        for item in object["swaps"] as? [[String: Any]] ?? [] {
            guard let word = (item["word"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !word.isEmpty, !word.contains(" ") else { continue }
            let options = parseOptions(item).filter { $0.lowercased() != word }
            if !options.isEmpty { swaps[word] = Array(options.prefix(5)) }
        }
        return swaps
    }

    // MARK: The answer

    /// Words in a reply that state something from the user's history, so the card can mark them.
    struct Fact: Equatable, Sendable {
        let phrase: String
        let source: String
    }

    struct Guess: Equatable, Sendable {
        var label: String
        /// Tone -> [tiny, short, medium, long, full]. Before the full set arrives, only the medium of one tone is known.
        var texts: [Tone: [String?]]
        var facts: [Fact]

        func text(tone: Tone, length: Int) -> String? {
            guard let lengths = texts[tone], lengths.indices.contains(length) else { return nil }
            return lengths[length]
        }
    }

    private static func object(_ properties: [String: Any], required: [String]) -> [String: Any] {
        ["type": "object", "additionalProperties": false, "properties": properties, "required": required]
    }

    private static var factsSchema: [String: Any] {
        ["type": "array", "items": object(["phrase": ["type": "string"], "source": ["type": "string"]], required: ["phrase", "source"])]
    }

    static var guessesSchema: [String: Any] {
        let guess = object(["label": ["type": "string"], "text": ["type": "string"], "facts": factsSchema], required: ["label", "text", "facts"])
        return object(["guesses": ["type": "array", "items": guess, "minItems": 3, "maxItems": 3]], required: ["guesses"])
    }

    static var fullSchema: [String: Any] {
        let lengths: [String: Any] = ["type": "array", "items": ["type": "string"], "minItems": 5, "maxItems": 5]
        let guess = object(["label": ["type": "string"], "casual": lengths, "direct": lengths, "warm": lengths, "facts": factsSchema],
                           required: ["label", "casual", "direct", "warm", "facts"])
        return object(["guesses": ["type": "array", "items": guess, "minItems": 3, "maxItems": 3]], required: ["guesses"])
    }

    static var alternativesSchema: [String: Any] {
        object(["options": ["type": "array", "items": ["type": "string"]]], required: ["options"])
    }

    private static func facts(_ any: Any?) -> [Fact] {
        (any as? [[String: Any]] ?? []).compactMap {
            guard let phrase = $0["phrase"] as? String, !phrase.isEmpty else { return nil }
            return Fact(phrase: phrase, source: $0["source"] as? String ?? "")
        }
    }

    /// Three guesses with one tone's medium filled in.
    static func parseGuesses(_ object: [String: Any], tone: Tone) -> [Guess]? {
        guard let list = object["guesses"] as? [[String: Any]], list.count == 3 else { return nil }
        return list.map { item in
            Guess(label: item["label"] as? String ?? "", texts: [tone: [nil, nil, item["text"] as? String, nil, nil]], facts: facts(item["facts"]))
        }
    }

    /// Three guesses with every tone and length.
    static func parseFull(_ object: [String: Any]) -> [Guess]? {
        guard let list = object["guesses"] as? [[String: Any]], list.count == 3 else { return nil }
        var guesses: [Guess] = []
        for item in list {
            var texts: [Tone: [String?]] = [:]
            for tone in Tone.allCases {
                guard let lengths = item[tone.rawValue] as? [String], lengths.count == 5 else { return nil }
                texts[tone] = lengths
            }
            guesses.append(Guess(label: item["label"] as? String ?? "", texts: texts, facts: facts(item["facts"])))
        }
        return guesses
    }

    static func parseOptions(_ object: [String: Any]) -> [String] {
        (object["options"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// Where each fact's phrase appears in `text`, for underlining. Case-insensitive, first match.
    static func factRanges(in text: String, facts: [Fact]) -> [(range: NSRange, source: String)] {
        let ns = text as NSString
        return facts.compactMap { fact in
            let range = ns.range(of: fact.phrase, options: .caseInsensitive)
            return range.location == NSNotFound ? nil : (range, fact.source)
        }
    }
}

extension String {
    var nextSentenceCollapsedWhitespace: String {
        split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
