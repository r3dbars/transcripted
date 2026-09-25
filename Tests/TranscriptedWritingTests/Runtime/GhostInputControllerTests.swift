import AppKit
import Testing
@testable import TranscriptedKeyboard
@testable import TranscriptedWritingCore

@Suite("Ghost input controller")
struct GhostInputControllerTests {
    @Test("The backtick/tilde key accepts all while modified chords remain printable")
    func tildeFullAcceptShortcut() {
        #expect(GhostInputController.shouldAcceptWholeSuggestion(
            keyCode: 50,
            modifiers: [.shift]
        ))
        #expect(GhostInputController.shouldAcceptWholeSuggestion(
            keyCode: 50,
            modifiers: []
        ))
        #expect(GhostInputController.shouldAcceptWholeSuggestion(
            keyCode: 50,
            modifiers: [.capsLock]
        ))
        #expect(!GhostInputController.shouldAcceptWholeSuggestion(
            keyCode: 50,
            modifiers: [.shift, .command]
        ))
        #expect(!GhostInputController.shouldAcceptWholeSuggestion(
            keyCode: 48,
            modifiers: [.shift]
        ))
    }

    @Test("Slow-key timing separates queue delay from handler work")
    func slowKeyTiming() throws {
        let timing = try #require(GhostInputController.slowKeyTiming(
            eventTimestamp: 10,
            handlerStartedAt: 10.060,
            handlerFinishedAt: 10.080
        ))
        #expect(timing.totalMilliseconds == 80)
        #expect(timing.queuedMilliseconds == 60)
        #expect(timing.handlerMilliseconds == 20)
        #expect(GhostInputController.slowKeyTiming(
            eventTimestamp: 10,
            handlerStartedAt: 10.020,
            handlerFinishedAt: 10.049
        ) == nil)
    }

    @Test("Complete words do not grow into longer completions")
    func completeWordsStayComplete() {
        #expect(GhostInputController.dictionarySuffix(
            for: "the",
            candidates: ["the", "they", "there"]
        ).isEmpty)
        #expect(GhostInputController.dictionarySuffix(
            for: "AND",
            candidates: ["and", "android"]
        ).isEmpty)
    }

    @Test("Unfinished words keep a useful suffix")
    func unfinishedWordsComplete() {
        #expect(GhostInputController.dictionarySuffix(
            for: "inst",
            candidates: ["instant", "instead"]
        ) == "ant")
    }

    @Test("Trailing context reads are bounded and require a caret")
    func trailingContextRangeIsSafe() {
        #expect(GhostInputController.trailingContextRange(
            selection: NSRange(location: 20, length: 0),
            markedRange: NSRange(location: NSNotFound, length: 0),
            documentLength: 150
        ) == NSRange(location: 20, length: 80))
        #expect(GhostInputController.trailingContextRange(
            selection: NSRange(location: 20, length: 0),
            markedRange: NSRange(location: NSNotFound, length: 0),
            documentLength: 25
        ) == NSRange(location: 20, length: 5))
        #expect(GhostInputController.trailingContextRange(
            selection: NSRange(location: 20, length: 0),
            markedRange: NSRange(location: 20, length: 8),
            documentLength: 35
        ) == NSRange(location: 28, length: 7))
        #expect(GhostInputController.trailingContextRange(
            selection: NSRange(location: 25, length: 0),
            markedRange: NSRange(location: NSNotFound, length: 0),
            documentLength: 25
        ) == nil)
        #expect(GhostInputController.trailingContextRange(
            selection: NSRange(location: 20, length: 3),
            markedRange: NSRange(location: NSNotFound, length: 0),
            documentLength: 25
        ) == nil)
    }

    @Test("Password managers stay excluded from the outcome watch")
    func passwordManagersAreExcluded() {
        #expect(
            GhostInputController.isOutcomeExcluded(
                bundleIdentifier: "com.1password.1password",
                secureInput: false
            )
        )
        #expect(
            !GhostInputController.isOutcomeExcluded(
                bundleIdentifier: "com.apple.mail",
                secureInput: false
            )
        )
        #expect(
            GhostInputController.isOutcomeExcluded(
                bundleIdentifier: "com.apple.mail",
                secureInput: true
            )
        )
    }
}

