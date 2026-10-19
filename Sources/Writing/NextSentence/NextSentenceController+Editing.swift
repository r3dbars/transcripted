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
        note = "Editing · Return inserts · Esc stops editing"
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
        card.animateWordIn(newRange)
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
        guard !text.isEmpty, !swapsRequested.contains(text), !rewriting, !card.isEditing else { return }
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // MARK: The end handle

    /// The whole message the handle cuts from: the one before any words were cut.
    func gripStarted() -> String {
        trimSource ?? card.currentText.nextSentenceCollapsedWhitespace
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
        card.closeOptions()
        note = instruction.isEmpty ? "Fresh take…" : nil
        render()
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
                case .success(let final): self.custom = final; self.note = nil
                case .failure(let error): self.note = error.localizedDescription
                }
                self.render()
            } }
        })
        // A spoken change should hold when they then pick another tone or length.
        if !instruction.isEmpty, let steered = self.request(steer: "Start from this draft: \"\(current)\". They asked: \(instruction)") {
            writeAllVersions(steered, image: image)
        }
    }

    func startListening() {
        guard startDictation != nil, finishDictation != nil else {
            note = "Voice changes need Transcripted's dictation."
            return render()
        }
        if card.isEditing { endEditing() }
        listening = true
        heard = nil
        NextSentenceCardStyle.tick()
        NextSentenceSounds.shared.play(.listenStart)
        render()
        startDictation?()
    }

    func finishListening() {
        guard listening else { return }
        listening = false
        NextSentenceSounds.shared.play(.listenStop)
        heard = "Got it. Rewriting…"
        render()
        let gen = generation
        dictationWatch = finishDictation? { [weak self] said in
            guard let self, gen == self.generation else { return }
            self.dictationWatch = nil
            let said = said.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !said.isEmpty else { self.heard = nil; self.note = "Didn't catch that."; return self.render() }
            self.heard = said
            self.rewrite(instruction: said)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, gen == self.generation, self.dictationWatch != nil else { return }
            self.dictationWatch = nil
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
