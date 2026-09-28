import Foundation
import Testing
@testable import TranscriptedWritingCore

@Suite("Retained span watch and local diary")
struct RetainedSpanWatchTests {
    @Test("Tab-and-keep counts the whole public span; rewrite counts less")
    func keepAndRewriteLookDifferent() throws {
        let accepted = "alpha beta"
        let kept = RetainedSpanWatch.retainedCharacters(
            accepted: accepted,
            window: "hello alpha beta"
        )
        let rewritten = RetainedSpanWatch.retainedCharacters(
            accepted: accepted,
            window: "hello something else"
        )
        #expect(kept == accepted.count)
        #expect(rewritten == 0)

        let missing = try RetainedSpanWatch.observation(accepted: accepted, window: nil)
        #expect(missing.missingness == .observerStopped)
        #expect(missing.retainedCharacters == nil)
    }

    @Test("Deleted-then-retyped text cannot resurrect at a later horizon")
    func retentionStaysMonotoneAcrossHorizons() throws {
        var watch = PendingRetainedWatch(
            opportunity: acceptedOpportunity("word", shownAt: Date(timeIntervalSince1970: 1_500))
        )
        // Gone at 5s: the writer deleted the accepted span.
        try watch.observeFiveSeconds(window: "something else")
        #expect(watch.retentionAt5Seconds.retainedCharacters == 0)
        // Retyped by 30s and still present at segment close: authored, not retained.
        try watch.observeThirtySeconds(window: "something else word")
        #expect(watch.retentionAt30Seconds.retainedCharacters == 0)
        try watch.observeSegment(window: "something else word")
        #expect(watch.retentionAtSegmentClose.retainedCharacters == 0)
    }

    @Test("Retyped text after a missing 5s observation clamps to the 30s count")
    func segmentClampsToThirtySecondsWhenFiveIsMissing() throws {
        var watch = PendingRetainedWatch(
            opportunity: acceptedOpportunity("word", shownAt: Date(timeIntervalSince1970: 1_500))
        )
        try watch.observeFiveSeconds(window: nil)
        #expect(watch.retentionAt5Seconds.missingness == .observerStopped)
        try watch.observeThirtySeconds(window: "wo")
        #expect(watch.retentionAt30Seconds.retainedCharacters == 2)
        try watch.observeSegment(window: "word")
        #expect(watch.retentionAtSegmentClose.retainedCharacters == 2)
    }

    private func acceptedOpportunity(
        _ text: String,
        shownAt: Date
    ) -> LiveOnlineOpportunity {
        var opportunity = LiveOnlineOpportunity(
            shownAt: shownAt,
            sessionDigestSHA256: String(repeating: "a", count: 64),
            appCategory: "prose",
            register: "prose",
            boundary: "word-boundary",
            safeOpportunity: true,
            candidateCharacters: text.count,
            candidateWordCount: 1,
            candidateSource: .baseModel,
            opportunityCharacters: 10
        )
        opportunity.noteAccepted(text, kind: .all, at: shownAt.addingTimeInterval(1))
        return opportunity
    }

