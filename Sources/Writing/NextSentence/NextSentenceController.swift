import AppKit
import Carbon.HIToolbox
import Combine

/// Next Sentence: Caps Lock (or ⌃⌥Space) writes the next thing you'd type, from what's on screen and
/// your saved context. Tab moves between three different replies; ↑/↓ shorter and longer; ←/→ more
/// direct and warmer (the mood pad does both). Hover a word for others, drag across a part to remix
/// it, type to edit. Caps Lock again listens for a spoken change. Return inserts; hold it to send.
/// Owner-only lab feature, off unless `NextSentencePreferences.isEnabled()`. See that type for why.
@MainActor
final class NextSentenceController {
    /// Starts Transcripted's own dictation (injected by the app; this module can't name Dictation).
    var startDictation: (() -> Void)?
    /// Stops it without pasting anywhere and hands back what was said, once it's transcribed.
    var finishDictation: ((@escaping @MainActor (String) -> Void) -> AnyCancellable?)?

    let card = NextSentenceCard()
    let history = NextSentenceHistory()
    let claude = NextSentenceClaude()
    let paster = ClipboardRestoringTextPaster()
    lazy var keyTap = NextSentenceKeyTap { [weak self] action, typed, keyCode in
        self?.handle(action, typed: typed, keyCode: keyCode)
    }
    lazy var capsLock = NextSentenceCapsLock { [weak self] in self?.capsLockPressed() }
    private var hotKey: EventHotKeyRef?
    private var handlerInstalled = false

    // What's on screen and what's been written for it.
    var targetApp: NSRunningApplication?
    var snapshot: NextSentenceSnapshot?
    var sources: [NextSentencePrompt.Source] = []
    var voice: [String] = []
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
    var remix: (range: NSRange, variants: [String], index: Int)?
    var rewriteGeneration = 0
    var rewriting = false
    var listening = false
    var heard: String?
    var dictationWatch: AnyCancellable?
    private var returnDownAt: Date?
    private var returnTimer: Timer?

    // MARK: Lifecycle

