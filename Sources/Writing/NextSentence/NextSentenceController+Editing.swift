import AppKit

/// Changing the message in place: typing, swapping words, remixing a part, a fresh take, and a
/// spoken change. Each leaves the result in `custom` until they pick another reply, tone or length.
extension NextSentenceController {
    // MARK: Typing

    func beginEditing(typing: String?) {
        guard card.isVisible else { return }
        keyTap.stop() // the text view has the keyboard now
        card.beginEditing(typing: typing)
        custom = card.currentText
        // No editing mode: nothing to announce or leave. The tools keep working, and using one ends the typing.
        note = nil
        render()
    }

    func endEditing() {
        custom = card.currentText
        card.endEditing()
        card.closeOptions()
        note = nil
        keyTap.start()
        render()
    }

    func textEdited() {
        typedEdits = true
        custom = card.currentText
        trimSource = nil
        card.closeOptions()
    }

    // MARK: Picking a word or part

    /// They highlighted a word or a few words: float other ways to say it above, to click or scroll through.
    func picked(_ range: NSRange) {
        let text = card.currentText
        guard NSMaxRange(range) <= (text as NSString).length else { return }
        let part = (text as NSString).substring(with: range)
        guard !part.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if let options = swaps[part.lowercased()], !options.isEmpty { return card.showOptions(for: range) }
        card.showOptionsLoading(for: range)
        alternatives(for: part, in: text) { options in
            self.swaps[part.lowercased()] = Array(options.prefix(3))
            if self.card.optionsRange == range { self.card.showOptions(for: range) }
        }
    }

    /// Puts `option` in place of the part at `range`. What it replaces goes back to the top of the list,
    /// so rolling the same way walks through every option and comes back around.
    func swap(_ range: NSRange, to option: String, step: Int) {
        let text = card.currentText as NSString
        guard NSMaxRange(range) <= text.length else { return }
        let old = text.substring(with: range)
        let pool = swaps[old.lowercased()] ?? []
        swaps[option.lowercased()] = [old] + pool.filter { $0.lowercased() != option.lowercased() && $0.lowercased() != old.lowercased() }
        let cased = old.first?.isUppercase == true ? option.prefix(1).uppercased() + option.dropFirst() : option
        let newRange = card.replace(range, with: cased)
        custom = card.currentText
        trimSource = nil
        NextSentenceCardStyle.tick()
        NextSentenceSounds.shared.play(.roll(up: step > 0))
        card.animateWordIn(newRange, replacing: old)
        card.showOptions(for: newRange, rolled: step)
    }

    /// One scroll step: +1 brings in the option nearest the text (the bottom of the list).
    func roll(_ range: NSRange, step: Int) {
        let part = (card.currentText as NSString).substring(with: range).lowercased()
        guard let options = swaps[part], !options.isEmpty else { return }
        swap(range, to: (step > 0 ? options.last : options.first) ?? options[0], step: step)
    }

