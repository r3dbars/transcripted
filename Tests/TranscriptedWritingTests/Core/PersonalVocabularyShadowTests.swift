import Foundation
import Testing
@testable import TranscriptedWritingCore

@Suite("Personal next-word shadow")
struct PersonalNextWordShadowTests {
    private let cutover: Int64 = 1_000

    @Test("Live recipe identifies its safety adaptation of r1945")
    func frozenRecipeIdentity() {
        let snapshot = PersonalNextWordShadow(evaluationStartMilliseconds: 0).snapshot

        #expect(PersonalNextWordShadow.baselineRecipeID == "r1435-live-v1")
        #expect(PersonalNextWordShadow.candidateRecipeID == "r1945-live-v1")
        #expect(PersonalNextWordShadow.recipeID == "r1945-live-v1")
        #expect(snapshot == PersonalNextWordShadow(evaluationStartMilliseconds: 0).snapshot)
        #expect(PersonalNextWordShadow.evaluationStartMilliseconds == 1_786_556_700_000)
        #expect(PersonalNextWordShadow.maximumContexts == 8_192)
        #expect(PersonalNextWordShadow.maximumTransitions == 32_768)
        #expect(PersonalNextWordShadow.maximumActiveStreams == 64)
        #expect(PersonalNextWordShadow.maximumRecentEventIDs == 2_048)
    }

    @Test("A target is predicted before it is learned")
    func onlineMetricsHaveNoLookahead() {
        var shadow = PersonalNextWordShadow(evaluationStartMilliseconds: 0)
        shadow.consume([event(id: "sequence", text: " echo echo echo ")])

        #expect(shadow.snapshot.opportunities == 2)
        #expect(shadow.snapshot.predictions == 1)
        #expect(shadow.snapshot.exactHits == 1)
        #expect(shadow.snapshot.baselinePredictions == 1)
        #expect(shadow.snapshot.baselineExactHits == 1)
        assertPairedInvariants(shadow.snapshot)
        #expect(shadow.snapshot.coverage == 0.5)
        #expect(shadow.snapshot.precision == 1)
    }

    @Test("Both recipes score before either learns the target")
    func pairedCausality() {
        var shadow = PersonalNextWordShadow(evaluationStartMilliseconds: 0)
        shadow.consume([event(id: "first", text: " echo echo ")])

        #expect(shadow.snapshot.opportunities == 1)
        #expect(shadow.snapshot.predictions == 0)
        #expect(shadow.snapshot.baselinePredictions == 0)
        #expect(shadow.snapshot.outcomeCells.baselineSilentCandidateSilent == 1)
    }

    @Test("Order four predicts and an ineligible context backs off to order zero")
    func contextFourAndBackoff() {
        var contextFour = PersonalNextWordShadow(evaluationStartMilliseconds: cutover)
        contextFour.consume([
            event(id: "train-a", text: " one two three four Finish ", time: 100, session: "a"),
            event(id: "train-b", text: " one two three four Finish ", time: 100, session: "b"),
            event(id: "wrong-a", text: " zero two three four Wrong ", time: 100, session: "w-a"),
            event(id: "wrong-b", text: " zero two three four Wrong ", time: 100, session: "w-b"),
            event(id: "wrong-c", text: " zero two three four Wrong ", time: 100, session: "w-c"),
            event(id: "boundary", text: " one two three four ", time: 999, session: "live"),
            event(id: "target", text: "Finish ", time: cutover, session: "live"),
        ])

        #expect(contextFour.snapshot.opportunities == 1)
        #expect(contextFour.snapshot.predictions == 1)
        #expect(contextFour.snapshot.exactHits == 1)
        #expect(contextFour.snapshot.baselinePredictions == 0)
        #expect(contextFour.snapshot.baselineExactHits == 0)
        #expect(contextFour.snapshot.outcomeCells.baselineSilentCandidateCorrect == 1)
        #expect(contextFour.snapshot.predictionDisagreements == 1)
        assertPairedInvariants(contextFour.snapshot)

        var backoff = PersonalNextWordShadow(evaluationStartMilliseconds: cutover)
        backoff.consume([
            event(id: "rare", text: " cue rare ", time: 100, session: "rare"),
            event(id: "common", text: " common common common ", time: 100, session: "common"),
            event(id: "cue", text: " cue ", time: 999, session: "live"),
            event(id: "common-target", text: "common ", time: cutover, session: "live"),
        ])

        #expect(backoff.snapshot.opportunities == 1)
        #expect(backoff.snapshot.predictions == 1)
        #expect(backoff.snapshot.exactHits == 1)
    }

