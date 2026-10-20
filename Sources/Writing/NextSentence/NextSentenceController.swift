import AppKit
import Carbon.HIToolbox
import Combine

/// Next Sentence: a tap of fn (or ⌃⌥Space) writes the next thing you'd type, from what's on screen and
/// your saved context. Tab moves between three different replies; ↑/↓ shorter and longer; ←/→ more
/// direct and warmer (the mood pad does both). Highlight a word or a few for other ways to say
/// it (scroll to roll through them), drag the end handle to cut words, type to edit. fn again listens for a spoken change. Return inserts; hold it to send.
/// A Developer Preview feature, off unless turned on in Settings (`NextSentencePreferences.isEnabled()`). See that type.
@MainActor
final class NextSentenceController {
    /// Starts Transcripted's own dictation (injected by the app; this module can't name Dictation).
    var startDictation: (() -> Void)?
    /// Stops it without pasting anywhere and hands back what was said, once it's transcribed.
    var finishDictation: ((@escaping @MainActor (String) -> Void) -> AnyCancellable?)?

    let card = NextSentenceCard()
    let history = NextSentenceHistory()
    let semantic = NextSentenceSemanticIndex()
    let claude = NextSentenceClaude()
    let paster = ClipboardRestoringTextPaster()
    lazy var keyTap = NextSentenceKeyTap { [weak self] action, typed, keyCode in
        self?.handle(action, typed: typed, keyCode: keyCode)
    }
    lazy var fnKey = NextSentenceFnKey(onTap: { [weak self] in self?.fnTapped() },
                                       onHoldStart: { [weak self] in self?.fnHoldBegan() },
                                       onHoldEnd: { [weak self] in self?.fnHoldEnded() })
    private var hotKey: EventHotKeyRef?
    private var handlerInstalled = false

    // What's on screen and what's been written for it.
    var targetApp: NSRunningApplication?
    var snapshot: NextSentenceSnapshot?
    var sources: [NextSentencePrompt.Source] = []
    var voice: [String] = []
    var people: [String] = []
    /// Opened by holding fn: what they say decides what it writes, so the first write waits for it.
    var awaitingIntent = false
    var intent: String?
    var contextReady = false
    /// fn is being held to talk (push-to-talk), as opposed to tapped on and off.
    var heldListening = false
    /// When the context search finished, so the card can say what it found for a moment.
    var contextFoundAt: Date?
    var generation = 0
    var streamText = ""
    var streamDone = false
    var streamTone: NextSentencePrompt.Tone = .casual
    var guesses: [NextSentencePrompt.Guess] = []
    var haveAllVersions = false
    var failure: String?
    var note: String?

    // What the user has picked.
    var toneIndex = 1
    var tone: NextSentencePrompt.Tone { NextSentencePrompt.Tone.padOrder[toneIndex] }
    var length = NextSentencePrompt.mediumLength
    var guessIndex = 0
    /// The message after their own changes (a swapped word, a remixed part, a fresh take, a spoken
    /// change, typing). Cleared when they pick another reply, tone or length.
    var custom: String?
    var fadeNext = false

    // Words, parts, voice and holds.
    var swaps: [String: [String]] = [:]
    var swapsRequested: Set<String> = []
    var swapWork: DispatchWorkItem?
    /// The end handle: the message before any words were cut, how many are cut, and where a drag began.
    var trimSource: String?
    /// They typed into this version of the message, so a single Esc only warns before closing.
    var typedEdits = false
    var escapeArmedAt: Date?
    var rewriteGeneration = 0
    var rewriting = false
    var listening = false
    var heard: String?
    var dictationWatch: AnyCancellable?
    /// The words so far while they hold fn and talk, from dictation's live preview.
    var liveWords = ""

    func setLiveWords(_ words: String) {
        guard listening, words != liveWords else { return }
        liveWords = words
        render()
    }

    /// The microphone's loudness while it listens, from Transcripted's dictation meter.
    func setVoiceLevel(_ level: CGFloat) {
        if listening { card.setVoiceLevel(level) }
    }
    private var returnDownAt: Date?
    private var returnTimer: Timer?

    // MARK: Lifecycle

