import Testing
@testable import TranscriptedWritingCore

@Suite("Retained-character observation")
struct RetainedCharacterObservationTests {
    @Test("An observed count cannot also carry missingness")
    func observedCountRejectsAMissingReason() throws {
        let kept = try RetainedCharacterObservation(retainedCharacters: 8).validated()
        #expect(kept.retainedCharacters == 8)
        #expect(kept.missingness == nil)
        #expect(kept.isObserved)

        let missing = try RetainedCharacterObservation(missingness: .notYetObserved).validated()
        #expect(missing.retainedCharacters == nil)
        #expect(missing.missingness == .notYetObserved)
        #expect(!missing.isObserved)

        let both = RetainedCharacterObservation(
            unchecked: 0,
            missingness: .notYetObserved
        )
        #expect(throws: RetainedCharacterObservationError.ambiguous) {
            try both.validated()
        }
        #expect(throws: RetainedCharacterObservationError.negativeCount) {
            _ = try RetainedCharacterObservation(retainedCharacters: -1)
        }
    }

    @Test("A flicker below 200ms is not a read, and cannot be typed-through")
    func flickerIsNotTypedThrough() {
        #expect(!SettledVisibility.countsAsRead(nil))
        #expect(!SettledVisibility.countsAsRead(199))
        #expect(SettledVisibility.countsAsRead(200))
        #expect(!TypedThroughRule.isEligible(displayed: true, settledVisibleMilliseconds: 80))
        #expect(TypedThroughRule.isEligible(displayed: true, settledVisibleMilliseconds: 200))
        #expect(!TypedThroughRule.isEligible(displayed: false, settledVisibleMilliseconds: 400))
        #expect(
            TypedThroughRule.isTypedThrough(
                displayed: true,
                settledVisibleMilliseconds: 200,
                typedAfterShow: true,
                accepted: false,
                dismissed: false
            )
        )
    }
}
