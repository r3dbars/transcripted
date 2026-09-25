import Testing
@testable import TranscriptedWritingCore

@Suite("Inline suggestion state")
struct InlineSuggestionStateTests {
    @Test("Stale client, bundle, context, and range tickets cannot present")
    func stalePresentationIsRejected() {
        let expected = ticket()
        let staleTickets = [
            ticket(client: "other"),
            ticket(bundle: "other.app"),
            ticket(context: "different"),
            ticket(location: 8),
            ticket(length: 2),
        ]

        for stale in staleTickets {
            var state = InlineSuggestionState()
            #expect(state.reduce(.awaitSuggestion(expected)).isEmpty)
            #expect(state.reduce(.present(" world", stale)).isEmpty)
            #expect(!state.isVisible)
        }
    }

    @Test("A streamed update may extend only the same live ticket")
    func streamedUpdateRequiresCurrentTicket() {
        let current = ticket(request: 4)
        let stale = ticket(request: 3)
        var state = InlineSuggestionState()
        _ = state.reduce(.awaitSuggestion(current))

        #expect(state.reduce(.update(" world", stale)).isEmpty)
        #expect(!state.isVisible)
        #expect(state.reduce(.update(" world", current)) == [
            .shown, .show(" world"),
        ])
        #expect(state.reduce(.update(" world again", current)) == [
            .show(" world again"),
        ])
        #expect(state.reduce(.update(" world", current)).isEmpty)
        #expect(state.reduce(.update(" rewritten", current)).isEmpty)
        #expect(state.reduce(.update(" world again", current)).isEmpty)
        #expect(state.visibleText == " world again")
    }

    /// Mid-word puts two predictors on one ticket for the first time: the
    /// system dictionary answers immediately and the model answers later,
    /// into the same request. The grow-only rule is what makes that safe —
    /// the writer is already reading the dictionary's suffix, and a model
    /// answer may only ever add to it.
    @Test("A mid-word model answer may extend a visible dictionary ghost, never rewrite it")
    func modelMayOnlyGrowADictionaryGhost() {
        let request = ticket(request: 7)
        var state = InlineSuggestionState()
        _ = state.reduce(.awaitSuggestion(request))

        // The dictionary's completion of "writ" lands first.
        #expect(state.reduce(.update("ing", request)) == [.shown, .show("ing")])

        // A model answer that extends it grows the same ghost, with no second
        // impression and no hide/show flicker.
        #expect(state.reduce(.update("ing the report", request)) == [.show("ing the report")])
        #expect(state.visibleText == "ing the report")

        // A model answer that disagrees with what is on screen is dropped:
        // "ten" would have retracted the writer's "ing" and re-marked a
        // different word under their caret.
        #expect(state.reduce(.update("ten a draft", request)).isEmpty)
        #expect(state.reduce(.update("ing", request)).isEmpty)
        #expect(state.visibleText == "ing the report")
    }

    @Test("With no dictionary suffix the mid-word model answer is the first thing shown")
    func modelAnswersAloneWhenTheDictionaryHasNothing() {
        let request = ticket(request: 7)
        var state = InlineSuggestionState()
        _ = state.reduce(.awaitSuggestion(request))

        // An empty dictionary suffix leaves the request pending, not resolved.
        #expect(state.reduce(.update("", request)).isEmpty)
        #expect(!state.isVisible)
        #expect(state.pendingTicket == request)

        #expect(state.reduce(.update("ting the report", request)) == [
            .shown, .show("ting the report"),
        ])
        #expect(state.visibleText == "ting the report")
    }

    @Test("A newer request rejects an older result for the same field state")
    func requestOrderRejectsLateResult() {
        let older = ticket(request: 1)
        let newer = ticket(request: 2)
        var state = InlineSuggestionState()
        _ = state.reduce(.awaitSuggestion(older))
        _ = state.reduce(.awaitSuggestion(newer))

        #expect(state.reduce(.present(" old", older)).isEmpty)
        #expect(state.reduce(.present(" new", newer)) == [.shown, .show(" new")])
    }

    @Test("Replacement and dismissal clear every older suggestion")
    func replacementAndDismissalClearState() {
        let first = ticket(request: 1)
        let second = ticket(request: 2)
        var state = InlineSuggestionState()
        _ = state.reduce(.awaitSuggestion(first))
        _ = state.reduce(.present(" first", first))

        #expect(state.reduce(.awaitSuggestion(second)) == [.hide])
        #expect(state.reduce(.present(" late", first)).isEmpty)
        #expect(state.pendingTicket == second)
        #expect(state.reduce(.dismiss).isEmpty)
        #expect(state.pendingTicket == nil)
        #expect(state.reduce(.present(" later", second)).isEmpty)
        #expect(!state.isVisible)
    }

    @Test("Matching type-through hides, inserts, and re-marks without scheduling")
    func matchingTypeThroughConsumesOneGrapheme() {
        let current = ticket(context: "caf", location: 3)
        let advanced = current.advancing(with: "é", boundedContext: "caf", utf16Limit: 3_000)
        var state = InlineSuggestionState()
        _ = state.reduce(.awaitSuggestion(current))
        _ = state.reduce(.present("é noir", current))

        #expect(state.reduce(.type("é", current: current, advanced: advanced)) == [
            .hide, .insert("é"), .show(" noir"),
        ])
        #expect(state.visibleTicket == advanced)
        #expect(state.pendingTicket == nil)
    }

    @Test("Multiple type-through characters keep the visible request valid for Tab")
    func multipleTypeThroughCharactersThenAccept() {
        let original = ticket(context: "h", location: 1, request: 7)
        var state = InlineSuggestionState()
        _ = state.reduce(.awaitSuggestion(original))
        _ = state.reduce(.present("ello", original))

        let afterE = original.advancing(with: "e", boundedContext: "h", utf16Limit: 3_000)
        #expect(state.reduce(.type("e", current: original, advanced: afterE)) == [
            .hide, .insert("e"), .show("llo"),
        ])

        // Scheduling revisions may advance while the visible request remains 7.
        let liveAfterE = ticket(context: "he", location: 2, request: 99)
        let matchedAfterE = state.visibleTicket.flatMap {
            $0.matchesFieldState(of: liveAfterE) ? $0 : nil
        }
        let afterL = matchedAfterE?.advancing(
            with: "l",
            boundedContext: "he",
            utf16Limit: 3_000
        )
        #expect(state.reduce(.type("l", current: matchedAfterE, advanced: afterL)) == [
            .hide, .insert("l"), .show("lo"),
        ])

        let liveAfterL = ticket(context: "hel", location: 3, request: 100)
        let matchedForTab = state.visibleTicket.flatMap {
            $0.matchesFieldState(of: liveAfterL) ? $0 : nil
        }
        #expect(state.reduce(.acceptNextWord(
            current: matchedForTab,
            boundedContext: "hel",
            utf16Limit: 3_000
        )) == [.hide, .insert("lo "), .accepted])
    }

    @Test("Divergence hides, inserts, then schedules a new request")
    func divergenceEffectOrder() {
        let current = ticket()
        var state = InlineSuggestionState()
        _ = state.reduce(.awaitSuggestion(current))
        _ = state.reduce(.present(" world", current))

        let advanced = current.advancing(
            with: "!",
            boundedContext: "hello",
            utf16Limit: 3_000
        )
        #expect(state.reduce(.type("!", current: current, advanced: advanced)) == [
            .hide, .insert("!"), .schedule(afterTyping: "!"),
        ])
    }

    @Test("Bounded context rollover keeps type-through valid for Tab")
    func boundedContextRollover() {
        let context = String(repeating: "a", count: 3_000)
        let current = ticket(context: context, location: 3_000, request: 7)
        let rolledContext = String((context + "b").suffix(3_000))
        let advanced = current.advancing(
            with: "b",
            boundedContext: context,
            utf16Limit: 3_000
        )
        let live = ticket(context: rolledContext, location: 3_001, request: 99)
        var state = InlineSuggestionState()
        _ = state.reduce(.awaitSuggestion(current))
        _ = state.reduce(.present("bc", current))

        #expect(state.reduce(.type("b", current: current, advanced: advanced)) == [
            .hide, .insert("b"), .show("c"),
        ])
        let matchedForTab = state.visibleTicket.flatMap {
            $0.matchesFieldState(of: live) ? $0 : nil
        }
        #expect(state.reduce(.acceptNextWord(
            current: matchedForTab,
            boundedContext: rolledContext,
            utf16Limit: 3_000
        )) == [.hide, .insert("c "), .accepted])
    }

    @Test("Non-BMP fallback shares the ticket's UTF-16 context window")
    func nonBMPFallbackRollover() {
        var fallback = InlineSuggestionTicket.boundedContext(
            String(repeating: "😀", count: 1_500),
            utf16Limit: 3_000
        )
        let current = ticket(context: fallback, location: 3_000, request: 8)
        let advanced = current.advancing(
            with: "b",
            boundedContext: fallback,
            utf16Limit: 3_000
        )
        fallback = InlineSuggestionTicket.boundedContext(fallback + "b", utf16Limit: 3_000)
        let live = ticket(context: fallback, location: 3_001, request: 101)
        var state = InlineSuggestionState()
        _ = state.reduce(.awaitSuggestion(current))
        _ = state.reduce(.present("bc", current))

        #expect(state.reduce(.type("b", current: current, advanced: advanced)) == [
            .hide, .insert("b"), .show("c"),
        ])
        let matchedForTab = state.visibleTicket.flatMap {
            $0.matchesFieldState(of: live) ? $0 : nil
        }
        #expect(state.reduce(.acceptNextWord(
            current: matchedForTab,
            boundedContext: fallback,
            utf16Limit: 3_000
        )) == [.hide, .insert("c "), .accepted])
    }

    @Test("Tab advances through a suggestion one word at a time")
    func repeatedTabAcceptsWords() {
        let current = ticket(context: "hello", location: 5, request: 7)
        var state = InlineSuggestionState()
        _ = state.reduce(.awaitSuggestion(current))
        _ = state.reduce(.present(" world and beyond", current))

        #expect(state.reduce(.acceptNextWord(
            current: current,
            boundedContext: "hello",
            utf16Limit: 3_000
        )) == [.hide, .insert(" world "), .show("and beyond"), .accepted])

        let afterWorld = current.advancing(
            with: " world ",
            boundedContext: "hello",
            utf16Limit: 3_000
        )
        #expect(state.visibleTicket == afterWorld)
        #expect(state.reduce(.acceptNextWord(
            current: afterWorld,
            boundedContext: "hello world ",
            utf16Limit: 3_000
        )) == [.hide, .insert("and "), .show("beyond")])

        let afterAnd = afterWorld.advancing(
            with: "and ",
            boundedContext: "hello world ",
            utf16Limit: 3_000
        )
        #expect(state.reduce(.acceptNextWord(
            current: afterAnd,
            boundedContext: "hello world and ",
            utf16Limit: 3_000
        )) == [.hide, .insert("beyond ")])
        #expect(!state.isVisible)
    }

    @Test("Tab accepts only a current suggestion")
    func acceptanceRequiresCurrentTicket() {
        let current = ticket()
        var stale = InlineSuggestionState()
        _ = stale.reduce(.awaitSuggestion(current))
        _ = stale.reduce(.present(" world", current))
        #expect(stale.reduce(.acceptNextWord(
            current: ticket(location: 99),
            boundedContext: "hello",
            utf16Limit: 3_000
        )) == [.hide])

        var live = InlineSuggestionState()
        _ = live.reduce(.awaitSuggestion(current))
        _ = live.reduce(.present(" world", current))
        #expect(live.reduce(.acceptNextWord(
            current: current,
            boundedContext: "hello",
            utf16Limit: 3_000
        )) == [.hide, .insert(" world "), .accepted])
    }

    @Test("Full accept inserts the whole current suggestion and dismisses it")
    func fullAcceptance() {
        let current = ticket(context: "hello", location: 5, request: 7)
        var state = InlineSuggestionState()
        _ = state.reduce(.awaitSuggestion(current))
        _ = state.reduce(.present(" world and beyond", current))

        #expect(state.reduce(.acceptAll(current: current)) == [
            .hide, .insert(" world and beyond"), .accepted,
        ])
        #expect(!state.isVisible)
        #expect(state.visibleTicket == nil)
    }

    @Test("Full accept can move the following separator into the inserted text, like a word accept")
    func fullAcceptAppendsSeparatorWhenAsked() {
        let current = ticket(context: "hello ", location: 6, request: 3)
        var state = InlineSuggestionState()
        _ = state.reduce(.awaitSuggestion(current))
        _ = state.reduce(.present("see you tomorrow", current))
        let effects = state.reduce(.acceptAll(current: current, appendsSeparator: true))
        #expect(effects == [.hide, .insert("see you tomorrow "), .accepted])
        #expect(!state.isVisible)

        // A ghost that already ends in whitespace is not doubled.
        var again = InlineSuggestionState()
        _ = again.reduce(.awaitSuggestion(current))
        _ = again.reduce(.present("see you ", current))
        #expect(again.reduce(.acceptAll(current: current, appendsSeparator: true))
            == [.hide, .insert("see you "), .accepted])
    }

    @Test("Full accept rejects a stale suggestion")
    func fullAcceptanceRequiresCurrentTicket() {
        let current = ticket(context: "hello", location: 5, request: 7)
        var state = InlineSuggestionState()
        _ = state.reduce(.awaitSuggestion(current))
        _ = state.reduce(.present(" world and beyond", current))

        #expect(state.reduce(.acceptAll(current: ticket(location: 99))) == [.hide])
        #expect(!state.isVisible)
    }

    @Test("Shown counts only fresh presentations; accepted counts only the first accept")
    func presentationCountingSemantics() {
        let current = ticket(context: "hello", location: 5, request: 1)
        var state = InlineSuggestionState()
        _ = state.reduce(.awaitSuggestion(current))

        // A fresh presentation is shown.
        #expect(state.reduce(.present(" world and beyond", current)) == [
            .shown, .show(" world and beyond"),
        ])

        // A matching keystroke consumes a character without re-recording shown.
        let advanced = current.advancing(with: " ", boundedContext: "hello", utf16Limit: 3_000)
        #expect(state.reduce(.type(" ", current: current, advanced: advanced)) == [
            .hide, .insert(" "), .show("world and beyond"),
        ])

        // The first Tab-walk accept of this presentation is recorded once...
        #expect(state.reduce(.acceptNextWord(
            current: advanced,
            boundedContext: "hello ",
            utf16Limit: 3_000
        )) == [.hide, .insert("world "), .show("and beyond"), .accepted])

        let afterWorld = advanced.advancing(with: "world ", boundedContext: "hello ", utf16Limit: 3_000)
        // ...and a later Tab-walk accept of the same presentation is not.
        #expect(state.reduce(.acceptNextWord(
            current: afterWorld,
            boundedContext: "hello world ",
            utf16Limit: 3_000
        )) == [.hide, .insert("and "), .show("beyond")])

        // A brand-new presentation is a fresh shown, and its first accept
        // records again.
        let next = ticket(context: "hello world and beyond", location: 23, request: 2)
        _ = state.reduce(.awaitSuggestion(next))
        #expect(state.reduce(.present(" next", next)) == [.shown, .show(" next")])
        #expect(state.reduce(.acceptNextWord(
            current: next,
            boundedContext: "hello world and beyond",
            utf16Limit: 3_000
        )) == [.hide, .insert(" next "), .accepted])
    }

    @Test("Typing immediately after a word accept uses the inserted space")
    func fastTypingAfterWordAcceptance() {
        let current = ticket(context: "hello", location: 5, request: 7)
        var state = InlineSuggestionState()
        _ = state.reduce(.awaitSuggestion(current))
        _ = state.reduce(.present(" world again", current))

        #expect(state.reduce(.acceptNextWord(
            current: current,
            boundedContext: "hello",
            utf16Limit: 3_000
        )) == [.hide, .insert(" world "), .show("again"), .accepted])

        let afterAccept = current.advancing(
            with: " world ",
            boundedContext: "hello",
            utf16Limit: 3_000
        )
        let afterTyping = afterAccept.advancing(
            with: "a",
            boundedContext: "hello world ",
            utf16Limit: 3_000
        )
        #expect(state.reduce(.type(
            "a",
            current: afterAccept,
            advanced: afterTyping
        )) == [.hide, .insert("a"), .show("gain")])
    }

    @Test("A stale callback cannot dismiss a newer request")
    func targetedDismissPreservesNewerRequest() {
        let old = ticket(request: 1)
        let newer = ticket(context: "hello ", location: 6, request: 2)
        var state = InlineSuggestionState()
        _ = state.reduce(.awaitSuggestion(old))
        _ = state.reduce(.present(" world", old))
        _ = state.reduce(.awaitSuggestion(newer))

        #expect(state.reduce(.dismissTicket(old)).isEmpty)
        #expect(state.pendingTicket == newer)
        #expect(!state.isVisible)
    }

    private func ticket(
        client: String = "client-1",
        bundle: String = "com.example.editor",
        context: String = "hello",
        location: Int = 5,
        length: Int = 0,
        request: Int = 0
    ) -> InlineSuggestionTicket {
        InlineSuggestionTicket(
            clientIdentifier: client,
            bundleIdentifier: bundle,
            contextFingerprint: InlineSuggestionTicket.fingerprint(context),
            selectionLocation: location,
            selectionLength: length,
            requestIdentifier: request
        )
    }
}
