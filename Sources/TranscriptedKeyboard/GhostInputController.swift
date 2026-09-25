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
    private static let unset = NSRange(location: NSNotFound, length: NSNotFound)
    private static let contextLimit = 3_000
    private static let trailingContextLimit = 80
    private static let slowKeyThreshold: TimeInterval = 0.050
    /// Chained accept: once the ghost is fully consumed by Tab or the whole-
    /// accept key, ask for the next continuation right away. See
    /// `TildeProductProfile.chainsCompletionAfterAccept`.
    /// Interaction behaviour comes from the app's served configuration, not
    /// this bundle: the same request in the same app must never chain,
    /// reveal, or start on punctuation differently in two processes.
    private static var chainsAfterAccept: Bool { ServedConfiguration.interaction.chainsCompletionAfterAccept }
    /// The schedule revision of the request a consumed accept chained, while
    /// it is still the live one. A Tab that lands before that ghost appears
    /// is held rather than handed to the host: the writer is mid-chain, and
    /// in an Electron composer a stray Tab moves focus out of the field.
    private var chainedRequestRevision: Int?
    private static let slowKeyLogger = Logger(
        subsystem: TildeProductProfile.current.inputMethodBundleIdentifier,
        category: "typing-performance"
    )
    private static let roundTripLogger = Logger(
        subsystem: TildeProductProfile.current.inputMethodBundleIdentifier,
        category: "suggestion-latency"
    )
    /// Chained-accept outcomes, reason codes only, never text.
    private static let chainLogger = Logger(
        subsystem: TildeProductProfile.current.inputMethodBundleIdentifier,
        category: "chained-accept"
    )
    /// Electron/Chromium hosts update the caret and document length
    /// asynchronously after `insertText`. A chained request that reads the
    /// field immediately after an accept sees the pre-insert caret, judges
    /// the just-inserted ghost as trailing text, and bails at the growing-
    /// edge check. Keystroke requests never hit this because the next key
    /// arrives after the host has caught up.
    private static let chainedCalmSettleNanoseconds: UInt64 = 90_000_000
    private static var calmRevealDelays: SuggestionRevealDelayPolicy.CalmDelays { ServedConfiguration.interaction.calmRevealDelays }
    private static var requestsAfterPunctuation: Bool { ServedConfiguration.interaction.requestsAfterPunctuation }
    /// Whether the model is asked to finish the word being typed, not just to
    /// open the next one. Served by the app, like every other interaction
    /// behaviour.
    private static var requestsMidWordContinuation: Bool {
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

    private struct FallbackOwner: Equatable {
        let bundle: String
        let caret: Int
    }

    private struct InsertionObservation {
        let bundle: String
        let selection: NSRange

        var owner: FallbackOwner? {
            guard selection.location != NSNotFound, selection.length == 0 else { return nil }
            return FallbackOwner(bundle: bundle, caret: selection.location)
        }
    }

    /// IMKit creates one controller for each input session.
    private let suggestionSessionIdentifier = UUID().uuidString
    /// Personal History needs a stricter notion of continuity than IMKit's
    /// unstable client identifiers. Rotate this on known edit/session
    /// boundaries so replay does not join across deletion or navigation.
    private var historySegmentIdentifier = UUID().uuidString
    /// Transcripted: the keyboard's own text in this segment chain, so a
    /// Backspace right after it can be reported to Save my writing.
    private var historyDeletions = PersonalHistoryDeletionTracker()
    private var state = InlineSuggestionState()
    private var typedFallback = ""
    private var fallbackOwner: FallbackOwner?
    private var historyOwner: FallbackOwner?
    private var scheduleRevision = 0
    private var lastScheduledContextTail = ""
    private var revealTask: Task<Void, Never>?
    private var modelTask: Task<Void, Never>?
    private var bufferedReveal: (text: String, ticket: InlineSuggestionTicket, provenance: GhostProvenance)?
    /// The app's receipt for the ghost most recently handed to the reducer,
    /// read back by `recordOutcomeShown` when the `.shown` effect fires.
    private var presentedProvenance: (ticket: InlineSuggestionTicket, provenance: GhostProvenance)?
    /// The eligible opportunity the keyboard has asked the app about and
    /// not yet shown or closed. Every path that ends it says why, once.
    private var openOpportunity: (ticket: InlineSuggestionTicket, id: UUID)?
    private var screenMemoryTypingTask: Task<Void, Never>?
    private var calmRevealByBundle = [String: Bool]()

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
        let paused = defaults.double(forKey: "GhostPausedUntil") > Date().timeIntervalSince1970
        guard suggestionsEnabled, !paused else {
            dismiss(client)
            resetFallback()
            if let typedGrapheme {
                capturePersonalHistory(
                    typedGrapheme,
                    source: .typed,
                    client: client,
                    secureInput: secureInput,
                    observation: nil
                )
            } else if event.keyCode == 51 {
                noteHistoryBackspace(client, observation: nil)
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
            let accepted = acceptSuggestion(client, observation: insertionObservation)
            if !accepted {
                if awaitingChainedGhost() { return true }
                breakHistorySegment()
            }
            return accepted

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
            noteHistoryBackspace(client, observation: insertionObservation)
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

    private func notifyScreenMemory(_ kind: ScreenMemoryInputEvent.Kind) {
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
    private func stopForSecureInput(_ client: IMKTextInput) -> Bool {
        guard IsSecureEventInputEnabled() else { return false }
        PersonalHistoryCapture.shared.sensitiveInputBegan()
        GhostOutcomeLedger.markPrivacyExcluded()
        breakHistorySegment()
        dismiss(client)
        resetFallback()
        return true
    }

    private func recordOutcomeShown(_ client: IMKTextInput) {
        let field = fieldSnapshot(client)
        guard !Self.isOutcomeExcluded(bundleIdentifier: field.bundleIdentifier) else { return }
        let context = contextBeforeCaret(client, selection: field.selection)
        // The receipt travels with the presentation that produced this
        // `.shown`; a mismatch can only mean a ghost the reducer showed
        // without passing through `present`, which does not exist today,
        // so the fallback is labelled legacy rather than guessed at.
        let provenance = presentedProvenance.flatMap { presented in
            presented.ticket == state.visibleTicket ? presented.provenance : nil
        } ?? GhostProvenance(
            register: ContinuationRegister.from(bundleIdentifier: field.bundleIdentifier),
            source: .unknownLegacy
        )
        let answered = openOpportunity.flatMap { open in
            open.ticket == state.visibleTicket ? open : nil
        }
        if answered != nil { openOpportunity = nil }
        GhostOutcomeLedger.noteShown(
            opportunityID: answered?.id,
            sessionIdentifier: suggestionSessionIdentifier,
            register: provenance.register,
            source: provenance.source,
            candidateCharacters: state.visibleText.count,
            candidateWordCount: state.visibleText.split(whereSeparator: \Character.isWhitespace).count,
            precedingCharacter: context.last,
            excluded: false,
            receipt: provenance.receipt
        )
    }

    /// Whether a model request may go out from `context`, and the boundary
    /// the flight recorder will file it under — `nil` when the caret is not
    /// an eligible opportunity at all.
    ///
    /// Word and (when served) punctuation boundaries are the long-standing
    /// case. Mid-word is the new one: with `allowsMidWordContinuation` on, a
    /// caret inside a word the writer has typed at least
    /// `RawContinuationPrompt.minimumMidWordPartialLetters` letters of is
    /// also a request, and the opportunity it opens is recorded with boundary
    /// `mid-word` — `openOpportunity` below hands the ledger the same
    /// preceding character this reads, so the two cannot drift.
    static func opportunityBoundary(
        context: String,
        allowsPunctuation: Bool,
        allowsMidWordContinuation: Bool
    ) -> TextFreeCursorBoundary? {
        RawContinuationPrompt.requestBoundary(
            in: context,
            allowingPunctuation: allowsPunctuation,
            allowingMidWord: allowsMidWordContinuation
        )
    }

    /// An eligible opportunity: the caret sits where a request may start and
    /// a model request is about to go out. Opens exactly one pending record.
    private func openOpportunity(
        ticket: InlineSuggestionTicket,
        context: String,
        field: FieldSnapshot
    ) -> UUID? {
        endOpenOpportunity(.supersededByTyping, deadlineMissed: true)
        guard !Self.isOutcomeExcluded(bundleIdentifier: field.bundleIdentifier) else { return nil }
        let id = UUID()
        openOpportunity = (ticket, id)
        GhostOutcomeLedger.noteOpportunityOpened(
            id: id,
            sessionIdentifier: suggestionSessionIdentifier,
            hostRegister: ContinuationRegister.from(bundleIdentifier: field.bundleIdentifier),
            precedingCharacter: context.last,
            excluded: false
        )
        return id
    }

    /// Ends the open opportunity without a ghost. With `ticket`, only the
    /// opportunity for that request is ended; a stale caller is a no-op.
    /// Main thread only, like every other touch of controller state.
    private func endOpenOpportunity(
        _ reason: SuggestionDecisionReason,
        ticket: InlineSuggestionTicket? = nil,
        receipt: GhostDecisionReceipt? = nil,
        deadlineMissed: Bool = false
    ) {
        guard let open = openOpportunity, ticket == nil || open.ticket == ticket else { return }
        openOpportunity = nil
        GhostOutcomeLedger.noteOpportunityEnded(
            id: open.id,
            reason: reason,
            receipt: receipt,
            deadlineMissed: deadlineMissed
        )
    }

    static func isOutcomeExcluded(
        bundleIdentifier: String,
        secureInput: Bool = IsSecureEventInputEnabled()
    ) -> Bool {
        if secureInput { return true }
        let configured = Set(
            UserDefaults.standard.stringArray(
                forKey: PersonalHistorySettingsContract.excludedAppsKey
            ) ?? []
        )
        return DefaultExcludedApps.isExcluded(
            bundleIdentifier,
            configuredExcludedApps: configured
        )
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

    private func resetFallback() {
        typedFallback = ""
        fallbackOwner = nil
    }

    private func fallbackOwner(for client: IMKTextInput) -> FallbackOwner? {
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

    private func apply(_ effects: [InlineSuggestionState.Effect], to client: IMKTextInput) {
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
                recordOutcomeShown(client)
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

    private func dismiss(_ client: IMKTextInput) {
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
        chainedRequestRevision = scheduleRevision
    }

    /// True while the request a consumed accept chained is still pending.
    /// Any newer schedule (a keystroke, a dismissal) moves the revision on,
    /// so an ordinary Tab is never held.
    private func awaitingChainedGhost() -> Bool {
        guard Self.chainsAfterAccept,
              let chained = chainedRequestRevision,
              chained == scheduleRevision,
              state.pendingTicket != nil else { return false }
        return true
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
                secureInput: false
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
            characters: 1,
            sessionIdentifier: historySegmentIdentifier,
            permit: permit
        )
    }

    // MARK: - Tickets and context

    /// One read of the client's cursor and identity, shared by everything
    /// that needs it within a single synchronous turn.
    ///
    /// Every `selectedRange()` / `bundleIdentifier()` is a cross-process call
    /// into the app being typed into, made on the same main thread that has to
    /// service the next keystroke — and `contextBeforeCaret`,
    /// ticket construction and `trailingTextAfterCaret` each used to make
    /// those calls independently, so one `present()` paid for three
    /// `selectedRange()` round trips and `updateSuggestion` for four. The
    /// client cannot change underneath us mid-turn, so reading once is exactly
    /// equivalent and materially cheaper — most of all in Electron hosts,
    /// whose own main thread is often already busy.
    struct FieldSnapshot {
        let selection: NSRange
        let bundleIdentifier: String
    }

    private func fieldSnapshot(_ client: IMKTextInput) -> FieldSnapshot {
        // Secure Event Input first, before any read. The readers below checked
        // this before touching the client at all, and routing them through a
        // snapshot must not quietly invert that ordering: in a password field
        // Tilde reads nothing, not even the caret or the host identity.
        guard !IsSecureEventInputEnabled() else {
            return FieldSnapshot(selection: Self.unset, bundleIdentifier: "")
        }
        return FieldSnapshot(
            selection: client.selectedRange(),
            bundleIdentifier: client.bundleIdentifier() ?? ""
        )
    }

    private func ticket(context: String, field: FieldSnapshot) -> InlineSuggestionTicket {
        InlineSuggestionTicket(
            clientIdentifier: suggestionSessionIdentifier,
            bundleIdentifier: field.bundleIdentifier,
            contextFingerprint: InlineSuggestionTicket.fingerprint(context),
            selectionLocation: field.selection.location == NSNotFound ? -1 : field.selection.location,
            selectionLength: field.selection.length == NSNotFound ? -1 : field.selection.length,
            requestIdentifier: scheduleRevision
        )
    }

    /// Re-read the bounded context on acceptance so a same-range field change
    /// cannot commit a stale suggestion.
    private func matchingVisibleState(
        for client: IMKTextInput
    ) -> (ticket: InlineSuggestionTicket, context: String)? {
        guard let visible = state.visibleTicket else { return nil }
        let field = fieldSnapshot(client)
        let context = contextBeforeCaret(client, selection: field.selection)
        let current = ticket(context: context, field: field)
        return visible.matchesFieldState(of: current) ? (visible, context) : nil
    }

    private func contextBeforeCaret(_ client: IMKTextInput) -> String {
        guard !IsSecureEventInputEnabled() else { return "" }
        return contextBeforeCaret(client, selection: client.selectedRange())
    }

    /// Takes the caret alone, never a whole `FieldSnapshot`: this reader has no
    /// use for the bundle identifier, and making it demand one would add a
    /// cross-process call per keystroke rather than remove one.
    private func contextBeforeCaret(_ client: IMKTextInput, selection: NSRange) -> String {
        guard !IsSecureEventInputEnabled() else { return "" }
        guard selection.location != NSNotFound, selection.length == 0 else { return "" }
        if selection.location > 0 {
            // Quantized start: once the field is past the limit, a window
            // that slides one character per keystroke moves every byte of
            // the prompt behind the scaffold and defeats the helper's
            // prompt-cache reuse for the rest of the session. The window is
            // never longer than the limit and never more than one quantum
            // shorter.
            let start = RawContinuationPrompt.stableWindowStart(
                end: selection.location,
                limit: Self.contextLimit
            )
            let range = NSRange(location: start, length: selection.location - start)
            if let text = client.attributedSubstring(from: range)?.string, !text.isEmpty {
                return text
            }
        }
        return fallbackOwner(for: client) == fallbackOwner ? typedFallback : ""
    }

    private func trailingTextAfterCaret(_ client: IMKTextInput) -> String {
        guard !IsSecureEventInputEnabled() else { return "" }
        return trailingTextAfterCaret(client, selection: client.selectedRange())
    }

    private func trailingTextAfterCaret(_ client: IMKTextInput, selection: NSRange) -> String {
        guard !IsSecureEventInputEnabled() else { return "" }
        guard let range = Self.trailingContextRange(
            selection: selection,
            markedRange: client.markedRange(),
            documentLength: client.length()
        ) else {
            return ""
        }
        return client.attributedSubstring(from: range)?.string ?? ""
    }

    private func canAcceptSuggestion(in client: IMKTextInput) -> Bool {
        SuggestionActivationPolicy.isAtGrowingEdge(
            trailingTextAfterCaret: trailingTextAfterCaret(client)
        )
    }

    // MARK: - Suggestion paths

    private func scheduleSuggestion(
        for client: IMKTextInput,
        afterUserTyped grapheme: String,
        chained: Bool = false
    ) {
        // Same field, different conversation: tell Screen Memory so the
        // next capture happens now-ish instead of serving the old thread.
        let contextTail = String(contextBeforeCaret(client).suffix(Self.contextLimit))
        if ContextResetDetector.isReset(previous: lastScheduledContextTail, current: contextTail) {
            notifyScreenMemory(.contentReset)
        }
        lastScheduledContextTail = contextTail
        cancelPendingWork()
        scheduleRevision += 1
        let revision = scheduleRevision
        let expectedBundle = client.bundleIdentifier() ?? ""
        let timing = SuggestionRevealDelayPolicy.schedule(
            afterUserTyped: grapheme,
            calmMarkedText: usesCalmReveal(for: expectedBundle),
            chained: chained,
            calm: Self.calmRevealDelays
        )
        guard scheduleRevision == revision,
              (client.bundleIdentifier() ?? "") == expectedBundle else { return }
        let revealNotBefore = Date().addingTimeInterval(
            Double(timing.revealDelayNanoseconds) / 1_000_000_000
        )
        // Yield only until the key callback returns; there is no timing
        // sleep before inference. Only marked-text presentation waits for
        // the calm-caret window in Chromium/Electron editors. The one
        // exception is a chained request in such a host, which must let the
        // host commit the accepted text before the field is read at all.
        let settleBeforeReading = chained && usesCalmReveal(for: expectedBundle)
        Task { @MainActor [weak self] in
            if settleBeforeReading {
                try? await Task.sleep(nanoseconds: Self.chainedCalmSettleNanoseconds)
            }
            guard let self,
                  self.scheduleRevision == revision,
                  let liveClient = self.client(),
                  (liveClient.bundleIdentifier() ?? "") == expectedBundle else {
                if chained { Self.chainLogger.info("chain-bailed reason=superseded") }
                return
            }
            self.updateSuggestion(for: liveClient, revealNotBefore: revealNotBefore)
        }
    }

    /// Whether the current schedule is the one a consumed accept chained.
    private var isChainedSchedule: Bool {
        chainedRequestRevision == scheduleRevision
    }

    /// Whether `revision` is still the live schedule. A throttled request
    /// asks this after its wait: any keystroke, dismissal, or accept in the
    /// meantime has moved the revision on and already closed the opportunity.
    @MainActor
    private func isCurrentSchedule(_ revision: Int) -> Bool {
        scheduleRevision == revision
    }

    /// Chromium browsers and Electron apps render marked-text carets at the
    /// ghost's end. Their longer pause prevents visible caret ping-pong while
    /// keeping native editors on the near-instant path.
    private func usesCalmReveal(for bundleIdentifier: String) -> Bool {
        guard !bundleIdentifier.isEmpty else { return false }
        if let cached = calmRevealByBundle[bundleIdentifier] { return cached }
        let electronFramework = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .first?.bundleURL?
            .appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
        let electron = electronFramework.map {
            FileManager.default.fileExists(atPath: $0.path)
        } ?? false
        let calm = SuggestionRevealDelayPolicy.requiresCalmMarkedText(
            bundleIdentifier: bundleIdentifier,
            hasElectronFramework: electron
        )
        calmRevealByBundle[bundleIdentifier] = calm
        return calm
    }

    private func updateSuggestion(for client: IMKTextInput, revealNotBefore: Date) {
        guard !stopForSecureInput(client) else { return }
        let field = fieldSnapshot(client)
        let selection = field.selection
        guard selection.location != NSNotFound, selection.length == 0 else {
            if isChainedSchedule { Self.chainLogger.info("chain-bailed reason=selection") }
            breakHistorySegment()
            dismiss(client)
            resetFallback()
            return
        }
        let context = contextBeforeCaret(client, selection: field.selection)
        let trailingText = trailingTextAfterCaret(client, selection: field.selection)
        let requestTicket = ticket(context: context, field: field)
        // A model request is the unit the flight recorder explains. A
        // dictionary-only pass under the caret runs no model and is recorded
        // only when it shows something.
        let boundary = Self.opportunityBoundary(
            context: context,
            allowsPunctuation: Self.requestsAfterPunctuation,
            allowsMidWordContinuation: Self.requestsMidWordContinuation
        )
        // Word and punctuation boundaries open their record now, so a host
        // that cannot render still ends it with a reason. A mid-word request
        // waits out the throttle first: only the request that actually
        // leaves is an opportunity, not every letter on the way there.
        let opportunityID = boundary != nil && boundary != .midWord
            ? openOpportunity(ticket: requestTicket, context: context, field: field)
            : nil
        guard SuggestionActivationPolicy.allowsSuggestions(
            afterUserTyped: typedFallback,
            trailingTextAfterCaret: trailingText
        ) else {
            if isChainedSchedule {
                Self.chainLogger.info(
                    "chain-bailed reason=activation trailingChars=\(trailingText.count, privacy: .public)"
                )
            }
            endOpenOpportunity(.notAtGrowingEdge, ticket: requestTicket)
            dismiss(client)
            return
        }
        if isChainedSchedule {
            let tail = context.last.map { $0.isWhitespace ? "whitespace" : ($0.isLetter ? "letter" : "other") } ?? "empty"
            Self.chainLogger.info("chain-request tail=\(tail, privacy: .public)")
        }
        apply(state.reduce(.awaitSuggestion(requestTicket)), to: client)

        if context.last?.isLetter == true {
            let suffix = spellCheckerSuffix(for: context)
            // No model runs here, so the register is the host's own and
            // the source is the dictionary, never the base model's credit.
            let provenance = GhostProvenance(
                register: ContinuationRegister.from(bundleIdentifier: field.bundleIdentifier),
                source: .dictionary
            )
            Task { @MainActor [weak self] in
                self?.present(
                    suffix,
                    ticket: requestTicket,
                    revealNotBefore: revealNotBefore,
                    provenance: provenance
                )
            }
        }
        // Mid-word, the dictionary has had its say and the model may now
        // guess at the rest of the word. It cannot take anything back: the
        // reducer only ever grows a visible ghost, so an answer that does not
        // extend the dictionary's suffix is dropped rather than rewriting
        // what the writer is already reading.
        if let boundary {
            requestPhrase(
                bundleIdentifier: field.bundleIdentifier,
                context: context,
                field: field,
                ticket: requestTicket,
                revealNotBefore: revealNotBefore,
                boundary: boundary,
                opportunityID: opportunityID
            )
        }
    }

    /// The only synchronous predictor: one system completion lookup for a 3+
    /// letter partial word, run after the key callback has returned.
    private func spellCheckerSuffix(for context: String) -> String {
        let partial = RawContinuationPrompt.partialWord(in: context)
        guard partial.count >= RawContinuationPrompt.minimumMidWordPartialLetters else { return "" }
        let range = NSRange(location: 0, length: partial.utf16.count)
        let candidates = NSSpellChecker.shared.completions(
            forPartialWordRange: range,
            in: partial,
            language: "en",
            inSpellDocumentWithTag: 0
        ) ?? []
        return Self.dictionarySuffix(for: partial, candidates: candidates)
    }

    static func dictionarySuffix(for partial: String, candidates: [String]) -> String {
        guard partial.count >= RawContinuationPrompt.minimumMidWordPartialLetters else { return "" }
        let normalizedPartial = partial.lowercased()
        guard !candidates.contains(where: { $0.lowercased() == normalizedPartial }) else {
            return ""
        }
        guard let match = candidates.first(where: {
            $0.count > partial.count && $0.lowercased().hasPrefix(normalizedPartial)
        }) else { return "" }
        return String(match.dropFirst(partial.count))
    }

    /// The IME-to-app socket round trip, measured from this side.
    ///
    /// This was the one segment of the suggestion path with no timing
    /// anywhere — `script/latency_report.py`'s own docstring names it as the
    /// known gap. The app times from its side of the socket inward
    /// (`ghost-request-timing`), so the connect, the peer code-signature
    /// handshake, and the wire read on this side were invisible, and a
    /// regression in them could ship without tripping any budget.
    ///
    /// Cancelled requests are deliberately not recorded: the user typed past
    /// them, so their truncated durations would understate the real tail.
    ///
    /// Aggregate duration and a fixed outcome word only, never context and
    /// never a suggestion. `TranscriptedKeyboard` does not depend on the app target
    /// and so cannot reach `DiagnosticsLog`; this goes to the same OSLog
    /// subsystem `slow-key` already writes to. Read it with:
    /// `log show --predicate 'subsystem == "com.justinbetker.draft.inputmethod.Transcripted"'`
    private static func logRoundTrip(startedAt: TimeInterval, outcome: GhostBrainResponse.Outcome) {
        let elapsed = max(0, ProcessInfo.processInfo.systemUptime - startedAt)
        let milliseconds = Int((elapsed * 1_000).rounded())
        roundTripLogger.notice(
            "ghost-round-trip roundTripMilliseconds=\(milliseconds, privacy: .public) outcome=\(outcome.rawValue, privacy: .public)"
        )
    }

    /// One request to Tilde's app-owned model. A mid-word request waits out
    /// the served throttle first and opens its flight-recorder opportunity
    /// only if it survives the wait; the next keystroke moves the schedule
    /// on and the waiting request simply never leaves. Word and punctuation
    /// requests arrive with their opportunity already open.
    private func requestPhrase(
        bundleIdentifier: String,
        context: String,
        field: FieldSnapshot,
        ticket requestTicket: InlineSuggestionTicket,
        revealNotBefore: Date,
        boundary: TextFreeCursorBoundary,
        opportunityID openedOpportunityID: UUID?
    ) {
        let throttleNanoseconds = Self.requestThrottleNanoseconds(
            for: boundary,
            policy: ServedConfiguration.interaction
        )
        let tail = String(context.suffix(Self.contextLimit))
        let bundle = bundleIdentifier.isEmpty ? nil : bundleIdentifier
        let fieldSessionIdentifier = requestTicket.clientIdentifier
        // After punctuation the ghost carries its own separator: the brain
        // strips leading whitespace on the wire, so the keyboard puts the
        // space back before the marked text. Accepting inserts it, and a
        // typed space consumes it as ordinary type-through.
        let separator = context.last.map(RawContinuationPrompt.requestPunctuation.contains) == true ? " " : ""
        let revision = scheduleRevision
        modelTask = Task { [weak self] in
            var opportunityID = openedOpportunityID
            if throttleNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: throttleNanoseconds)
                guard !Task.isCancelled,
                      await self?.isCurrentSchedule(revision) == true else { return }
            }
            if opportunityID == nil, boundary == .midWord {
                // A keystroke can land between the throttle check and this
                // hop; re-check on the actor so a cancelled request never
                // opens a record nothing will close.
                opportunityID = await MainActor.run {
                    guard let self, !Task.isCancelled, self.isCurrentSchedule(revision) else { return nil }
                    return self.openOpportunity(ticket: requestTicket, context: context, field: field)
                }
                guard opportunityID != nil else { return }
            }
            let startedAt = ProcessInfo.processInfo.systemUptime
            let result = await GhostBrainClient.complete(
                context: tail,
                app: bundle,
                fieldSessionIdentifier: fieldSessionIdentifier,
                // The wire field stays; the H01 harness that filled it is not ported.
                experimentArm: nil,
                opportunityID: opportunityID?.uuidString,
                onPartial: { [weak self] partial in
                    // Called on the socket worker; the ticket check in
                    // `present` is what discards a partial that arrives late.
                    let provenance = GhostProvenance(receipt: partial, hostBundleIdentifier: bundleIdentifier)
                    Task { @MainActor [weak self] in
                        ServedConfiguration.adopt(partial)
                        self?.present(
                            separator + (partial.suggestion ?? ""),
                            ticket: requestTicket,
                            revealNotBefore: revealNotBefore,
                            provenance: provenance
                        )
                    }
                }
            )
            guard !Task.isCancelled else {
                // Superseded while in flight: the keystroke that cancelled us
                // may have run before this record existed, so close it here.
                await MainActor.run {
                    self?.endOpenOpportunity(.supersededByTyping, ticket: requestTicket, deadlineMissed: true)
                }
                return
            }
            Self.logRoundTrip(startedAt: startedAt, outcome: result.outcome)
            await MainActor.run { ServedConfiguration.adopt(result) }
            let receipt = GhostDecisionReceipt(result)
            switch result.outcome {
            case .suggestion:
                if let text = result.suggestion {
                    await self?.present(
                        separator + text,
                        ticket: requestTicket,
                        revealNotBefore: revealNotBefore,
                        provenance: GhostProvenance(receipt: result, hostBundleIdentifier: bundleIdentifier)
                    )
                } else {
                    await MainActor.run { self?.endOpenOpportunity(.emptyOutput, ticket: requestTicket, receipt: receipt) }
                    await self?.settle(ticket: requestTicket)
                }
            case .unavailable:
                await MainActor.run { self?.endOpenOpportunity(.runtimeUnavailable, ticket: requestTicket, receipt: receipt) }
                await self?.settle(ticket: requestTicket)
                Self.summonBrainIfNeeded()
            case .error, .timeout, .invalidRequest:
                await MainActor.run {
                    self?.endOpenOpportunity(
                        result.outcome == .timeout ? .timeout : .protocolError,
                        ticket: requestTicket,
                        receipt: receipt
                    )
                }
                await self?.settle(ticket: requestTicket)
                GhostStats.recordFailure(result.outcome)
            case .silence, .recorded:
                // The app's reason rides on the receipt; a pre-receipt app
                // leaves only "no suggestion".
                await MainActor.run { self?.endOpenOpportunity(.noSuggestion, ticket: requestTicket, receipt: receipt) }
                await self?.settle(ticket: requestTicket)
            }
        }
    }

    /// Shows a streamed or final suggestion for `requestTicket`. The reducer
    /// only ever grows the visible text, so a final that equals or trims the
    /// streamed prefix leaves the ghost exactly where the writer saw it.
    @MainActor
    private func present(
        _ text: String,
        ticket requestTicket: InlineSuggestionTicket,
        revealNotBefore: Date = .distantPast,
        provenance: GhostProvenance
    ) {
        guard let liveClient = client() else { return }
        guard !stopForSecureInput(liveClient) else { return }
        let field = fieldSnapshot(liveClient)
        let currentContext = contextBeforeCaret(liveClient, selection: field.selection)
        guard ticket(context: currentContext, field: field) == requestTicket else {
            // The answer exists but the writer moved on before it could be
            // shown: generated, and too late.
            endOpenOpportunity(
                .supersededByTyping,
                ticket: requestTicket,
                receipt: provenance.receipt,
                deadlineMissed: true
            )
            apply(state.reduce(.dismissTicket(requestTicket)), to: liveClient)
            return
        }
        guard SuggestionActivationPolicy.isAtGrowingEdge(
            trailingTextAfterCaret: trailingTextAfterCaret(liveClient, selection: field.selection)
        ) else {
            endOpenOpportunity(.notAtGrowingEdge, ticket: requestTicket, receipt: provenance.receipt)
            dismiss(liveClient)
            return
        }
        if Date() < revealNotBefore {
            bufferReveal(text, ticket: requestTicket, until: revealNotBefore, provenance: provenance)
            return
        }
        if bufferedReveal?.ticket == requestTicket { bufferedReveal = nil }
        presentedProvenance = (requestTicket, provenance)
        let wasVisible = state.isVisible && state.visibleTicket == requestTicket
        let effects = state.reduce(.update(text, requestTicket))
        apply(effects, to: liveClient)
        guard state.visibleTicket == requestTicket else { return }
        if wasVisible {
            // A ghost was already on screen for this ticket (the dictionary,
            // or an earlier partial). The model either grew it — one ghost,
            // one record, now credited to the model — or added nothing.
            let grew = effects.contains { if case .show = $0 { return true } else { return false } }
            if grew {
                let answered = openOpportunity.flatMap { $0.ticket == requestTicket ? $0 : nil }
                if answered != nil { openOpportunity = nil }
                GhostOutcomeLedger.noteModelExtendedVisibleCandidate(
                    opportunityID: answered?.id,
                    receipt: provenance.receipt
                )
            } else if provenance.source != .dictionary {
                endOpenOpportunity(.behindVisibleGhost, ticket: requestTicket, receipt: provenance.receipt)
            }
        }
        // The terminal line's timings fill in a record the model opened (or
        // took over); a rejected model answer never lends its timings to a
        // dictionary ghost.
        if provenance.source != .dictionary, let receipt = provenance.receipt {
            GhostOutcomeLedger.noteReceipt(receipt)
        }
    }

    @MainActor
    private func bufferReveal(
        _ text: String,
        ticket: InlineSuggestionTicket,
        until deadline: Date,
        provenance: GhostProvenance
    ) {
        guard !text.isEmpty else { return }
        if let bufferedReveal, bufferedReveal.ticket == ticket {
            guard text.count > bufferedReveal.text.count,
                  text.hasPrefix(bufferedReveal.text) else { return }
        }
        bufferedReveal = (text, ticket, provenance)
        revealTask?.cancel()
        let nanoseconds = UInt64(max(0, deadline.timeIntervalSinceNow) * 1_000_000_000)
        revealTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled,
                  let self,
                  let buffered = self.bufferedReveal,
                  buffered.ticket == ticket else { return }
            self.bufferedReveal = nil
            self.present(buffered.text, ticket: buffered.ticket, provenance: buffered.provenance)
        }
    }

    /// The request ended without a longer suggestion. A partial that is
    /// already visible stays — it passed the same cleaner — and silence and
    /// retraction are both worse than a shorter word-boundary ghost. Only a
    /// still-pending ticket is released.
    @MainActor
    private func settle(ticket requestTicket: InlineSuggestionTicket) {
        guard state.visibleTicket != requestTicket, let liveClient = client() else { return }
        apply(state.reduce(.dismissTicket(requestTicket)), to: liveClient)
    }

    private func cancelPendingWork() {
        endOpenOpportunity(.supersededByTyping, deadlineMissed: true)
        scheduleRevision += 1
        revealTask?.cancel()
        revealTask = nil
        bufferedReveal = nil
        modelTask?.cancel()
        modelTask = nil
    }

    private func breakHistorySegment() {
        historySegmentIdentifier = UUID().uuidString
        historyOwner = nil
        historyDeletions.reset()
    }

    private func invalidateHistoryContinuity() {
        if historyOwner != nil { breakHistorySegment() }
    }

    /// Tracks only known app/caret boundaries. IMKit cannot distinguish two
    /// same-app fields at the same caret without broader system permissions.
    private func prepareHistoryInsertion(
        _ text: String,
        observation: InsertionObservation
    ) -> Bool {
        let selection = observation.selection
        guard selection.location != NSNotFound else {
            breakHistorySegment()
            return false
        }
        let current = FallbackOwner(bundle: observation.bundle, caret: selection.location)
        if selection.length != 0 || (historyOwner != nil && historyOwner != current) {
            breakHistorySegment()
        }
        historyOwner = FallbackOwner(
            bundle: current.bundle,
            caret: current.caret + text.utf16.count
        )
        return true
    }

    // MARK: - App watchdog

    private static var lastBrainSummon = Date.distantPast

    private static func summonBrainIfNeeded() {
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