    @Test("Ratio-one ties are allowed and choose the smallest NFC surface")
    func tieAndShareGates() {
        var tied = PersonalNextWordShadow(evaluationStartMilliseconds: cutover)
        tied.consume([
            event(id: "apple-a", text: " cue Apple ", time: 100, session: "apple-a"),
            event(id: "apple-b", text: " cue Apple ", time: 100, session: "apple-b"),
            event(id: "berry-a", text: " cue Berry ", time: 100, session: "berry-a"),
            event(id: "berry-b", text: " cue Berry ", time: 100, session: "berry-b"),
            event(id: "tie-boundary", text: " cue ", time: 999, session: "tie-live"),
            event(id: "tie-target", text: "Apple ", time: cutover, session: "tie-live"),
        ])

        #expect(tied.snapshot.opportunities == 1)
        #expect(tied.snapshot.predictions == 1)
        #expect(tied.snapshot.exactHits == 1)
        #expect(tied.snapshot.baselinePredictions == 1)
        #expect(tied.snapshot.baselineExactHits == 0)
        #expect(tied.snapshot.outcomeCells.baselineWrongCandidateCorrect == 1)
        #expect(tied.snapshot.predictionDisagreements == 1)
        assertPairedInvariants(tied.snapshot)

        var shareBackoff = PersonalNextWordShadow(evaluationStartMilliseconds: cutover)
        shareBackoff.consume([
            event(id: "a-1", text: " cue Apple ", time: 100, session: "a-1"),
            event(id: "a-2", text: " cue Apple ", time: 100, session: "a-2"),
            event(id: "b-1", text: " cue Berry ", time: 100, session: "b-1"),
            event(id: "b-2", text: " cue Berry ", time: 100, session: "b-2"),
            event(id: "c-1", text: " cue Citrus ", time: 100, session: "c-1"),
            event(id: "share-boundary", text: " cue ", time: 999, session: "share-live"),
            event(id: "share-target", text: "cue ", time: cutover, session: "share-live"),
        ])

        #expect(shareBackoff.snapshot.opportunities == 1)
        #expect(shareBackoff.snapshot.predictions == 1)
        #expect(shareBackoff.snapshot.exactHits == 1)
    }

    @Test("The four both-predict exactness cells remain independently countable")
    func fourBothPredictionOutcomeCells() {
        let bothCorrect = pairedFixture(exactTarget: "Good", exactSupport: "Good", broadSupport: "Good")
        #expect(bothCorrect.outcomeCells.baselineCorrectCandidateCorrect == 1)

        let baselineCorrect = pairedFixture(
            exactTarget: "Good", exactSupport: "Wrong", broadSupport: "Good"
        )
        #expect(baselineCorrect.outcomeCells.baselineCorrectCandidateWrong == 1)

        let candidateCorrect = pairedFixture(
            exactTarget: "Good", exactSupport: "Good", broadSupport: "Wrong"
        )
        #expect(candidateCorrect.outcomeCells.baselineWrongCandidateCorrect == 1)

        let bothWrong = pairedFixture(
            exactTarget: "Target", exactSupport: "Wrong", broadSupport: "Wrong"
        )
        #expect(bothWrong.outcomeCells.baselineWrongCandidateWrong == 1)

        for snapshot in [bothCorrect, baselineCorrect, candidateCorrect, bothWrong] {
            assertPairedInvariants(snapshot)
        }

        let differentWrong = pairedFixture(
            exactTarget: "Target", exactSupport: "Candidate", broadSupport: "Baseline"
        )
        #expect(differentWrong.outcomeCells.baselineWrongCandidateWrong == 1)
        #expect(bothWrong.predictionDisagreements == 0)
        #expect(differentWrong.predictionDisagreements == 1)
    }

    @Test("All nine cells reconstruct both recipe marginals")
    func nineCellMarginals() {
        let cells = PersonalNextWordOutcomeCells(
            baselineSilentCandidateSilent: 1,
            baselineSilentCandidateCorrect: 2,
            baselineSilentCandidateWrong: 3,
            baselineCorrectCandidateSilent: 4,
            baselineCorrectCandidateCorrect: 5,
            baselineCorrectCandidateWrong: 6,
            baselineWrongCandidateSilent: 7,
            baselineWrongCandidateCorrect: 8,
            baselineWrongCandidateWrong: 9
        )

        #expect(cells.opportunities == 45)
        #expect(cells.baselinePredictions == 39)
        #expect(cells.baselineExactHits == 15)
        #expect(cells.candidatePredictions == 33)
        #expect(cells.candidateExactHits == 15)
    }

    @Test("A candidate-only higher-order prediction can be wrong")
    func candidateOnlyWrongCell() {
        var shadow = PersonalNextWordShadow(evaluationStartMilliseconds: cutover)
        shadow.consume([
            event(id: "exact-a", text: " one two three four Candidate ", time: 100, session: "a"),
            event(id: "exact-b", text: " one two three four Candidate ", time: 100, session: "b"),
            event(id: "broad-a", text: " nine ten three four Other ", time: 100, session: "c"),
            event(id: "broad-b", text: " nine ten three four Other ", time: 100, session: "d"),
            event(id: "live-context", text: " one two three four ", time: 999, session: "live"),
            event(id: "live-target", text: "Wrong ", time: cutover, session: "live"),
        ])

        #expect(shadow.snapshot.outcomeCells.baselineSilentCandidateWrong == 1)
        #expect(shadow.snapshot.baselinePredictions == 0)
        #expect(shadow.snapshot.predictions == 1)
        #expect(shadow.snapshot.exactHits == 0)
        #expect(shadow.snapshot.predictionDisagreements == 1)
        assertPairedInvariants(shadow.snapshot)
    }