    @Test("Typed-through requires a settled show and typing, and loses to Tab")
    func typedThroughCloseRule() {
        #expect(
            TypedThroughRule.isTypedThrough(
                displayed: true,
                settledVisibleMilliseconds: 250,
                typedAfterShow: true,
                accepted: false,
                dismissed: false
            )
        )
        #expect(
            !TypedThroughRule.isTypedThrough(
                displayed: true,
                settledVisibleMilliseconds: 80,
                typedAfterShow: true,
                accepted: false,
                dismissed: false
            )
        )
        #expect(
            !TypedThroughRule.isTypedThrough(
                displayed: true,
                settledVisibleMilliseconds: 250,
                typedAfterShow: true,
                accepted: true,
                dismissed: false
            )
        )
    }

    @Test("A finished keep event has no text keys and a diary row does")
    func eventStaysTextFreeWhileDiaryHoldsWords() throws {
        let shownAt = Date(timeIntervalSince1970: 1_500)
        var opportunity = LiveOnlineOpportunity(
            shownAt: shownAt,
            sessionDigestSHA256: TextFreeOnlineEvent.sessionDigest(sessionIdentifier: "session"),
            appCategory: "prose",
            register: "prose",
            boundary: "word-boundary",
            safeOpportunity: true,
            candidateCharacters: 10,
            candidateWordCount: 2,
            candidateSource: .baseModel,
            opportunityCharacters: 20
        )
        opportunity.noteAccepted("alpha beta", kind: .all, at: shownAt.addingTimeInterval(0.4))
        opportunity.settleVisible(at: shownAt.addingTimeInterval(0.4))

        var watch = PendingRetainedWatch(opportunity: opportunity)
        try watch.observeFiveSeconds(window: "alpha beta")
        try watch.observeThirtySeconds(window: "alpha beta")
        try watch.closeSegment(window: "alpha beta")
        let acceptedText = watch.accepted
        let event = try watch.finishedEvent()
        let eventLine = try TextFreeOnlineEvent.encodeJSONL(event)
        let eventObject = try #require(
            JSONSerialization.jsonObject(with: eventLine) as? [String: Any]
        )
        #expect(event.outcome == "accepted-all")
        #expect(event.retentionAt5Seconds.retainedCharacters == 10)
        #expect(Set(eventObject.keys).isDisjoint(with: [
            "text", "prompt", "candidate", "acceptedText", "screenText",
        ]))

        let diary = LocalOutcomeDiaryEntry(
            id: event.id,
            recordedAt: shownAt,
            outcome: event.outcome,
            acceptedText: acceptedText,
            five: event.retentionAt5Seconds,
            thirty: event.retentionAt30Seconds,
            segment: event.retentionAtSegmentClose
        )
        #expect(diary.acceptedText == "alpha beta")
        #expect(diary.fate == .kept)
        #expect(diary.schema == LocalOutcomeDiaryEntry.schema)
        #expect(event.schema == TextFreeOnlineEvent.schema)
    }

    @Test("Rewrite before five seconds is edited, not a missing zero")
    func rewriteIsEdited() throws {
        let shownAt = Date(timeIntervalSince1970: 1_500)
        var opportunity = LiveOnlineOpportunity(
            shownAt: shownAt,
            sessionDigestSHA256: TextFreeOnlineEvent.sessionDigest(sessionIdentifier: "session"),
            appCategory: "chat",
            register: "chat",
            boundary: "word-boundary",
            safeOpportunity: true,
            candidateCharacters: 10,
            candidateWordCount: 2,
            candidateSource: .baseModel,
            opportunityCharacters: 20
        )
        opportunity.noteAccepted("alpha beta", kind: .all, at: shownAt.addingTimeInterval(0.5))
        var watch = PendingRetainedWatch(opportunity: opportunity)
        try watch.observeFiveSeconds(window: "rewritten")
        try watch.observeThirtySeconds(window: "rewritten")
        try watch.closeSegment(window: "rewritten")
        let event = try watch.finishedEvent()
        #expect(event.retentionAt5Seconds.retainedCharacters == 0)
        #expect(event.replacedCharactersWithin5Seconds == 10)
        #expect(event.retentionAt5Seconds.missingness == nil)

        let diary = LocalOutcomeDiaryEntry(
            id: event.id,
            outcome: event.outcome,
            acceptedText: "alpha beta",
            five: event.retentionAt5Seconds,
            thirty: event.retentionAt30Seconds,
            segment: event.retentionAtSegmentClose
        )
        #expect(diary.fate == .edited)
    }

    @Test("An unwitnessed horizon stays missing, not zero")
    func missingHorizonIsNotZero() throws {
        var opportunity = LiveOnlineOpportunity(
            shownAt: Date(timeIntervalSince1970: 1_500),
            sessionDigestSHA256: TextFreeOnlineEvent.sessionDigest(sessionIdentifier: "session"),
            appCategory: "email",
            register: "email",
            boundary: "sentence-boundary",
            safeOpportunity: true,
            candidateCharacters: 10,
            candidateWordCount: 2,
            candidateSource: .baseModel,
            opportunityCharacters: 20
        )
        opportunity.noteAccepted("alpha beta", kind: .word, at: Date(timeIntervalSince1970: 1_501))
        var watch = PendingRetainedWatch(opportunity: opportunity)
        try watch.closeSegment(window: "alpha beta")
        #expect(watch.retentionAt5Seconds.missingness == .segmentClosedEarly)
        #expect(watch.retentionAt30Seconds.missingness == .segmentClosedEarly)
        #expect(watch.retentionAtSegmentClose.retainedCharacters == 10)
        let event = try watch.finishedEvent()
        #expect(event.retentionAt5Seconds.retainedCharacters == nil)
    }

    @Test("Privacy wipe drops the span and keeps the accept count")
    func privacyWipeKeepsCounts() throws {
        var opportunity = LiveOnlineOpportunity(
            shownAt: Date(timeIntervalSince1970: 1_500),
            sessionDigestSHA256: TextFreeOnlineEvent.sessionDigest(sessionIdentifier: "session"),
            appCategory: "prose",
            register: "prose",
            boundary: "word-boundary",
            safeOpportunity: true,
            candidateCharacters: 10,
            candidateWordCount: 2,
            candidateSource: .baseModel,
            opportunityCharacters: 20
        )
        opportunity.noteAccepted("alpha beta", kind: .all, at: Date(timeIntervalSince1970: 1_501))
        var watch = PendingRetainedWatch(opportunity: opportunity)
        watch.markPrivacyExcluded()
        #expect(watch.accepted.isEmpty)
        let event = try watch.finishedEvent()
        #expect(event.outcome == "accepted-all")
        #expect(event.acceptedCharacters == 10)
        #expect(event.safeOpportunity)
        #expect(event.retentionAt5Seconds.missingness == .privacyExcluded)
        #expect(event.retentionAt5Seconds.retainedCharacters == nil)
        #expect(event.replacedCharactersWithin5Seconds == 0)
    }

    @Test("A close without Tab is not stored as zero kept accepts")
    func dismissDoesNotClaimAnAccept() throws {
        var opportunity = LiveOnlineOpportunity(
            shownAt: Date(timeIntervalSince1970: 1_500),
            sessionDigestSHA256: TextFreeOnlineEvent.sessionDigest(sessionIdentifier: "session"),
            appCategory: "prose",
            register: "prose",
            boundary: "word-boundary",
            safeOpportunity: true,
            candidateCharacters: 10,
            candidateWordCount: 2,
            candidateSource: .baseModel,
            opportunityCharacters: 20
        )
        opportunity.settleVisible(at: Date(timeIntervalSince1970: 1_501))
        let event = try opportunity.eventWithoutAcceptedSpan()
        #expect(event.outcome == "ignored")
        #expect(event.acceptedCharacters == 0)
        #expect(event.retentionAt5Seconds.retainedCharacters == 0)
        #expect(event.retentionAt30Seconds.missingness == .notYetObserved)
    }
}