    func startIfEnabled() {
        guard NextSentencePreferences.isEnabled(), hotKey == nil else { return }
        installHotKeyHandler()
        let id = EventHotKeyID(signature: OSType(0x4E58_5354), id: 1) // "NXST"
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKey)
        capsLock.start()
        wireCard()
        history.prewarm()
        DispatchQueue.global(qos: .utility).async { [claude] in claude.prewarm() }
    }

    func stop() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        capsLock.stop()
        close()
        history.stop()
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
        card.onClose = { [weak self] in self?.close() }
        card.onBeginEditing = { [weak self] in self?.beginEditing(typing: nil) }
        card.onEndEditing = { [weak self] in self?.endEditing() }
        card.onTextEdited = { [weak self] in self?.textEdited() }
        card.onReturnDown = { [weak self] in self?.returnDown() }
        card.onReturnUp = { [weak self] in self?.returnUp() }
        card.onPickReply = { [weak self] index in self?.pickReply(index) }
        card.onMood = { [weak self] tone, length in self?.set(tone: tone, length: length) }
        card.onLength = { [weak self] length in
            guard let self else { return }
            self.set(tone: self.toneIndex, length: length)
        }
        card.onFreshTake = { [weak self] in self?.rewrite(instruction: "") }
        card.onMic = { [weak self] in self?.capsLockPressed() }
        card.wordOptions = { [weak self] word in self?.swaps[word] ?? [] }
        card.onWordPick = { [weak self] range, word in self?.swap(range, to: word, step: 1) }
        card.onWordRoll = { [weak self] range, step in self?.roll(range, step: step) }
        card.onPickSelection = { [weak self] range in self?.picked(range) }
        card.onRemixPart = { [weak self] range in self?.remixPart(range) }
    }

    // MARK: Open and write

    func toggle() {
        card.isVisible && !card.content.compact ? close() : open()
    }

    /// Caps Lock: closed, it opens the card; open, it starts listening; listening, it finishes.
    func capsLockPressed() {
        guard card.isVisible, !card.content.compact else { return open() }
        if listening { finishListening() } else if heard == nil { startListening() }
    }

    private func open() {
        let app = NSWorkspace.shared.frontmostApplication
        if let block = NextSentenceContext.blockReason(for: app) {
            return flash(block == .excludedApp ? "Next Sentence doesn't run in password managers." : "Click into a text box first.")
        }
        guard let app else { return }
        generation += 1
        let gen = generation
        targetApp = app
        resetDraft()
        sources = []
        voice = []
        swaps = [:]
        swapsRequested = []
        toneIndex = 1
        let focus = NextSentenceContext.captureFocus(of: app)
        snapshot = focus
        card.show(at: focus.caret, content: content())
        keyTap.start()

        Task { @MainActor in
            let window = await NextSentenceContext.captureWindow(into: focus)
            guard gen == self.generation else { return }
            self.snapshot = window
            self.render()
            let found = await self.history.lookUp(screen: window.screenText + "\n" + window.draft)
            guard gen == self.generation else { return }
            self.sources = found.sources
            self.voice = found.voice
            self.write(steer: "")
        }
    }

    func request(steer: String = "") -> NextSentencePrompt.Request? {
        guard let snap = snapshot else { return nil }
        return NextSentencePrompt.Request(
            appName: snap.appName, windowTitle: snap.windowTitle, screenText: snap.screenText, draft: snap.draft,
            hasScreenshot: snap.screenshotJPEG != nil, sources: sources, voiceExamples: voice, steer: steer)
    }

    /// Three requests at once: the likeliest reply streamed word by word, three different replies in the
    /// current tone (~4s, so Tab works early), and all three in every tone and length (~13s).
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
                case .failure(let error):
                    if self.guesses.isEmpty { self.failure = error.localizedDescription }
                }
                self.render()
            } }
        })
        claude.structured(.guesses, prompt: NextSentencePrompt.guessesPrompt(request, tone: currentTone), image: image) { result in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard gen == self.generation, !self.haveAllVersions,
                      case .success(let object) = result,
                      let quick = NextSentencePrompt.parseGuesses(object, tone: currentTone) else { return }
                self.guesses = quick
                self.render()
            } }
        }
        writeAllVersions(request, image: image)
    }

    /// Every reply in every tone and length. Also re-run after a spoken change, so the other tones
    /// and lengths carry it too.
    func writeAllVersions(_ request: NextSentencePrompt.Request, image: Data?) {
        let gen = generation
        claude.structured(.full, prompt: NextSentencePrompt.fullPrompt(request), image: image) { result in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard gen == self.generation, case .success(let object) = result,
                      let full = NextSentencePrompt.parseFull(object) else { return }
                self.guesses = full
                self.haveAllVersions = true
                self.failure = nil
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
        remix = nil
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
        changedVersion()
    }

    func set(tone: Int, length: Int) {
        let newTone = NextSentencePolicy.stepTone(tone, by: 0)
        let newLength = NextSentencePolicy.stepLength(length, by: 0)
        guard newTone != toneIndex || newLength != self.length else { return }
        toneIndex = newTone
        self.length = newLength
        changedVersion()
    }

    private func changedVersion() {
        custom = nil
        remix = nil
        rewriteGeneration += 1
        rewriting = false
        card.hideRemixChip()
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
        case .close: listening ? cancelListening() : close()
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
        card.setRing(progress, color: NextSentenceCardStyle.send)
        card.setSendArmed(progress >= 1)
    }

    private func cancelReturnHold() {
        returnTimer?.invalidate()
        returnTimer = nil
        returnDownAt = nil
        card.setRing(0, color: NextSentenceCardStyle.send)
        card.setSendArmed(false)
    }

    // MARK: Insert and close

    /// Pastes the message into the app. `send` also presses Return there, after the paste lands.
    func insert(send: Bool) {
        let text = card.currentText.nextSentenceCollapsedWhitespace
        guard !text.isEmpty, !listening, let app = targetApp else { return }
        generation += 1 // ignore anything still on its way
        keyTap.stop()
        card.hide()
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

    func close() {
        generation += 1
        if listening { cancelListening() }
        resetDraft()
        keyTap.stop()
        card.hide()
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