    @Test("Global counts cross streams while partial tokens do not")
    func globalModelAndIndependentStreams() {
        var shadow = PersonalNextWordShadow(evaluationStartMilliseconds: cutover)
        shadow.consume([
            event(id: "train-a", text: " red fox ", time: 100, session: "a"),
            event(id: "train-b", text: " red fox ", time: 100, session: "b"),
            event(id: "boundary", text: " red ", time: 999, session: "live", app: "app.one"),
            event(id: "other", text: " fox ", time: cutover, session: "live", app: "app.two"),
            event(id: "target", text: "fox ", time: cutover, session: "live", app: "app.one"),
        ])

        #expect(shadow.snapshot.opportunities == 1)
        #expect(shadow.snapshot.predictions == 1)
        #expect(shadow.snapshot.exactHits == 1)

        var keys = PersonalNextWordShadow(evaluationStartMilliseconds: 0)
        keys.consume([
            event(id: "base", text: " al", history: "h", consent: "c", session: "s", app: "app"),
            event(id: "history", text: "pha ", history: "other", consent: "c", session: "s", app: "app"),
            event(id: "consent", text: "pha ", history: "h", consent: "other", session: "s", app: "app"),
            event(id: "session", text: "pha ", history: "h", consent: "c", session: "other", app: "app"),
            event(id: "app", text: "pha ", history: "h", consent: "c", session: "s", app: "other"),
            event(id: "finish", text: "pha ", history: "h", consent: "c", session: "s", app: "app"),
        ])

        #expect(keys.snapshot.learnedContexts == 1)
        #expect(keys.snapshot.learnedTransitions == 1)
        #expect(keys.snapshot.opportunities == 0)
    }

    @Test("Arbitrary event chunking leaves aggregate results unchanged")
    func chunkingDoesNotChangeOutcome() {
        var whole = PersonalNextWordShadow(evaluationStartMilliseconds: 0)
        whole.consume([event(id: "whole", text: " alpha beta alpha beta ")])

        var split = PersonalNextWordShadow(evaluationStartMilliseconds: 0)
        split.consume([event(id: "a", text: " al")])
        split.consume([event(id: "b", text: "pha be")])
        split.consume([event(id: "c", text: "ta alpha b")])
        split.consume([event(id: "d", text: "eta ")])

        #expect(split.snapshot == whole.snapshot)
    }

    @Test("Accepted suggestions never score, train, or provide context")
    func acceptedSuggestionsStayCensoredThroughTheirDelimiter() {
        var shadow = PersonalNextWordShadow(evaluationStartMilliseconds: cutover)
        shadow.consume([
            event(id: "train-a", text: " alpha beta ", time: 100, session: "a"),
            event(id: "train-b", text: " alpha beta ", time: 100, session: "b"),
            event(id: "typed-boundary", text: " alpha ", time: 999, session: "live"),
            event(
                id: "accepted",
                text: "beta",
                time: cutover,
                session: "live",
                source: .acceptedSuggestion
            ),
            event(id: "typed-tail", text: "tail ", time: cutover, session: "live"),
            event(id: "manual", text: " beta ", time: cutover, session: "live"),
        ])

        #expect(shadow.snapshot.opportunities == 0)
        #expect(shadow.snapshot.predictions == 0)
        #expect(shadow.snapshot.exactHits == 0)
    }

    @Test("Accepted-only text leaves the model empty")
    func acceptedOnlyDoesNotModel() {
        var shadow = PersonalNextWordShadow(evaluationStartMilliseconds: 0)
        shadow.consume([event(
            id: "accepted-only",
            text: "alpha beta ",
            source: .acceptedSuggestion
        )])

        #expect(shadow.snapshot.learnedContexts == 0)
        #expect(shadow.snapshot.learnedTransitions == 0)
        #expect(shadow.snapshot.opportunities == 0)
    }

    @Test("Manual typing after an accepted word does not inherit its old context")
    func acceptedSuggestionBreaksContextContinuity() {
        var shadow = PersonalNextWordShadow(evaluationStartMilliseconds: 0)
        shadow.consume([
            event(id: "train", text: " alpha beta "),
            event(id: "boundary", text: " alpha ", session: "live"),
        ])
        let beforeAcceptedText = shadow.snapshot

        shadow.consume([
            event(
                id: "accepted",
                text: "beta",
                session: "live",
                source: .acceptedSuggestion
            ),
            event(id: "manual", text: " gamma ", session: "live"),
        ])

        #expect(shadow.snapshot.learnedContexts == beforeAcceptedText.learnedContexts)
        #expect(shadow.snapshot.learnedTransitions == beforeAcceptedText.learnedTransitions + 1)
    }

    @Test("A retry is removed before it can reverse stream time")
    func retryDeduplicationPrecedesMutation() {
        var shadow = PersonalNextWordShadow(evaluationStartMilliseconds: cutover)
        shadow.consume([
            event(id: "train-a", text: " alpha beta ", time: 100, session: "a"),
            event(id: "train-b", text: " alpha beta ", time: 100, session: "b"),
            event(id: "same", text: " alpha ", time: 999, session: "live"),
            event(id: "same", text: " noise ", time: 1, session: "live"),
            event(id: "target", text: "beta ", time: cutover, session: "live"),
        ])

        #expect(shadow.snapshot.opportunities == 1)
        #expect(shadow.snapshot.predictions == 1)
        #expect(shadow.snapshot.exactHits == 1)
    }