    /// Asks once for the words in a settled message worth swapping, so picking one is instant.
    func fetchSwapsIfNeeded(for text: String) {
        swapWork?.cancel()
        guard !text.isEmpty, !swapsRequested.contains(text), !rewriting else { return }
        let words = Set(text.lowercased().split { !($0.isLetter || $0 == "'" || $0 == "’") }.map(String.init))
        guard words.filter({ swaps[$0] != nil }).count < 2 else { return }
        let gen = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, gen == self.generation else { return }
            self.swapsRequested.insert(text)
            self.claude.structured(.swaps, prompt: NextSentencePrompt.swapsPrompt(text: text), image: nil, timeout: 40) { result in
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    guard gen == self.generation, case .success(let object) = result else { return }
                    self.swaps.merge(NextSentencePrompt.parseSwaps(object)) { current, _ in current }
                } }
            }
        }
        swapWork = work
        // While they type, wait for a real pause so each keystroke doesn't ask for new swaps.
        DispatchQueue.main.asyncAfter(deadline: .now() + (card.isEditing ? 1.5 : 0.5), execute: work)
    }

    // MARK: Stretching the card

    /// The whole message the bottom edge cuts from: the one before any sentences were cut.
    func gripStarted() -> String {
        if card.isEditing { endEditing() }
        return trimSource ?? card.currentText.nextSentenceCollapsedWhitespace
    }

    /// Let go: keep the shorter message, or (pulled past the end) show the next longer version.
    func gripEnded(kept: String?, whole: String) {
        guard let kept else {
            set(tone: toneIndex, length: length + 1)
            return
        }
        custom = kept
        trimSource = kept == whole ? nil : whole
        render()
    }

    private func alternatives(for part: String, in text: String, then use: @escaping @MainActor ([String]) -> Void) {
        let gen = generation
        claude.structured(.alternatives, prompt: NextSentencePrompt.alternativesPrompt(text: text, selection: part),
                          image: nil, timeout: 30) { result in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard gen == self.generation, self.card.isVisible, case .success(let object) = result else { return }
                let options = NextSentencePrompt.parseOptions(object)
                if !options.isEmpty { use(options) }
            } }
        }
    }

    // MARK: Fresh takes and spoken changes

    /// Rewrites the message on the card, streaming it in. No instruction means a fresh take.
    func rewrite(instruction: String) {
        let current = card.currentText.nextSentenceCollapsedWhitespace
        guard !current.isEmpty, let request = request() else { return }
        if card.isEditing { card.endEditing(); keyTap.start() }
        if instruction.isEmpty { NextSentenceSounds.shared.play(.remix) }
        rewriteGeneration += 1
        let gen = generation
        let rewriteGen = rewriteGeneration
        rewriting = true
        trimSource = nil
        typedEdits = false
        card.closeOptions()
        note = instruction.isEmpty ? "Fresh take…" : nil
        render()
        if instruction.isEmpty { card.burstText() }
        let image = snapshot?.screenshotJPEG
        var text = ""
        claude.stream(prompt: NextSentencePrompt.rewritePrompt(request, current: current, instruction: instruction), image: image, onText: { piece in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard gen == self.generation, rewriteGen == self.rewriteGeneration else { return }
                if text.isEmpty { self.fadeNext = true }
                text += piece
                self.custom = text
                self.render()
            } }
        }, completion: { result in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard gen == self.generation, rewriteGen == self.rewriteGeneration else { return }
                self.rewriting = false
                self.heard = nil
                switch result {
                case .success(let final):
                    self.custom = final
                    self.note = nil
                    // The other tones and lengths follow the new wording.
                    self.writeVariations(of: final, tone: self.tone, length: self.length)
                case .failure(let error): self.note = error.localizedDescription
                }
                self.render()
            } }
        })
    }

    func startListening() {
        // Transcripted's own dictation does the listening and transcribing.
        guard startDictation != nil, finishDictation != nil else {
            note = "Voice needs Transcripted's dictation."
            if awaitingIntent { useIntent("") }
            return render()
        }
        if card.isEditing { endEditing() }
        liveWords = ""
        startDictation?()
        listening = true
        heard = nil
        NextSentenceCardStyle.tick()
        NextSentenceSounds.shared.play(.listenStart)
        render()
    }

    func finishListening() {
        guard listening else { return }
        listening = false
        heldListening = false
        if awaitingIntent { NextSentenceSynth.shared.heard() } else { NextSentenceSounds.shared.play(.listenStop) }
        heard = awaitingIntent ? "Got it. Writing…" : "Got it. Rewriting…"
        render()
        let gen = generation
        let handle: @MainActor (String) -> Void = { [weak self] said in
            guard let self, gen == self.generation else { return }
            self.dictationWatch = nil
            let said = said.trimmingCharacters(in: .whitespacesAndNewlines)
            if self.awaitingIntent { return self.useIntent(said) }
            guard !said.isEmpty else { self.heard = nil; self.note = "Didn't catch that."; return self.render() }
            self.heard = said
            self.rewrite(instruction: said)
        }
        dictationWatch = finishDictation? { said in handle(said) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, gen == self.generation, self.dictationWatch != nil else { return }
            self.dictationWatch = nil
            if self.awaitingIntent { return self.useIntent("") }
            self.heard = nil
            self.note = "Didn't catch that."
            self.render()
        }
    }

    /// Esc while listening: stop, and ignore what was said.
    func cancelListening() {
        guard listening else { return }
        listening = false
        dictationWatch = finishDictation? { _ in }
        dictationWatch = nil
        heard = nil
        render()
    }
}
