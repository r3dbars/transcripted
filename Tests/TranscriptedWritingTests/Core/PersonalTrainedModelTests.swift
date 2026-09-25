import Foundation
import Testing
@testable import TranscriptedWritingCore

/// The trained next-word table is durable state now, not something rebuilt
/// from a bounded tail of raw history on every launch. Persisting it is only
/// honest if a restore is indistinguishable from that rebuild, so these tests
/// compare a restored-then-topped-up shadow against one that never restarted.
@Suite("Personal trained model")
struct PersonalTrainedModelTests {
    private let cutover: Int64 = 1_000

    @Test("Restore plus the remaining events equals one uninterrupted shadow")
    func restoreThenCatchUpMatchesAnUninterruptedShadow() {
        let early = [
            event(id: "one", text: " alpha beta gamma alpha beta gamma "),
            event(id: "two", text: "alpha beta delta "),
        ]
        let late = [
            event(id: "three", text: "alpha beta gamma "),
            event(id: "four", text: " epsilon alpha beta "),
        ]

        var uninterrupted = PersonalNextWordShadow(evaluationStartMilliseconds: cutover)
        uninterrupted.consume(early)
        uninterrupted.consume(late)

        var trained = PersonalNextWordShadow(evaluationStartMilliseconds: cutover)
        trained.consume(early)
        var restored = PersonalNextWordShadow(evaluationStartMilliseconds: cutover)
        let didRestore = restored.restore(trained.trainedModel)
        #expect(didRestore)
        restored.consume(late)

        #expect(restored.trainedModel == uninterrupted.trainedModel)
        #expect(restored.snapshot.learnedContexts == uninterrupted.snapshot.learnedContexts)
        #expect(restored.snapshot.learnedTransitions == uninterrupted.snapshot.learnedTransitions)
        for tail in [["alpha", "beta"], ["beta", "gamma"], ["epsilon"], ["nothing"]] {
            #expect(restored.predictNextWord(afterTailWords: tail)
                == uninterrupted.predictNextWord(afterTailWords: tail))
        }
        #expect(restored.predictNextWord(afterTailWords: ["alpha", "beta"])?.word == "gamma")
    }

    @Test("A retried append after a restart is refused, as a rebuild from the log would refuse it")
    func retriedEventAfterRestoreIsNotLearnedTwice() {
        var live = PersonalNextWordShadow()
        let events = [
            event(id: "e1", text: "see you tomorrow "),
            event(id: "e2", text: "see you tomorrow "),
        ]
        live.consume(events, scoring: false)
        let before = live.trainedModel

        var restored = PersonalNextWordShadow()
        let restoredOK = restored.restore(before)
        #expect(restoredOK)
        // The keyboard lost the acknowledgement and sends the last event again.
        restored.consume([events[1]], scoring: false)
        #expect(restored.trainedModel.contexts == before.contexts)
        #expect(!before.recentEvents.isEmpty)
    }

    @Test("A restart mid-word does not reset the stream: token, context, and censoring survive")
    func streamStateSurvivesTheRestart() {
        // The keystrokes of one word arrive split across the save boundary.
        // Without the stream state the second half would be parsed as the
        // start of a fresh, censored stream and the word would be lost.
        let early = [event(id: "one", text: " ready steady go ready steady g")]
        let late = [event(id: "two", text: "o ")]

        var uninterrupted = PersonalNextWordShadow(evaluationStartMilliseconds: cutover)
        uninterrupted.consume(early)
        uninterrupted.consume(late)

        var restored = PersonalNextWordShadow(evaluationStartMilliseconds: cutover)
        var trained = PersonalNextWordShadow(evaluationStartMilliseconds: cutover)
        trained.consume(early)
        let didRestore = restored.restore(trained.trainedModel)
        #expect(didRestore)
        restored.consume(late)

        #expect(restored.trainedModel == uninterrupted.trainedModel)
        #expect(restored.predictNextWord(afterTailWords: ["ready", "steady"])?.word == "go")
        #expect(uninterrupted.predictNextWord(afterTailWords: ["ready", "steady"])?.word == "go")
    }

    @Test("The durable form is deterministic and carries the capacity flags")
    func durableFormIsDeterministic() throws {
        var left = PersonalNextWordShadow(evaluationStartMilliseconds: cutover)
        var right = PersonalNextWordShadow(evaluationStartMilliseconds: cutover)
        let events = [
            event(id: "a", text: " one two three one two three "),
            event(id: "b", text: " four five four five ", session: "other"),
        ]
        left.consume(events)
        right.consume(events)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(left.trainedModel) == encoder.encode(right.trainedModel))
        #expect(left.trainedModel.recipeID == PersonalNextWordShadow.recipeID)
        #expect(left.trainedModel.v == PersonalNextWordTrainedModel.version)
        #expect(!left.trainedModel.capacityLimited)
        #expect(left.trainedModel.transitionCount == left.snapshot.learnedTransitions)
        #expect(left.trainedModel.contexts.count == left.snapshot.learnedContexts)
    }

    @Test("The durable form round-trips through JSON unchanged")
    func codableRoundTrip() throws {
        var shadow = PersonalNextWordShadow(evaluationStartMilliseconds: cutover)
        shadow.consume([
            event(id: "a", text: " sign off kindly sign off kindly sign "),
            event(id: "b", text: " different stream words ", session: "second"),
        ])
        let encoded = try JSONEncoder().encode(shadow.trainedModel)
        let decoded = try JSONDecoder().decode(PersonalNextWordTrainedModel.self, from: encoded)

        #expect(decoded == shadow.trainedModel)
        var restored = PersonalNextWordShadow(evaluationStartMilliseconds: cutover)
        let didRestore = restored.restore(decoded)
        #expect(didRestore)
        #expect(restored.trainedModel == shadow.trainedModel)
    }

    @Test("A model from another schema or recipe is refused, leaving the shadow untouched")
    func incompatibleModelIsRefused() throws {
        var shadow = PersonalNextWordShadow(evaluationStartMilliseconds: cutover)
        shadow.consume([event(id: "a", text: " keep this learning keep this learning ")])
        let before = shadow.trainedModel

        var other = PersonalNextWordShadow(evaluationStartMilliseconds: cutover)
        other.consume([event(id: "b", text: " different different different ")])
        let encoded = try JSONEncoder().encode(other.trainedModel)
        var fields = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [Any]
        )
        fields[1] = "retired-recipe"
        let foreign = try JSONDecoder().decode(
            PersonalNextWordTrainedModel.self,
            from: try JSONSerialization.data(withJSONObject: fields)
        )
        #expect(!foreign.isCompatibleWithCurrentRecipe)
        let refusedRecipe = shadow.restore(foreign)
        #expect(!refusedRecipe)
        #expect(shadow.trainedModel == before)

        fields[1] = PersonalNextWordShadow.recipeID
        fields[0] = PersonalNextWordTrainedModel.version + 1
        let futureSchema = try JSONDecoder().decode(
            PersonalNextWordTrainedModel.self,
            from: try JSONSerialization.data(withJSONObject: fields)
        )
        #expect(!futureSchema.isCompatibleWithCurrentRecipe)
        let refusedSchema = shadow.restore(futureSchema)
        #expect(!refusedSchema)
        #expect(shadow.trainedModel == before)
    }

    @Test("A structurally impossible table is rejected at decode, not half-loaded")
    func corruptTableFailsClosed() throws {
        var shadow = PersonalNextWordShadow(evaluationStartMilliseconds: cutover)
        shadow.consume([event(id: "a", text: " one two one two one two ")])
        let encoded = try JSONEncoder().encode(shadow.trainedModel)
        var fields = try #require(try JSONSerialization.jsonObject(with: encoded) as? [Any])

        // A transition count that does not match the table it claims to
        // describe would make the capacity limit meaningless.
        fields[4] = 99
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                PersonalNextWordTrainedModel.self,
                from: try JSONSerialization.data(withJSONObject: fields)
            )
        }
    }

    @Test("Restoring leaves the paired aggregate counters alone")
    func restoreDoesNotTouchAggregates() {
        var scored = PersonalNextWordShadow(evaluationStartMilliseconds: cutover)
        scored.consume([event(id: "a", text: " same same same same ", time: cutover)])
        #expect(scored.snapshot.opportunities > 0)
        let aggregatesBefore = scored.snapshot.outcomeCells

        var other = PersonalNextWordShadow(evaluationStartMilliseconds: cutover)
        other.consume([event(id: "b", text: " other other other ", time: cutover)])
        let didRestore = scored.restore(other.trainedModel)
        #expect(didRestore)

        #expect(scored.snapshot.outcomeCells == aggregatesBefore)
        #expect(scored.snapshot.learnedContexts == other.snapshot.learnedContexts)
    }

    private func event(
        id: String,
        text: String,
        time: Int64 = 1,
        history: String = "history",
        consent: String = "consent",
        session: String = "session",
        app: String = "com.example.Editor",
        source: PersonalHistoryEventSource = .typed
    ) -> PersonalHistoryEvent {
        PersonalHistoryEvent(
            id: id,
            timestampMilliseconds: time,
            historyIdentifier: history,
            consentIdentifier: consent,
            sessionIdentifier: session,
            appBundleIdentifier: app,
            source: source,
            text: text
        )!
    }
}