    @Test("Gaps and time reversal censor a possibly truncated token")
    func gapsAndTimeReversalCensorTheTail() {
        let gap = Int64(30 * 60 * 1_000 + 1)
        var afterGap = PersonalNextWordShadow(evaluationStartMilliseconds: cutover)
        afterGap.consume([
            event(id: "train-a", text: " alpha beta ", time: 100, session: "a"),
            event(id: "train-b", text: " alpha beta ", time: 100, session: "b"),
            event(id: "boundary", text: " alpha ", time: 999, session: "live"),
            event(id: "gapped", text: "gamma ", time: 999 + gap, session: "live"),
        ])
        #expect(afterGap.snapshot.opportunities == 0)
        let gapBaseline = modelCountsForAlphaBetaTraining()
        #expect(afterGap.snapshot.learnedContexts == gapBaseline.contexts)
        #expect(afterGap.snapshot.learnedTransitions == gapBaseline.transitions)

        var reversed = PersonalNextWordShadow(evaluationStartMilliseconds: cutover)
        reversed.consume([
            event(id: "train-a", text: " alpha beta ", time: 100, session: "a"),
            event(id: "train-b", text: " alpha beta ", time: 100, session: "b"),
            event(id: "boundary", text: " alpha ", time: 999, session: "live"),
            event(id: "reversed", text: "gamma ", time: 998, session: "live"),
        ])
        #expect(reversed.snapshot.opportunities == 0)
        #expect(reversed.snapshot.learnedContexts == gapBaseline.contexts)
        #expect(reversed.snapshot.learnedTransitions == gapBaseline.transitions)
    }

    @Test("Tail replay drops its possibly truncated first token")
    func tailReplayDoesNotInventAWordPrefix() {
        var shadow = PersonalNextWordShadow(evaluationStartMilliseconds: 0)
        shadow.consume([
            event(id: "tail-a", text: "frag"),
            event(id: "tail-b", text: "ment alpha beta "),
        ])

        #expect(shadow.snapshot.opportunities == 1)
        #expect(shadow.snapshot.predictions == 0)
        #expect(shadow.snapshot.learnedContexts == 2)
        #expect(shadow.snapshot.learnedTransitions == 3)
    }

    @Test("A fresh stream needs a delimiter before its first complete token")
    func freshStreamRequiresObservedBoundary() {
        var unknownStart = PersonalNextWordShadow(evaluationStartMilliseconds: 0)
        unknownStart.consume([event(id: "unknown", text: "alpha beta ")])

        #expect(unknownStart.snapshot.opportunities == 0)
        #expect(unknownStart.snapshot.learnedContexts == 1)
        #expect(unknownStart.snapshot.learnedTransitions == 1)

        var boundedStart = PersonalNextWordShadow(evaluationStartMilliseconds: 0)
        boundedStart.consume([event(id: "bounded", text: " alpha beta ")])

        #expect(boundedStart.snapshot.opportunities == 1)
        #expect(boundedStart.snapshot.learnedContexts == 2)
        #expect(boundedStart.snapshot.learnedTransitions == 3)
    }

    @Test("NFC letter scalars compose, while remaining marks delimit tokens")
    func combiningMarkTokenizationMatchesOfflineRunner() {
        var composed = PersonalNextWordShadow(evaluationStartMilliseconds: 0)
        composed.consume([event(id: "composed", text: " Cafe\u{301} noir ")])

        #expect(composed.snapshot.opportunities == 1)
        #expect(composed.snapshot.learnedContexts == 2)
        #expect(composed.snapshot.learnedTransitions == 3)

        var remainingMark = PersonalNextWordShadow(evaluationStartMilliseconds: 0)
        remainingMark.consume([event(id: "mark", text: " a\u{301}\u{327}b ")])

        #expect(remainingMark.snapshot.opportunities == 1)
        #expect(remainingMark.snapshot.learnedContexts == 2)
        #expect(remainingMark.snapshot.learnedTransitions == 3)
    }

    @Test("A combining mark split across events matches one NFC chunk")
    func combiningMarkAcrossEventsIsChunkInvariant() {
        var whole = PersonalNextWordShadow(evaluationStartMilliseconds: 0)
        whole.consume([event(id: "whole", text: " café noir ")])

        var split = PersonalNextWordShadow(evaluationStartMilliseconds: 0)
        split.consume([event(id: "split-a", text: " cafe")])
        split.consume([event(id: "split-b", text: "\u{301} noir ")])

        #expect(split.snapshot == whole.snapshot)
    }

