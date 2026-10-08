#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif
import Cocoa
import InputMethodKit
import OSLog

/// A deliberately small IMKit keyboard: marked-text display, type-through,
/// dictionary suffixes, and phrase requests to Tilde's app-owned model.
@objc(GhostInputController)
final class GhostInputController: IMKInputController {
    static let unset = NSRange(location: NSNotFound, length: NSNotFound)
    static let contextLimit = 3_000
    private static let trailingContextLimit = 80
    private static let slowKeyThreshold: TimeInterval = 0.050
    /// Chained accept: once the ghost is fully consumed by Tab or the whole-
    /// accept key, ask for the next continuation right away. See
    /// `TildeProductProfile.chainsCompletionAfterAccept`.
    /// Interaction behaviour comes from the app's served configuration, not
    /// this bundle: the same request in the same app must never chain,
    /// reveal, or start on punctuation differently in two processes.
    private static var chainsAfterAccept: Bool { ServedConfiguration.interaction.chainsCompletionAfterAccept }
    /// The request a consumed accept chained. A Tab that lands before that
    /// ghost appears is held rather than handed to the host: the writer is
    /// mid-chain, and in an Electron composer a stray Tab moves focus out.
    var chainedTabHold = ChainedTabHold()
    private static let slowKeyLogger = Logger(
        subsystem: TildeProductProfile.current.inputMethodBundleIdentifier,
        category: "typing-performance"
    )
    static let roundTripLogger = Logger(
        subsystem: TildeProductProfile.current.inputMethodBundleIdentifier,
        category: "suggestion-latency"
    )
    /// Chained-accept outcomes, reason codes only, never text.
    static let chainLogger = Logger(
        subsystem: TildeProductProfile.current.inputMethodBundleIdentifier,
        category: "chained-accept"
    )
    /// Electron/Chromium hosts update the caret and document length
    /// asynchronously after `insertText`. A chained request that reads the
    /// field immediately after an accept sees the pre-insert caret, judges
    /// the just-inserted ghost as trailing text, and bails at the growing-
    /// edge check. Keystroke requests never hit this because the next key
    /// arrives after the host has caught up.
    static let chainedCalmSettleNanoseconds: UInt64 = 90_000_000
    static var calmRevealDelays: SuggestionRevealDelayPolicy.CalmDelays { ServedConfiguration.interaction.calmRevealDelays }
    static var requestsAfterPunctuation: Bool { ServedConfiguration.interaction.requestsAfterPunctuation }
    /// Whether the model is asked to finish the word being typed, not just to
    /// open the next one. Served by the app, like every other interaction
    /// behaviour.
    static var requestsMidWordContinuation: Bool {
        ServedConfiguration.interaction.requestsMidWordContinuation
    }
    /// How long a request from `boundary` waits before it leaves. Word and
    /// punctuation boundaries never wait; only the mid-word path, which a
    /// keystroke can retrigger ten times a second, is held back — by the
    /// served policy's throttle, so the number is part of the digest.
    static func requestThrottleNanoseconds(
        for boundary: TextFreeCursorBoundary?,
        policy: InteractionPolicy
    ) -> UInt64 {
        boundary == .midWord ? UInt64(max(0, policy.midWordRequestThrottleMilliseconds)) * 1_000_000 : 0
    }

    struct SlowKeyTiming {
        let totalMilliseconds: Int
        let queuedMilliseconds: Int
        let handlerMilliseconds: Int
    }

    static func slowKeyTiming(
        eventTimestamp: TimeInterval,
        handlerStartedAt: TimeInterval,
        handlerFinishedAt: TimeInterval
    ) -> SlowKeyTiming? {
        let total = max(0, handlerFinishedAt - eventTimestamp)
        guard total >= slowKeyThreshold else { return nil }
        return SlowKeyTiming(
            totalMilliseconds: Int((total * 1_000).rounded()),
            queuedMilliseconds: Int((max(0, handlerStartedAt - eventTimestamp) * 1_000).rounded()),
            handlerMilliseconds: Int((max(0, handlerFinishedAt - handlerStartedAt) * 1_000).rounded())
        )
    }

