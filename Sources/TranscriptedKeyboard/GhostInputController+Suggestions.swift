#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif
import Cocoa
import InputMethodKit
import OSLog

extension GhostInputController {
    // MARK: - Suggestion paths

    func scheduleSuggestion(
        for client: IMKTextInput,
        afterUserTyped grapheme: String,
        chained: Bool = false
    ) {
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
        guard scheduleRevision == revision else { return }
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
            self?.chainedTabHold.taskStarted(revision: revision)
            guard let self,
                  self.scheduleRevision == revision,
                  let liveClient = self.client(),
                  (liveClient.bundleIdentifier() ?? "") == expectedBundle else {
                if chained { Self.chainLogger.info("chain-bailed reason=superseded") }
                return
            }
            self.updateSuggestion(for: liveClient, bundleIdentifier: expectedBundle, revealNotBefore: revealNotBefore)
        }
    }

    /// Whether the current schedule is the one a consumed accept chained.
    private var isChainedSchedule: Bool {
        chainedTabHold.chainedRevision == scheduleRevision
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
    func usesCalmReveal(for bundleIdentifier: String) -> Bool {
        GhostCalmRevealCache.shared.usesCalmReveal(for: bundleIdentifier)
    }

    /// `bundleIdentifier` was just checked against the live client by the caller's Task.
    private func updateSuggestion(for client: IMKTextInput, bundleIdentifier: String, revealNotBefore: Date) {
        guard !stopForSecureInput(client) else { _ = contextTailSampler.record(nil); return }
        let field = IsSecureEventInputEnabled()
            ? FieldSnapshot(selection: Self.unset, bundleIdentifier: "")
            : FieldSnapshot(selection: client.selectedRange(), bundleIdentifier: bundleIdentifier)
        let selection = field.selection
        guard selection.location != NSNotFound, selection.length == 0 else {
            _ = contextTailSampler.record(nil)
            if isChainedSchedule { Self.chainLogger.info("chain-bailed reason=selection") }
            breakHistorySegment()
            dismiss(client)
            resetFallback()
            return
        }
        let hostText = hostContextBeforeCaret(client, selection: selection)
        // Same field, different conversation: tell Screen Memory so the next
        // capture happens now-ish instead of serving the old thread.
        if contextTailSampler.record(hostText) { notifyScreenMemory(.contentReset) }
        let context = contextBeforeCaret(client, hostText: hostText)
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
            case .error, .timeout, .invalidRequest, .unsupported:
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
        apply(effects, to: liveClient, shown: (field.bundleIdentifier, currentContext.last))
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

    func cancelPendingWork() {
        endOpenOpportunity(.supersededByTyping, deadlineMissed: true)
        scheduleRevision += 1
        revealTask?.cancel()
        revealTask = nil
        bufferedReveal = nil
        modelTask?.cancel()
        modelTask = nil
    }

    func breakHistorySegment() {
        historySegmentIdentifier = UUID().uuidString
        historyOwner = nil
        historyDeletions.reset()
    }

    func invalidateHistoryContinuity() {
        if historyOwner != nil { breakHistorySegment() }
    }

    /// Tracks only known app/caret boundaries. IMKit cannot distinguish two
    /// same-app fields at the same caret without broader system permissions.
    func prepareHistoryInsertion(
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
}