/// Where a request may start, and what the flight recorder files it under.
/// The fifth rule of the live ledger: an opportunity is a model request, and
/// every eligible one ends with exactly one terminal reason.
@Suite("Request opportunities")
struct GhostInputControllerOpportunityTests {
    private func boundary(
        _ context: String,
        punctuation: Bool = false,
        midWord: Bool = false
    ) -> TextFreeCursorBoundary? {
        GhostInputController.opportunityBoundary(
            context: context,
            allowsPunctuation: punctuation,
            allowsMidWordContinuation: midWord
        )
    }

    @Test("Production asks only at word boundaries")
    func productionAsksAtWordBoundaries() {
        #expect(boundary("see you ") == .wordBoundary)
        #expect(boundary("that works. ") == .wordBoundary)
        // A letter under the caret is the dictionary's business alone: no
        // model request, so no opportunity to explain.
        #expect(boundary("I am wri") == nil)
        #expect(boundary("one thing,") == nil)
        #expect(boundary("") == nil)
    }

    @Test("A mid-word request is an eligible opportunity, recorded as mid-word")
    func midWordIsAnEligibleOpportunity() {
        #expect(boundary("I am wri", midWord: true) == .midWord)
        // The character before the caret is what the ledger files the
        // opportunity under (`TextFreeCursorBoundary.from`), so the two
        // cannot drift apart.
        #expect(TextFreeCursorBoundary.from(precedingCharacter: "I am wri".last) == .midWord)
    }

    @Test("Mid-word keeps the dictionary's floor and does not fire on a pasted blob")
    func midWordKeepsTheSharedBounds() {
        // Two letters is what the system dictionary already refuses to
        // complete; the model is not asked earlier than that.
        #expect(boundary("since we", midWord: true) == nil)
        #expect(GhostInputController.dictionarySuffix(
            for: "we",
            candidates: ["week", "went"]
        ).isEmpty)
        #expect(boundary("key \(String(repeating: "a", count: 64))", midWord: true) == nil)
    }

    @Test("Only the mid-word path is throttled, and by more than a fast typist's keystroke")
    func onlyMidWordIsThrottled() {
        let tuned = InteractionPolicy.tuned9B
        #expect(GhostInputController.requestThrottleNanoseconds(for: .wordBoundary, policy: tuned) == 0)
        #expect(GhostInputController.requestThrottleNanoseconds(for: .sentenceBoundary, policy: tuned) == 0)
        #expect(GhostInputController.requestThrottleNanoseconds(for: nil, policy: tuned) == 0)
        // Production does not ask mid-word at all, so its throttle is moot and zero.
        #expect(GhostInputController.requestThrottleNanoseconds(for: .midWord, policy: .conservative) == 0)
        let throttle = GhostInputController.requestThrottleNanoseconds(for: .midWord, policy: tuned)
        // A fast typist lands roughly ten characters a second. The wait has
        // to outlast that gap, or a burst still spends one request a letter.
        #expect(throttle >= 100_000_000)
        // And stay short enough that a pause still gets an answer promptly.
        #expect(throttle <= 250_000_000)
    }

    @Test("The two permissions are independent doors")
    func permissionsAreIndependent() {
        #expect(boundary("one thing,", punctuation: true) == .wordBoundary)
        #expect(boundary("that works.", punctuation: true) == .sentenceBoundary)
        #expect(boundary("one thing,", midWord: true) == nil)
        #expect(boundary("I am wri", punctuation: true) == nil)
        // Both on: each still answers only for its own caret.
        #expect(boundary("I am wri", punctuation: true, midWord: true) == .midWord)
        #expect(boundary("one thing,", punctuation: true, midWord: true) == .wordBoundary)
        #expect(boundary("see you ", punctuation: true, midWord: true) == .wordBoundary)
    }
}