    static func shouldAcceptWholeSuggestion(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        let shortcutModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .function]
        return keyCode == 50 && modifiers.intersection(shortcutModifiers).isEmpty
    }

    static func trailingContextRange(
        selection: NSRange,
        markedRange: NSRange,
        documentLength: Int
    ) -> NSRange? {
        guard selection.location != NSNotFound,
              selection.length == 0,
              documentLength > selection.location else {
            return nil
        }

        // While a ghost is visible, some clients include Tilde's own marked
        // text in their document length. Skip that range so the acceptance
        // safety check examines only the writer's real trailing content.
        let start: Int
        if markedRange.location == selection.location,
           markedRange.length <= documentLength - selection.location {
            start = NSMaxRange(markedRange)
        } else {
            start = selection.location
        }
        guard documentLength > start else { return nil }
        return NSRange(
            location: start,
            length: min(trailingContextLimit, documentLength - start)
        )
    }

    struct FallbackOwner: Equatable {
        let bundle: String
        let caret: Int
    }

    struct InsertionObservation {
        let bundle: String
        let selection: NSRange

        var owner: FallbackOwner? {
            guard selection.location != NSNotFound, selection.length == 0 else { return nil }
            return FallbackOwner(bundle: bundle, caret: selection.location)
        }
    }

    /// IMKit creates one controller for each input session.
    let suggestionSessionIdentifier = UUID().uuidString
    /// Personal History needs a stricter notion of continuity than IMKit's
    /// unstable client identifiers. Rotate this on known edit/session
    /// boundaries so replay does not join across deletion or navigation.
    var historySegmentIdentifier = UUID().uuidString
    /// Transcripted: the keyboard's own text in this segment chain, so a
    /// Backspace right after it can be reported to Save my writing.
    var historyDeletions = PersonalHistoryDeletionTracker()
    var state = InlineSuggestionState()
    var typedFallback = ""
    var fallbackOwner: FallbackOwner?
    var historyOwner: FallbackOwner?
    var scheduleRevision = 0
    var contextTailSampler = GhostContextTailSampler(limit: GhostInputController.contextLimit)
    var revealTask: Task<Void, Never>?
    var modelTask: Task<Void, Never>?
    var bufferedReveal: (text: String, ticket: InlineSuggestionTicket, provenance: GhostProvenance)?
    /// The app's receipt for the ghost most recently handed to the reducer,
    /// read back by `recordOutcomeShown` when the `.shown` effect fires.
    var presentedProvenance: (ticket: InlineSuggestionTicket, provenance: GhostProvenance)?
    /// The eligible opportunity the keyboard has asked the app about and
    /// not yet shown or closed. Every path that ends it says why, once.
    var openOpportunity: (ticket: InlineSuggestionTicket, id: UUID)?
    private var screenMemoryTypingTask: Task<Void, Never>?

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event, event.type == .keyDown, let client = sender as? IMKTextInput else {
            return false
        }
        let handlerStartedAt = ProcessInfo.processInfo.systemUptime
        defer {
            if let timing = Self.slowKeyTiming(
                eventTimestamp: event.timestamp,
                handlerStartedAt: handlerStartedAt,
                handlerFinishedAt: ProcessInfo.processInfo.systemUptime
            ) {
                Self.slowKeyLogger.notice(
                    "slow-key totalMilliseconds=\(timing.totalMilliseconds, privacy: .public) queuedMilliseconds=\(timing.queuedMilliseconds, privacy: .public) handlerMilliseconds=\(timing.handlerMilliseconds, privacy: .public)"
                )
            }
        }
        let secureInput = IsSecureEventInputEnabled()
        if secureInput {
            screenMemoryTypingTask?.cancel()
            screenMemoryTypingTask = nil
            notifyScreenMemory(.textFieldBlurred)
            PersonalHistoryCapture.shared.sensitiveInputBegan()
            GhostOutcomeLedger.markPrivacyExcluded()
            breakHistorySegment()
            dismiss(client)
            resetFallback()
            return false
        }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command)
            || modifiers.contains(.control)
            || modifiers.contains(.function)
            || modifiers.contains(.option) {
            breakHistorySegment()
            dismiss(client)
            resetFallback()
            return false
        }

        let typedGrapheme = printableGrapheme(from: event)
        let defaults = UserDefaults.standard
        let suggestionsEnabled = defaults.object(forKey: "GhostSuggestionsEnabled") as? Bool ?? true
        let paused = PersonalHistorySettingsContract.isPaused(
            pausedUntil: defaults.double(forKey: PersonalHistorySettingsContract.pausedUntilKey),
            now: Date()
        )
        guard suggestionsEnabled, !paused else {
            dismiss(client)
            resetFallback()
            if paused {
                // Transcripted: nothing typed during a pause is captured,
                // whenever it would have reached the app. Suggestions merely
                // off (Save my writing alone) still capture below.
                breakHistorySegment()
            } else if let typedGrapheme {
                capturePersonalHistory(
                    typedGrapheme,
                    source: .typed,
                    client: client,
                    secureInput: secureInput,
                    observation: nil
                )
            } else if event.keyCode == 51 {
                noteHistoryBackspace(client, secureInput: secureInput, observation: nil)
            } else {
                breakHistorySegment()
            }
            return false
        }
        let previousOwner = fallbackOwner
        let insertionObservation = synchronizeFallback(with: client)
        // Transcripted (Tilde bug fix): the app scope and the exclusion list
        // gate suggestions too, not only capture and screen context. Outside
        // them keys behave as with suggestions off, and nothing is captured.
        guard WritingAppScopeReader.shared.allowsSuggestions(in: insertionObservation.bundle) else {
            dismiss(client)
            resetFallback()
            breakHistorySegment()
            return false
        }
        if previousOwner != insertionObservation.owner {
            notifyScreenMemory(.textFieldFocused)
        }
        if typedGrapheme != nil {
            scheduleScreenMemoryTypingPause()
        }

        switch event.keyCode {
        case 48: // Plain Tab accepts one word. Shift-Tab remains the host app's key.
            guard !modifiers.contains(.shift) else {
                breakHistorySegment()
                dismiss(client)
                return false
            }
            let outcome = Self.routePlainTab(awaitingChainedGhost: awaitingChainedGhost) {
                acceptSuggestion(client, observation: insertionObservation)
            }
            if outcome == .passedToHost { breakHistorySegment() }
            return outcome != .passedToHost

        case 50: // The physical backtick/tilde key accepts the whole visible suggestion.
            guard Self.shouldAcceptWholeSuggestion(
                keyCode: event.keyCode,
                modifiers: modifiers
            ) else { break }
            let accepted = acceptAllSuggestion(client, observation: insertionObservation)
            if !accepted { breakHistorySegment() }
            return accepted

        case 53: // Escape dismisses only when something is visible.
            let wasVisible = state.isVisible
            dismiss(client)
            if wasVisible {
                GhostOutcomeLedger.noteDismissed()
            } else {
                breakHistorySegment()
            }
            return wasVisible

        case 51: // The host owns deletion; wait for the next typed character.
            noteHistoryBackspace(client, secureInput: secureInput, observation: insertionObservation)
            dismiss(client)
            resetFallback()
            return false

        default:
            break
        }

        if let grapheme = typedGrapheme {
            let match = matchingVisibleState(for: client)
            cancelPendingWork()
            let advanced = match.map { match in
                match.ticket.advancing(
                    with: grapheme,
                    boundedContext: match.context,
                    utf16Limit: Self.contextLimit
                )
            }
            let current = match?.ticket
            let effects = state.reduce(.type(grapheme, current: current, advanced: advanced))
            apply(effects, to: client)
            GhostOutcomeLedger.noteTyped()
            GhostOutcomeLedger.closeIfGhostGone(stillVisible: state.isVisible)
            appendFallback(grapheme, for: client)
            capturePersonalHistory(
                grapheme,
                source: .typed,
                client: client,
                secureInput: secureInput,
                observation: insertionObservation
            )
            return true
        }

        dismiss(client)
        breakHistorySegment()
        resetFallback()
        return false
    }

    /// Client-driven composition endings must never commit an unaccepted ghost.
    override func commitComposition(_ sender: Any!) {
        if let client = sender as? IMKTextInput { dismiss(client) }
        GhostOutcomeLedger.closeOpenGhost()
        breakHistorySegment()
    }

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        GhostOutcomeLedger.configure { [weak self] in
            guard let self, let liveClient = self.client() else { return nil }
            if IsSecureEventInputEnabled() { return nil }
            return self.contextBeforeCaret(liveClient)
        }
        guard !IsSecureEventInputEnabled() else { return }
        notifyScreenMemory(.textFieldFocused)
    }

    override func deactivateServer(_ sender: Any!) {
        screenMemoryTypingTask?.cancel()
        screenMemoryTypingTask = nil
        notifyScreenMemory(.textFieldBlurred)
        GhostStats.flush(force: true)
        PersonalHistoryCapture.shared.flush()
        GhostOutcomeLedger.closeSegment()
        if let client = sender as? IMKTextInput { dismiss(client) }
        breakHistorySegment()
        resetFallback()
        super.deactivateServer(sender)
    }

    private func scheduleScreenMemoryTypingPause() {
        screenMemoryTypingTask?.cancel()
        let delay = UInt64(CaptureTriggerPolicy.typingPauseThresholdSeconds * 1_000_000_000)
        screenMemoryTypingTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            self?.notifyScreenMemory(.typingPaused)
        }
    }

    func notifyScreenMemory(_ kind: ScreenMemoryInputEvent.Kind) {
        let event = ScreenMemoryInputEvent(
            kind: kind,
            sessionIdentifier: suggestionSessionIdentifier
        )
        Task { _ = await GhostBrainClient.notifyScreenMemory(event) }
    }

    // MARK: - Input and effects

    private func printableGrapheme(from event: NSEvent) -> String? {
        guard let characters = event.characters, characters.count == 1 else { return nil }
        guard characters.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) else {
            return nil
        }
        return characters
    }

    /// IMKit exposes no field semantics. Fail closed when the host protects a
    /// field with macOS secure event input.
    func stopForSecureInput(_ client: IMKTextInput) -> Bool {
        guard IsSecureEventInputEnabled() else { return false }
        PersonalHistoryCapture.shared.sensitiveInputBegan()
        GhostOutcomeLedger.markPrivacyExcluded()
        breakHistorySegment()
        dismiss(client)
        resetFallback()
        return true
    }

    private func appendFallback(_ text: String, for client: IMKTextInput) {
        guard let owner = fallbackOwner else {
            resetFallback()
            return
        }
        typedFallback = InlineSuggestionTicket.boundedContext(
            typedFallback + text,
            utf16Limit: Self.contextLimit
        )
        fallbackOwner = FallbackOwner(
            bundle: owner.bundle,
            caret: owner.caret + text.utf16.count
        )
    }

    private func synchronizeFallback(with client: IMKTextInput) -> InsertionObservation {
        let observation = InsertionObservation(
            bundle: client.bundleIdentifier() ?? "",
            selection: client.selectedRange()
        )
        guard let current = observation.owner else {
            resetFallback()
            return observation
        }
        if fallbackOwner != current {
            typedFallback = ""
            fallbackOwner = current
        }
        return observation
    }

    func resetFallback() {
        typedFallback = ""
        fallbackOwner = nil
    }

    func fallbackOwner(for client: IMKTextInput) -> FallbackOwner? {
        let selection = client.selectedRange()
        guard selection.location != NSNotFound, selection.length == 0 else { return nil }
        return FallbackOwner(
            bundle: client.bundleIdentifier() ?? "",
            caret: selection.location
        )
    }

    /// Resolved once per visible suggestion chain because querying the host's
    /// text attributes is synchronous cross-process work.
    private var cachedGhostStyle: [NSAttributedString.Key: Any]?

    func apply(_ effects: [InlineSuggestionState.Effect], to client: IMKTextInput, shown: ShownFieldState? = nil) {
        for effect in effects {
            switch effect {
            case .hide:
                cachedGhostStyle = nil
                client.setMarkedText(
                    "",
                    selectionRange: NSRange(location: 0, length: 0),
                    replacementRange: Self.unset
                )
            case let .insert(text):
                client.insertText(text, replacementRange: Self.unset)
            case let .show(text):
                client.setMarkedText(
                    NSAttributedString(string: text, attributes: ghostStyle(client)),
                    selectionRange: NSRange(location: 0, length: 0),
                    replacementRange: Self.unset
                )
                GhostOutcomeLedger.noteVisibleCandidate(
                    characters: text.count,
                    wordCount: text.split(whereSeparator: \Character.isWhitespace).count
                )
            case let .schedule(afterTyping: grapheme):
                scheduleSuggestion(for: client, afterUserTyped: grapheme)
            case .shown:
                GhostStats.recordSuggestionShown()
                recordOutcomeShown(client, shown: shown)
            case .accepted:
                GhostStats.recordSuggestionAccepted()
            }
        }
    }

    private func ghostStyle(_ client: IMKTextInput) -> [NSAttributedString.Key: Any] {
        if let cachedGhostStyle { return cachedGhostStyle }

        var lineRect = NSRect.zero
        let reported = client.attributes(forCharacterIndex: 0, lineHeightRectangle: &lineRect)
        let reportedFont = (reported?[NSAttributedString.Key.font.rawValue]
            ?? reported?[NSAttributedString.Key.font]) as? NSFont

        let pointSize = CGFloat(InlineGhostFontPolicy.resolvedPointSize(
            reportedPointSize: reportedFont.map { Double($0.pointSize) },
            measuredLineHeight: lineRect.height.isFinite ? Double(lineRect.height) : nil,
            fallbackPointSize: Double(NSFont.systemFontSize)
        ))
        let font: NSFont
        if let reportedFont, reportedFont.pointSize == pointSize {
            font = reportedFont
        } else if let reportedFont {
            font = NSFont(descriptor: reportedFont.fontDescriptor, size: pointSize)
                ?? .systemFont(ofSize: pointSize)
        } else {
            font = .systemFont(ofSize: pointSize)
        }

        let spec = InlineGhostColorSpec.markedText
        var style: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(
                calibratedWhite: CGFloat(spec.fillWhite),
                alpha: CGFloat(spec.fillAlpha)
            ),
        ]
        // Chromium and Electron ignore a composition's foreground colour and
        // always draw an underline under it; with no underline attribute of
        // our own that underline is thick and text-coloured, which is what
        // makes the ghost read as "underlined text" instead of grey text in
        // browsers. They do honour the underline's own style and colour, so
        // in those hosts the marked text carries a thin, faint underline —
        // the closest a Chromium composition can get to a ghost. Native
        // editors honour the grey fill and get no underline at all.
        if usesCalmReveal(for: client.bundleIdentifier() ?? "") {
            style[.underlineStyle] = NSUnderlineStyle.single.rawValue
            style[.underlineColor] = NSColor(calibratedWhite: CGFloat(spec.fillWhite), alpha: 0.45)
        }
        cachedGhostStyle = style
        return style
    }

    func dismiss(_ client: IMKTextInput) {
        cancelPendingWork()
        apply(state.reduce(.dismiss), to: client)
    }

    private func acceptSuggestion(
        _ client: IMKTextInput,
        observation: InsertionObservation
    ) -> Bool {
        guard canAcceptSuggestion(in: client) else {
            dismiss(client)
            return false
        }
        let match = matchingVisibleState(for: client)
        cancelPendingWork()
        let effects = state.reduce(.acceptNextWord(
            current: match?.ticket,
            boundedContext: match?.context ?? "",
            utf16Limit: Self.contextLimit
        ))
        guard case let .insert(accepted)? = effects.first(where: {
            if case .insert = $0 { return true }
            return false
        }) else {
            apply(effects, to: client)
            return false
        }
        apply(effects, to: client)
        appendFallback(accepted, for: client)
        capturePersonalHistory(
            accepted,
            source: .acceptedSuggestion,
            client: client,
            secureInput: IsSecureEventInputEnabled(),
            observation: observation
        )
        GhostStats.recordAccepted(accepted)
        GhostOutcomeLedger.noteAccepted(
            accepted,
            kind: .word,
            remainderVisible: state.isVisible
        )
        chainAfterAcceptIfConsumed(client)
        return true
    }

    /// The reward for a correct ghost used to be silence: accepting its last
    /// word left the caret at a word boundary with nothing scheduled until
    /// the next keystroke. When the profile chains, the accepted text (which
    /// ends in the separator) is the new context and the next three words
    /// are requested at once, through the ordinary schedule path with its
    /// reveal delay, activation checks, and ticket rules intact.
    private func chainAfterAcceptIfConsumed(_ client: IMKTextInput) {
        guard Self.chainsAfterAccept, !state.isVisible else { return }
        scheduleSuggestion(for: client, afterUserTyped: " ", chained: true)
        chainedTabHold.chained(revision: scheduleRevision)
    }

    /// True while the request a consumed accept chained is still on its way.
    /// Any newer schedule (a keystroke, a dismissal) moves the revision on,
    /// so an ordinary Tab is never held.
    private func awaitingChainedGhost() -> Bool {
        Self.chainsAfterAccept && chainedTabHold.isAwaitingGhost(
            scheduleRevision: scheduleRevision, requestPending: state.pendingTicket != nil, ghostVisible: state.isVisible
        )
    }

    private func acceptAllSuggestion(
        _ client: IMKTextInput,
        observation: InsertionObservation
    ) -> Bool {
        guard canAcceptSuggestion(in: client) else {
            dismiss(client)
            return false
        }
        let match = matchingVisibleState(for: client)
        cancelPendingWork()
        let effects = state.reduce(.acceptAll(
            current: match?.ticket,
            appendsSeparator: Self.chainsAfterAccept
        ))
        guard case let .insert(accepted)? = effects.first(where: {
            if case .insert = $0 { return true }
            return false
        }) else {
            apply(effects, to: client)
            return false
        }
        apply(effects, to: client)
        appendFallback(accepted, for: client)
        capturePersonalHistory(
            accepted,
            source: .acceptedSuggestion,
            client: client,
            secureInput: IsSecureEventInputEnabled(),
            observation: observation
        )
        GhostStats.recordAccepted(accepted)
        GhostOutcomeLedger.noteAccepted(
            accepted,
            kind: .all,
            remainderVisible: state.isVisible
        )
        chainAfterAcceptIfConsumed(client)
        return true
    }

    private func capturePersonalHistory(
        _ text: String,
        source: PersonalHistoryEventSource,
        client: IMKTextInput,
        secureInput: Bool,
        observation: InsertionObservation?
    ) {
        let bundle = observation?.bundle ?? client.bundleIdentifier()
        guard let permit = PersonalHistoryCapture.shared.permit(
            appBundleIdentifier: bundle,
            secureInput: secureInput
        ) else {
            invalidateHistoryContinuity()
            return
        }
        let observed = observation ?? InsertionObservation(
            bundle: permit.appBundleIdentifier,
            selection: client.selectedRange()
        )
        guard prepareHistoryInsertion(text, observation: observed) else { return }
        PersonalHistoryCapture.shared.record(
            text: text,
            source: source,
            sessionIdentifier: historySegmentIdentifier,
            permit: permit
        )
        historyDeletions.inserted(text)
    }

    /// Transcripted: a plain Backspace. The host still deletes; this only
    /// reports it when the character is the keyboard's own, sent in this
    /// segment chain and still right before the caret. Anything else breaks
    /// the segment, as every Backspace did in Tilde. Reads the caret only
    /// when there is something to report.
    private func noteHistoryBackspace(
        _ client: IMKTextInput,
        secureInput: Bool,
        observation: InsertionObservation?
    ) {
        guard let owner = historyOwner, historyDeletions.hasTrackedText else {
            breakHistorySegment()
            return
        }
        let observed = observation ?? InsertionObservation(
            bundle: client.bundleIdentifier() ?? "",
            selection: client.selectedRange()
        )
        guard observed.owner == owner,
              let permit = PersonalHistoryCapture.shared.permit(
                appBundleIdentifier: owner.bundle,
                secureInput: secureInput
              ),
              let backspace = historyDeletions.backspace() else {
            breakHistorySegment()
            return
        }
        // Tilde's predictor saw a new segment after every Backspace; it still
        // does. The continuation keeps the chain for the day file.
        if backspace.rotatesSegment {
            historySegmentIdentifier = PersonalHistorySegmentChain.continuation(
                of: historySegmentIdentifier
            )
        }
        historyOwner = FallbackOwner(
            bundle: owner.bundle,
            caret: max(0, owner.caret - backspace.utf16Length)
        )
        PersonalHistoryCapture.shared.recordDeletion(
            utf16Length: backspace.utf16Length,
            sessionIdentifier: historySegmentIdentifier,
            permit: permit
        )
    }

    // MARK: - App watchdog

    private static var lastBrainSummon = Date.distantPast

    static func summonBrainIfNeeded() {
        DispatchQueue.main.async {
            guard Date().timeIntervalSince(lastBrainSummon) >= 60 else { return }
            guard !UserDefaults.standard.bool(forKey: "GhostBrainQuietQuit") else { return }
            // Transcripted deviation from Tilde: if the app is already running,
            // the brain is only starting up (model or helper still loading).
            // Opening it again would deliver a reopen event, and Transcripted
            // answers reopen by showing its window, up to once a minute.
            guard NSRunningApplication.runningApplications(
                withBundleIdentifier: TildeProductProfile.current.appBundleIdentifier
            ).isEmpty else { return }
            guard let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: TildeProductProfile.current.appBundleIdentifier
            ) else {
                return
            }
            lastBrainSummon = Date()
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
    }
}