    func startIfEnabled() {
        guard NextSentencePreferences.isEnabled(), hotKey == nil else { return }
        installHotKeyHandler()
        let id = EventHotKeyID(signature: OSType(0x4E58_5354), id: 1) // "NXST"
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKey)
        fnKey.start()
        wireCard()
        history.prewarm()
        semantic.refresh()
        NextSentenceSounds.shared.preload()
        DispatchQueue.global(qos: .utility).async { [claude] in claude.prewarm() }
    }

    func stop() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        fnKey.stop()
        close()
        history.stop()
        semantic.stop()
        claude.stop()
    }

    private func installHotKeyHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard id.signature == OSType(0x4E58_5354) else { return OSStatus(eventNotHandledErr) }
            let controller = Unmanaged<NextSentenceController>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { controller.toggle() } }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    private func wireCard() {
        card.onInsert = { [weak self] send in self?.insert(send: send) }
        card.onClose = { [weak self] in self?.escapePressed() }
        card.onBeginEditing = { [weak self] in self?.beginEditing(typing: nil) }
        card.onEndEditing = { [weak self] in self?.endEditing() }
        card.onTextEdited = { [weak self] in self?.textEdited() }
        card.onReturnDown = { [weak self] in self?.returnDown() }
        card.onReturnUp = { [weak self] in self?.returnUp() }
        card.onMood = { [weak self] tone, length in self?.set(tone: tone, length: length) }
        card.onGripStart = { [weak self] in self?.gripStarted() }
        card.onGripEnd = { [weak self] kept, whole in self?.gripEnded(kept: kept, whole: whole) }
        card.onSelectionCleared = { [weak self] in self?.card.closeOptions() }
        card.onFreshTake = { [weak self] in self?.rewrite(instruction: "") }
        card.onMic = { [weak self] in self?.fnTapped() }
        card.wordOptions = { [weak self] word in self?.swaps[word] ?? [] }
        card.onWordPick = { [weak self] range, word in self?.swap(range, to: word, step: 1) }
        card.onWordRoll = { [weak self] range, step in self?.roll(range, step: step) }
        card.onPickSelection = { [weak self] range in self?.picked(range) }
    }

    // MARK: Open and write

    func toggle() {
        card.isVisible && !card.content.compact ? close() : open()
    }

    /// fn: closed, it opens the card; open, it starts listening; listening, it finishes.
    func fnTapped() {
        guard card.isVisible, !card.content.compact else { return open() }
        if listening { finishListening() } else if heard == nil { startListening() }
    }

    /// Holding fn: with no card, open one that listens first and writes what you said; with a card
    /// open, speak a change. Let go to finish.
    func fnHoldBegan() {
        guard card.isVisible, !card.content.compact else { return open(listenFirst: true) }
        guard !listening, heard == nil else { return }
        heldListening = true
        startListening()
    }

    func fnHoldEnded() {
        guard heldListening else { return }
        heldListening = false
        finishListening()
    }

    /// What they said they want the message to say: write it now, or as soon as the context is ready.
    func useIntent(_ said: String) {
        awaitingIntent = false
        intent = said.isEmpty ? nil : said
        heard = nil
        note = nil
        render()
        if contextReady { write(steer: "") }
    }

    private func open(listenFirst: Bool = false) {
        let app = NSWorkspace.shared.frontmostApplication
        if let block = NextSentenceContext.blockReason(for: app) {
            return flash(block == .excludedApp ? "Write for Me doesn't run in password managers." : "Click into a text box first.")
        }
        guard let app else { return }
        generation += 1
        let gen = generation
        targetApp = app
        resetDraft()
        sources = []
        people = []
        contextFoundAt = nil
        intent = nil
        contextReady = false
        awaitingIntent = listenFirst
        voice = []
        swaps = [:]
        swapsRequested = []
        toneIndex = 1
        let focus = NextSentenceContext.captureFocus(of: app)
        snapshot = focus
        card.show(at: focus.caret, content: content())
        keyTap.start()
        if awaitingIntent {
            heldListening = true
            startListening()
        }

        Task { @MainActor in
            let window = await NextSentenceContext.captureWindow(into: focus)
            guard gen == self.generation else { return }
            self.snapshot = window
            self.render()
            // By meaning (EmbeddingGemma, on this Mac) and by keyword, at the same time.
            // Plus everything said about the people on screen, from their dictations, writing and meetings.
            let screen = window.screenText + "\n" + window.draft
            let names = NextSentencePrompt.people(screen: window.screenText, windowTitle: window.windowTitle)
            async let meaning = self.semantic.search(screen, screen: window.screenText)
            async let mentions = self.semantic.mentions(of: names, relatedTo: screen)
            async let keywords = self.history.lookUp(screen: screen)
            let (hits, aboutPeople, found) = await (meaning, mentions, keywords)
            guard gen == self.generation else { return }
            self.people = names
            self.sources = NextSentencePrompt.mergeSources(meaning: hits.map(\.chunk), people: aboutPeople, keywords: found.sources)
            self.contextFoundAt = Date()
            self.voice = found.voice.isEmpty
                ? hits.filter { $0.chunk.kind != "meeting" }.prefix(3).map { String($0.chunk.text.prefix(240)) }
                : found.voice
            self.contextReady = true
            self.render()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.45))
                guard gen == self.generation else { return }
                self.render()
            }
            // Opened by holding fn: wait for what they say, then useIntent writes.
            if self.awaitingIntent { return }
            self.write(steer: "")
        }
    }

    func request(steer: String = "") -> NextSentencePrompt.Request? {
        guard let snap = snapshot else { return nil }
        return NextSentencePrompt.Request(
            appName: snap.appName, windowTitle: snap.windowTitle, screenText: snap.screenText, draft: snap.draft,
            hasScreenshot: snap.screenshotJPEG != nil, sources: sources, voiceExamples: voice, steer: steer, people: people,
            intent: intent ?? "")
    }

    /// The one reply, streamed word by word. The moment it's done, the same reply is rewritten in every
    /// tone and length in the background, so the pad, arrows and end handle are instant after that.
    func write(steer: String) {
        guard let request = request(steer: steer) else { return }
        let gen = generation
        let image = snapshot?.screenshotJPEG
        let currentTone = tone
        streamTone = currentTone

        claude.stream(prompt: NextSentencePrompt.streamPrompt(request, tone: currentTone), image: image, onText: { piece in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard gen == self.generation else { return }
                self.streamText += piece
                self.render()
            } }
        }, completion: { result in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard gen == self.generation else { return }
                switch result {
                case .success(let text):
                    self.streamText = text
                    self.streamDone = true
                    self.writeVariations(of: text, tone: currentTone, length: NextSentencePrompt.mediumLength)
                case .failure(let error):
                    self.failure = error.localizedDescription
                }
                self.render()
            } }
        })
    }

    /// The reply on the card in all 3 tones and 5 lengths. Also re-run after a fresh take or a spoken
    /// change, so picking another tone or length keeps the new wording.
    func writeVariations(of base: String, tone baseTone: NextSentencePrompt.Tone, length baseLength: Int) {
        guard let request = request() else { return }
        let gen = generation
        let prompt = NextSentencePrompt.variationsPrompt(request, base: base, tone: baseTone, length: baseLength)
        claude.structured(.variations, prompt: prompt, image: snapshot?.screenshotJPEG) { result in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard gen == self.generation, case .success(let object) = result,
                      let variations = NextSentencePrompt.parseVariations(object) else { return }
                self.guesses = [variations]
                self.haveAllVersions = true
                self.render()
            } }
        }
    }

    func resetDraft() {
        streamText = ""
        streamDone = false
        guesses = []
        haveAllVersions = false
        failure = nil
        note = nil
        length = NextSentencePrompt.mediumLength
        guessIndex = 0
        custom = nil
        trimSource = nil
        typedEdits = false
        rewriting = false
        listening = false
        heard = nil
        dictationWatch = nil
        cancelReturnHold()
    }

    // MARK: Choosing

    func pickReply(_ index: Int) {
        guard guesses.count > 1, index != guessIndex else { return }
        guessIndex = (index + guesses.count) % guesses.count
        NextSentenceSounds.shared.play(.step(tone: toneIndex, length: length))
        changedVersion()
    }

    func set(tone: Int, length: Int) {
        let newTone = NextSentencePolicy.stepTone(tone, by: 0)
        let newLength = NextSentencePolicy.stepLength(length, by: 0)
        guard newTone != toneIndex || newLength != self.length else { return }
        toneIndex = newTone
        self.length = newLength
        NextSentenceSounds.shared.play(.step(tone: newTone, length: newLength))
        changedVersion()
    }

    private func changedVersion() {
        if card.isEditing { endEditing() }
        typedEdits = false
        custom = nil
        trimSource = nil
        rewriteGeneration += 1
        rewriting = false
        card.closeOptions()
        fadeNext = true
        render()
    }

    // MARK: Keys

    private func handle(_ action: NextSentencePolicy.KeyAction, typed: String, keyCode: Int64) {
        guard card.isVisible, !card.isEditing, !card.content.compact else { return }
        switch action {
        case .nextReply: pickReply(guessIndex + 1)
        case .previousReply: pickReply(guessIndex - 1)
        case .shorter: set(tone: toneIndex, length: length - 1)
        case .longer: set(tone: toneIndex, length: length + 1)
        case .moreDirect: set(tone: toneIndex - 1, length: length)
        case .warmer: set(tone: toneIndex + 1, length: length)
        case .edit: beginEditing(typing: nil)
        case .typeIntoCard:
            beginEditing(typing: keyCode == NextSentencePolicy.KeyCode.delete ? nil : typed)
            if keyCode == NextSentencePolicy.KeyCode.delete { card.deleteBackward() }
        case .returnDown: returnDown()
        case .returnUp: returnUp()
        case .close: listening && !awaitingIntent ? cancelListening() : escapePressed()
        case .ignore, .passThrough: break
        }
    }

    /// Return down starts the green ring; let go before it's full to insert, after to insert and send.
    func returnDown() {
        guard returnDownAt == nil else { return }
        returnDownAt = Date()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.returnTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        returnTimer = timer
    }

    func returnUp() {
        guard let start = returnDownAt else { return }
        let send = Date().timeIntervalSince(start) >= NextSentencePolicy.holdToSend
        cancelReturnHold()
        insert(send: send)
    }

    private func returnTick() {
        guard let start = returnDownAt else { return }
        let progress = NextSentencePolicy.holdProgress(heldFor: Date().timeIntervalSince(start), needed: NextSentencePolicy.holdToSend)
        card.setCharge(progress)
        card.setSendArmed(progress >= 1)
    }

    private func cancelReturnHold() {
        returnTimer?.invalidate()
        returnTimer = nil
        returnDownAt = nil
        card.setCharge(0)
        card.setSendArmed(false)
    }

    // MARK: Insert and close

    /// Pastes the message into the app. `send` also presses Return there, after the paste lands.
    func insert(send: Bool) {
        let text = card.currentText.nextSentenceCollapsedWhitespace
        guard !text.isEmpty, !listening, let app = targetApp else { return }
        generation += 1 // ignore anything still on its way
        keyTap.stop()
        if send { NextSentenceSynth.shared.sendRelease() } else { NextSentenceSounds.shared.play(.insert) }
        card.hide(exit: send ? .send : .insert)
        let target = DictationPasteTarget.capture(sourceApp: app)
        app.activate(options: [])
        switch paster.paste(text, target: target) {
        case .pasted, .likelyPasted:
            guard send else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                for down in [true, false] {
                    CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(NextSentencePolicy.KeyCode.returnKey), keyDown: down)?
                        .post(tap: .cghidEventTap)
                }
            }
        case .copied, .failed: flash("Copied. If it isn't there, press ⌘V.")
        }
    }

    /// Esc closes the card. If they've typed into it, the first Esc only says so, and a second within
    /// 1.5 seconds closes: a stray press can't lose their words. Without typing, one Esc closes.
    func escapePressed() {
        let armed = escapeArmedAt.map { Date().timeIntervalSince($0) < NextSentencePolicy.escapeConfirmWindow } ?? false
        guard typedEdits, !armed else { return close() }
        let armedAt = Date()
        escapeArmedAt = armedAt
        note = Self.escapeHint
        NextSentenceCardStyle.tick()
        render()
        DispatchQueue.main.asyncAfter(deadline: .now() + NextSentencePolicy.escapeConfirmWindow) { [weak self] in
            guard let self, self.escapeArmedAt == armedAt else { return }
            self.escapeArmedAt = nil
            if self.note == Self.escapeHint { self.note = nil }
            self.render()
        }
    }

    static let escapeHint = "Press Esc again to close"

    func close() {
        escapeArmedAt = nil
        if card.isVisible, !card.content.compact { NextSentenceSounds.shared.play(.close) }
        generation += 1
        if listening { cancelListening() }
        resetDraft()
        keyTap.stop()
        card.hide(exit: .dismiss)
    }

    /// A short note in the card's place, then gone.
    func flash(_ message: String) {
        let caret = targetApp.flatMap { AccessibilityBridge.focusedCaretRect(for: $0) }
        card.show(at: caret, content: .init(status: message, compact: true))
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, gen == self.generation, self.card.content.compact else { return }
            self.card.hide()
        }
    }
}
