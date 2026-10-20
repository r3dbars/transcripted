import AppKit

/// What the card shows for the current reply, tone and length.
extension NextSentenceController {
    /// The text for a reply at the current tone and length, and the best stand-in while it's on its way.
    func text(forReply index: Int) -> (text: String, waiting: Bool) {
        let guess = guesses.indices.contains(index) ? guesses[index] : nil
        // The streamed reply is the likeliest guess in the tone it was written in, medium length.
        if index == 0, tone == streamTone, length == NextSentencePrompt.mediumLength, !streamText.isEmpty {
            return (streamText, false)
        }
        if let exact = guess?.text(tone: tone, length: length) { return (exact, false) }
        let standIn = guess?.text(tone: streamTone, length: NextSentencePrompt.mediumLength) ?? (index == 0 ? streamText : "")
        return (standIn, true)
    }

    func displayed() -> (text: String, facts: [NextSentencePrompt.Fact], waiting: Bool) {
        let facts = guesses.indices.contains(guessIndex) ? guesses[guessIndex].facts : []
        if let custom { return (custom, facts, false) }
        let shown = text(forReply: guessIndex)
        return (shown.text, facts, shown.waiting)
    }

    func render() {
        guard card.isVisible else { return }
        let next = content()
        fadeNext = false
        card.update(next)
        if !next.streaming, !next.text.isEmpty, !listening { fetchSwapsIfNeeded(for: next.text) }
    }

    func content() -> NextSentenceCard.Content {
        let app = snapshot?.appName ?? targetApp?.localizedName ?? ""
        let window = snapshot?.windowTitle ?? ""
        let place = window.isEmpty || window == app ? app : "\(app) · \(window)"
        let continuing = !(snapshot?.draft.isEmpty ?? true)
        let shown = displayed()
        let streaming = (custom == nil && !streamText.isEmpty && !streamDone && guessIndex == 0) || rewriting

        var status = listening ? "Listening" : continuing ? "Continuing your text in \(app)" : "Replying in \(place)"
        let busy = failure == nil && (streamText.isEmpty || !streamDone || rewriting)
        if shown.text.isEmpty && busy { status = waitingStatus() }
        if let failure { status = failure }

        var hint: String
        if let note {
            hint = note
        } else if failure != nil {
            hint = "esc close"
        } else if shown.waiting {
            hint = "Writing that version…"
        } else {
            hint = "hold ↵ to send"
        }

        let stated = NextSentencePrompt.factRanges(in: shown.text, facts: shown.facts)
        let found = NextSentencePrompt.historyRanges(in: shown.text, sources: sources, screen: snapshot?.screenText ?? "")
            .filter { mark in !stated.contains { NSIntersectionRange($0.range, mark.range).length > 0 } }
        let marks = (streaming ? [] : stated + found).map { mark -> NextSentenceCard.Mark in
            let source = sources.first { $0.id == mark.source }
            let about = source.map { $0.about.isEmpty ? nil : "about \($0.about)" } ?? nil
            let heading = [source?.kind.capitalized, source?.title, source?.date, about].compactMap { $0 }.filter { !$0.isEmpty }
            return .init(range: mark.range, color: color(forSource: mark.source),
                         heading: heading.isEmpty ? "From your history" : heading.joined(separator: " · "),
                         quote: String((source?.quote ?? "").prefix(180)))
        }
        return .init(
            status: shown.text.isEmpty || failure != nil ? status : "", busy: busy, text: shown.text, marks: marks,
            streaming: streaming, fade: fadeNext, tone: toneIndex, length: length, hint: hint,
            insertHelp: app.isEmpty ? "Insert. Hold to send." : "Insert into \(app). Hold to send.",
            showsButtons: failure == nil && !shown.text.isEmpty,
            listening: listening, heard: heard)
    }

    /// What the card is doing before its first words: reading, then what it found, then writing.
    func waitingStatus() -> String {
        guard let found = contextFoundAt else { return "Reading the window" }
        guard Date().timeIntervalSince(found) < 1.4, !sources.isEmpty else { return "Writing it like you" }
        if let person = people.first {
            let about = sources.filter { $0.about == person }.count
            if about > 0 { return "Found \(about) \(about == 1 ? "note" : "notes") about \(person)" }
        }
        return "Found \(sources.count) related \(sources.count == 1 ? "note" : "notes")"
    }

    private func color(forSource source: String) -> NSColor {
        let index = sources.firstIndex { $0.id == source } ?? 0
        return NextSentenceCardStyle.factColors[index % NextSentenceCardStyle.factColors.count]
    }
}