    @Test("Contexts fold Unicode while targets remain NFC surface-exact")
    func unicodeContextAndSurfaceAccuracy() {
        var exact = PersonalNextWordShadow(evaluationStartMilliseconds: cutover)
        exact.consume([
            event(id: "upper-a", text: " Cafe\u{301} E\u{301}clair ", time: 100, session: "upper-a"),
            event(id: "upper-b", text: " CAFÉ Éclair ", time: 100, session: "upper-b"),
            event(id: "lower-a", text: " café éclair ", time: 100, session: "lower-a"),
            event(id: "lower-b", text: " café éclair ", time: 100, session: "lower-b"),
            event(id: "boundary", text: " café ", time: 999, session: "live"),
            event(id: "target", text: "Éclair ", time: cutover, session: "live"),
        ])

        #expect(exact.snapshot.opportunities == 1)
        #expect(exact.snapshot.predictions == 1)
        #expect(exact.snapshot.exactHits == 1)

        var mismatch = PersonalNextWordShadow(evaluationStartMilliseconds: cutover)
        mismatch.consume([
            event(id: "upper-a", text: " Cafe\u{301} Éclair ", time: 100, session: "upper-a"),
            event(id: "upper-b", text: " CAFÉ Éclair ", time: 100, session: "upper-b"),
            event(id: "boundary", text: " café ", time: 999, session: "live"),
            event(id: "target", text: "éclair ", time: cutover, session: "live"),
        ])

        #expect(mismatch.snapshot.opportunities == 1)
        #expect(mismatch.snapshot.predictions == 1)
        #expect(mismatch.snapshot.exactHits == 0)
    }

    @Test("Capacity is hard, fail-closed, and resettable")
    func capacityAndReset() {
        var shadow = PersonalNextWordShadow(evaluationStartMilliseconds: 0)
        shadow.consume([
            event(id: "capacity-train-a", text: " cue Answer Answer ", session: "capacity-a"),
            event(id: "capacity-train-b", text: " cue Answer Answer ", session: "capacity-b"),
        ])
        #expect(!shadow.snapshot.capacityLimited)
        var events: [PersonalHistoryEvent] = []
        var text = " "
        var chunk = 0
        for index in 0..<2_100 {
            text += uniqueWord(index) + " "
            if text.count >= 420 || index == 2_099 {
                events.append(event(id: "chunk-\(chunk)", text: text, time: Int64(chunk + 1)))
                text = ""
                chunk += 1
            }
        }
        shadow.consume(events)

        let limited = shadow.snapshot
        #expect(limited.capacityLimited)
        #expect(limited.learnedContexts <= PersonalNextWordShadow.maximumContexts)
        #expect(limited.learnedTransitions <= PersonalNextWordShadow.maximumTransitions)

        shadow.consume([
            event(id: "after-cap-boundary", text: " cue ", time: 10_000, session: "after-cap"),
            event(id: "after-cap-target", text: "Answer Answer ", time: 10_000, session: "after-cap"),
        ])
        #expect(shadow.snapshot.learnedContexts == limited.learnedContexts)
        #expect(shadow.snapshot.learnedTransitions == limited.learnedTransitions)
        #expect(shadow.snapshot.opportunities == limited.opportunities + 2)
        #expect(shadow.snapshot.predictions == limited.predictions + 2)
        #expect(shadow.snapshot.exactHits == limited.exactHits + 2)

        shadow.reset()
        #expect(shadow.snapshot == PersonalNextWordShadow(evaluationStartMilliseconds: 0).snapshot)
    }

    @Test("Pre-cutover history warms a post-cutover reconstruction")
    func postCutoverReconstruction() {
        let replay = [
            event(id: "train-a", text: " quiet work ", time: 100, session: "a"),
            event(id: "train-b", text: " quiet work ", time: 100, session: "b"),
            event(id: "boundary", text: " quiet ", time: 999, session: "live"),
            event(id: "target", text: "work ", time: cutover, session: "live"),
        ]

        var whole = PersonalNextWordShadow(evaluationStartMilliseconds: cutover)
        whole.consume(replay)

        var reconstructed = PersonalNextWordShadow(evaluationStartMilliseconds: cutover)
        reconstructed.consume(Array(replay.prefix(2)))
        #expect(reconstructed.snapshot.opportunities == 0)
        #expect(reconstructed.snapshot.learnedTransitions > 0)
        reconstructed.consume(Array(replay.dropFirst(2)))

        #expect(reconstructed.snapshot == whole.snapshot)
        #expect(reconstructed.snapshot.opportunities == 1)
        #expect(reconstructed.snapshot.predictions == 1)
        #expect(reconstructed.snapshot.exactHits == 1)
    }

    @Test("Checkpoint round-trip restores aggregates while replay only rebuilds the model")
    func checkpointRoundTripAndTrainingOnlyReplay() throws {
        let experimentStart = PersonalNextWordShadow.evaluationStartMilliseconds
        let training = [
            event(id: "train-a", text: " quiet work ", time: 100, session: "a"),
            event(id: "train-b", text: " quiet work ", time: 100, session: "b"),
        ]
        var original = PersonalNextWordShadow()
        original.consume(training, scoring: false)
        original.consume([
            event(id: "boundary", text: " quiet ", time: experimentStart, session: "live"),
            event(id: "target", text: "work ", time: experimentStart, session: "live"),
        ])

        let encoded = try JSONEncoder().encode(original.checkpoint)
        let serialized = String(decoding: encoded, as: UTF8.self)
        #expect(!serialized.contains("quiet"))
        #expect(!serialized.contains("work"))
        #expect(!serialized.contains("com.example"))

        let decoded = try JSONDecoder().decode(
            PersonalNextWordShadowCheckpoint.self,
            from: encoded
        )
        var restored = try #require(PersonalNextWordShadow(checkpoint: decoded))
        #expect(restored.checkpoint == original.checkpoint)
        #expect(restored.snapshot.opportunities == original.snapshot.opportunities)
        #expect(restored.snapshot.predictions == original.snapshot.predictions)
        #expect(restored.snapshot.baselinePredictions == original.snapshot.baselinePredictions)
        #expect(restored.snapshot.learnedTransitions == 0)

        let totalsBeforeReplay = restored.checkpoint.totals
        let daysBeforeReplay = restored.checkpoint.activeDays
        restored.consume(training, scoring: false)
        #expect(restored.checkpoint.totals == totalsBeforeReplay)
        #expect(restored.checkpoint.activeDays == daysBeforeReplay)
        #expect(restored.snapshot.learnedTransitions > 0)
    }

    @Test("Old checkpoints decode but only current compatible checkpoints restore")
    func oldCheckpointIsSafeButIncompatible() throws {
        let data = try JSONEncoder().encode(PersonalNextWordShadow().checkpoint)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [Any])
        object[0] = 2
        object[1] = "r1000-live-v0"
        object[2] = "r1001-live-v0"
        object[3] = PersonalNextWordShadow.evaluationStartMilliseconds - 1

        let decoded = try JSONDecoder().decode(
            PersonalNextWordShadowCheckpoint.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        #expect(decoded.v == 2)
        #expect(decoded.baselineRecipeID == "r1000-live-v0")
        #expect(decoded.candidateRecipeID == "r1001-live-v0")
        #expect(!decoded.isCompatibleWithCurrentExperiment)
        #expect(PersonalNextWordShadow(checkpoint: decoded) == nil)
    }

    @Test("Checkpoint validation rejects malformed and over-cap aggregates")
    func malformedCheckpointFailsClosed() throws {
        let valid = PersonalNextWordShadow().checkpoint
        let data = try JSONEncoder().encode(valid)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [Any]
        )
        let mutations: [(Int, Any)] = [
            (0, 0), (1, ""), (2, "invalid recipe"), (3, 0),
        ]
        for (index, replacement) in mutations {
            var mutated = object
            mutated[index] = replacement
            let invalid = try JSONSerialization.data(withJSONObject: mutated)
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(PersonalNextWordShadowCheckpoint.self, from: invalid)
            }
        }

        let negative = PersonalNextWordPairedAggregate(
            outcomeCells: .init(baselineSilentCandidateSilent: -1)
        )
        #expect(PersonalNextWordShadowCheckpoint(
            evaluationStartMilliseconds: PersonalNextWordShadow.evaluationStartMilliseconds,
            totals: negative,
            activeDays: []
        ) == nil)

        let tooManyDays = (0...PersonalNextWordShadow.maximumActiveDays).map {
            PersonalNextWordDailyAggregate(
                utcDayStartMilliseconds: Int64($0) * PersonalNextWordShadow.dayMilliseconds,
                aggregate: .init()
            )
        }
        #expect(PersonalNextWordShadowCheckpoint(
            evaluationStartMilliseconds: PersonalNextWordShadow.evaluationStartMilliseconds,
            totals: .init(),
            activeDays: tooManyDays
        ) == nil)

        #expect(PersonalNextWordShadowCheckpoint(
            evaluationStartMilliseconds: PersonalNextWordShadow.evaluationStartMilliseconds,
            totals: .init(),
            activeDays: [.init(utcDayStartMilliseconds: 0, aggregate: .init())]
        ) == nil)

        let impossibleDisagreement = PersonalNextWordPairedAggregate(
            outcomeCells: .init(baselineCorrectCandidateWrong: 1),
            predictionDisagreements: 0
        )
        #expect(PersonalNextWordShadowCheckpoint(
            evaluationStartMilliseconds: PersonalNextWordShadow.evaluationStartMilliseconds,
            totals: impossibleDisagreement,
            activeDays: []
        ) == nil)
    }

    @Test("A capacity warning survives checkpoint restoration")
    func capacityWarningSurvivesCheckpoint() {
        var shadow = PersonalNextWordShadow()
        let gap = Int64(30 * 60 * 1_000 + 1)
        shadow.consume((0..<6_600).map { index in
            event(
                id: "sticky-cap-\(index)",
                text: " context stays fixed here \(uniqueWord(index)) ",
                time: Int64(index + 1) * gap
            )
        }, scoring: false)
        #expect(shadow.snapshot.capacityLimited)

        let restored = PersonalNextWordShadow(checkpoint: shadow.checkpoint)
        #expect(restored?.snapshot.capacityLimited == true)
        #expect(restored?.snapshot.learnedTransitions == 0)
    }

    @Test("Lifetime totals retain 65 days while recent UTC buckets stay capped at 64")
    func dailyAggregateCap() {
        var shadow = PersonalNextWordShadow()
        let firstDay = PersonalNextWordShadow.evaluationStartMilliseconds
            / PersonalNextWordShadow.dayMilliseconds * PersonalNextWordShadow.dayMilliseconds
        shadow.consume([
            event(id: "day-train-a", text: " cue Answer ", session: "train-a"),
            event(id: "day-train-b", text: " cue Answer ", session: "train-b"),
        ], scoring: false)

        for index in 0..<65 {
            let timestamp = max(
                PersonalNextWordShadow.evaluationStartMilliseconds,
                firstDay + Int64(index) * PersonalNextWordShadow.dayMilliseconds
            )
            let session = "day-\(index)"
            shadow.consume([
                event(id: "day-boundary-\(index)", text: " cue ", time: timestamp, session: session),
                event(id: "day-target-\(index)", text: "Answer ", time: timestamp, session: session),
            ])
        }

        #expect(shadow.snapshot.opportunities == 65)
        #expect(shadow.snapshot.activeDays == PersonalNextWordShadow.maximumActiveDays)
        #expect(shadow.checkpoint.activeDays.count == PersonalNextWordShadow.maximumActiveDays)
        #expect(shadow.checkpoint.activeDays.first?.utcDayStartMilliseconds
            == firstDay + PersonalNextWordShadow.dayMilliseconds)
    }

    @Test("The active-stream bound admits new writing")
    func activeStreamBoundAdmitsNewWriting() {
        var shadow = PersonalNextWordShadow(evaluationStartMilliseconds: 0)
        for index in 0..<PersonalNextWordShadow.maximumActiveStreams {
            shadow.consume([event(
                id: "partial-\(index)",
                text: " partial",
                session: "partial-\(index)"
            )])
        }
        shadow.consume([event(id: "fresh", text: " alpha beta ", session: "fresh")])

        #expect(shadow.snapshot.learnedContexts == 2)
        #expect(shadow.snapshot.learnedTransitions == 3)
        #expect(shadow.snapshot.opportunities == 1)

        let beforeEvictedContinuation = shadow.snapshot
        shadow.consume([event(
            id: "evicted-tail",
            text: "suffix ",
            session: "partial-0"
        )])
        #expect(shadow.snapshot == beforeEvictedContinuation)
    }

    @Test("The transition cap freezes new targets without growing the model")
    func transitionCapFreezesNewTargets() {
        var shadow = PersonalNextWordShadow(evaluationStartMilliseconds: 0)
        let gap = Int64(30 * 60 * 1_000 + 1)
        var events: [PersonalHistoryEvent] = []
        for index in 0..<6_600 {
            events.append(event(
                id: "transition-\(index)",
                text: " context stays fixed here \(uniqueWord(index)) ",
                time: Int64(index + 1) * gap
            ))
        }
        shadow.consume(events)

        let limited = shadow.snapshot
        #expect(limited.capacityLimited)
        #expect(limited.learnedContexts < PersonalNextWordShadow.maximumContexts)
        #expect(limited.learnedTransitions <= PersonalNextWordShadow.maximumTransitions)

        shadow.consume([event(id: "transition-after", text: " novel target ")])
        #expect(shadow.snapshot.learnedContexts == limited.learnedContexts)
        #expect(shadow.snapshot.learnedTransitions == limited.learnedTransitions)
    }

    @Test("Recent event IDs evict only the oldest identity")
    func recentEventIDsUseFIFOEviction() {
        var shadow = PersonalNextWordShadow(evaluationStartMilliseconds: 0)
        for index in 0...PersonalNextWordShadow.maximumRecentEventIDs {
            shadow.consume([event(id: "id-\(index)", text: " alpha ")])
        }

        let beforeProtectedRetry = shadow.snapshot
        shadow.consume([event(id: "id-1", text: " alpha ")])
        #expect(shadow.snapshot == beforeProtectedRetry)

        shadow.consume([event(id: "id-0", text: " alpha ")])
        #expect(shadow.snapshot.opportunities == beforeProtectedRetry.opportunities + 1)
    }

    @Test("predictNextWord serves a well-supported context and never perturbs consume's scoring")
    func predictNextWordServesWellSupportedContext() {
        var shadow = PersonalNextWordShadow(evaluationStartMilliseconds: cutover)
        shadow.consume([
            event(id: "training", text: " three four Finish three four Finish ", time: 100, session: "a"),
        ])
        let before = shadow.snapshot

        let prediction = shadow.predictNextWord(afterTailWords: ["three", "four"])
        #expect(prediction?.word == "Finish")
        #expect(prediction?.support == 2)
        #expect(prediction?.total == 2)

        // Calling the read-only lookup repeatedly must never change what
        // `consume`'s paired A/B scoring later reports.
        for _ in 0..<5 { _ = shadow.predictNextWord(afterTailWords: ["three", "four"]) }
        #expect(shadow.snapshot == before)

        shadow.consume([event(id: "score", text: " three four ", time: cutover, session: "live")])
        #expect(shadow.snapshot.opportunities == before.opportunities + 1)
    }

    @Test("predictNextWord withholds low-support and ambiguous contexts")
    func predictNextWordWithholdsWeakEvidence() {
        var singleton = PersonalNextWordShadow(evaluationStartMilliseconds: cutover)
        singleton.consume([event(id: "single", text: " three four Finish ", time: 100, session: "a")])
        #expect(singleton.predictNextWord(afterTailWords: ["three", "four"]) == nil)

        var ambiguous = PersonalNextWordShadow(evaluationStartMilliseconds: cutover)
        ambiguous.consume([
            event(id: "finish-a", text: " three four Finish ", time: 100, session: "a"),
            event(id: "finish-b", text: " three four Finish ", time: 100, session: "b"),
            event(id: "other-a", text: " three four Other ", time: 100, session: "c"),
            event(id: "other-b", text: " three four Other ", time: 100, session: "d"),
        ])
        #expect(ambiguous.predictNextWord(afterTailWords: ["three", "four"]) == nil)
    }

    @Test("predictNextWord has no answer for an unseen context")
    func predictNextWordUnseenContextIsNil() {
        let shadow = PersonalNextWordShadow(evaluationStartMilliseconds: cutover)
        #expect(shadow.predictNextWord(afterTailWords: ["never", "seen"]) == nil)
    }

    @Test("predictNextWord never serves a contraction remainder split off a larger token")
    func predictNextWordRefusesContractionFragments() {
        var shadow = PersonalNextWordShadow(evaluationStartMilliseconds: cutover)
        shadow.consume([
            event(id: "train-a", text: " I'll be there ", time: 100, session: "a"),
            event(id: "train-b", text: " I'll be there ", time: 100, session: "b"),
        ])

        // The letter-run tokenizer really did split "I'll" into ["I", "ll"]
        // and learn "I" -> "ll" with support 2 — comfortably enough to win
        // on its own. But "ll" was never a whole word the user typed, so
        // serving must never hand it back as if it were.
        let tailWords = PersonalSuggestionPolicy.tailWords(fromContext: "I think I ")
        #expect(tailWords == ["think", "I"])
        #expect(shadow.predictNextWord(afterTailWords: tailWords) == nil)
        #expect(shadow.predictNextWord(afterTailWords: ["I"]) == nil)
    }

    @Test("predictNextWord never backs off to the empty-context global bag")
    func predictNextWordNeverServesFromOrderZero() {
        // Mirrors "Order four predicts and an ineligible context backs off
        // to order zero" above, but through the production-facing
        // predictNextWord entry point: "common" is globally dominant
        // (learned far more often than anything else) yet has no relation
        // to the live "cue" context. The shadow's own baseline/candidate
        // A/B recipes are still allowed to fall back that far (that
        // backoff is exactly what the older test above exercises); a
        // served suggestion must not.
        var shadow = PersonalNextWordShadow(evaluationStartMilliseconds: cutover)
        shadow.consume([
            event(id: "rare", text: " cue rare ", time: 100, session: "rare"),
            event(id: "common", text: " common common common ", time: 100, session: "common"),
        ])
        #expect(shadow.predictNextWord(afterTailWords: ["cue"]) == nil)
        #expect(shadow.predictNextWord(afterTailWords: []) == nil)
    }

    private func modelCountsForAlphaBetaTraining() -> (contexts: Int, transitions: Int) {
        var shadow = PersonalNextWordShadow(evaluationStartMilliseconds: cutover)
        shadow.consume([
            event(id: "baseline-a", text: " alpha beta ", time: 100, session: "a"),
            event(id: "baseline-b", text: " alpha beta ", time: 100, session: "b"),
        ])
        return (shadow.snapshot.learnedContexts, shadow.snapshot.learnedTransitions)
    }

    private func pairedFixture(
        exactTarget: String,
        exactSupport: String,
        broadSupport: String
    ) -> PersonalNextWordShadowSnapshot {
        var shadow = PersonalNextWordShadow(evaluationStartMilliseconds: cutover)
        shadow.consume([
            event(id: "exact-a", text: " one two three four \(exactSupport) ", time: 100, session: "exact-a"),
            event(id: "exact-b", text: " one two three four \(exactSupport) ", time: 100, session: "exact-b"),
        ])
        for index in 0..<5 {
            shadow.consume([event(
                id: "broad-\(index)",
                text: " other path three four \(broadSupport) ",
                time: 100,
                session: "broad-\(index)"
            )])
        }
        shadow.consume([
            event(id: "fixture-boundary", text: " one two three four ", time: 999, session: "live"),
            event(id: "fixture-target", text: "\(exactTarget) ", time: cutover, session: "live"),
        ])
        return shadow.snapshot
    }

    private func assertPairedInvariants(
        _ snapshot: PersonalNextWordShadowSnapshot,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let cells = snapshot.outcomeCells
        #expect(cells.opportunities == snapshot.opportunities, sourceLocation: sourceLocation)
        #expect(cells.baselinePredictions == snapshot.baselinePredictions, sourceLocation: sourceLocation)
        #expect(cells.baselineExactHits == snapshot.baselineExactHits, sourceLocation: sourceLocation)
        #expect(cells.candidatePredictions == snapshot.predictions, sourceLocation: sourceLocation)
        #expect(cells.candidateExactHits == snapshot.exactHits, sourceLocation: sourceLocation)
        #expect(snapshot.baselineExactHits <= snapshot.baselinePredictions, sourceLocation: sourceLocation)
        #expect(snapshot.exactHits <= snapshot.predictions, sourceLocation: sourceLocation)
        #expect(snapshot.predictionDisagreements <= snapshot.opportunities, sourceLocation: sourceLocation)
    }

    private func uniqueWord(_ number: Int) -> String {
        var value = number
        var result = "w"
        for _ in 0..<6 {
            result.append(Character(UnicodeScalar(97 + value % 26)!))
            value /= 26
        }
        return result
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
