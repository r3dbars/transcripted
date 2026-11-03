import XCTest
@testable import TranscriptedCore

/// Promise: a call-audio voice gets a call-app name only when the call app
/// clearly showed one other person talking while that voice spoke; anything
/// weaker, mixed, or ambiguous is withheld with a reason.
final class CallSpeakerAttributionPolicyTests: XCTestCase {
    private typealias Policy = CallSpeakerAttributionPolicy

    private func interval(_ name: String, _ start: Double, _ end: Double) -> CallSpeakerActivity.Interval {
        CallSpeakerActivity.Interval(name: name, start: start, end: end)
    }

    private func spans(_ pairs: [(Double, Double)]) -> [Policy.SpeechSpan] {
        pairs.map { Policy.SpeechSpan(start: $0.0, end: $0.1) }
    }

    private func activity(
        _ intervals: [CallSpeakerActivity.Interval],
        roster: [String] = [],
        selfNames: Set<String> = [],
        indicator: Bool = true
    ) -> CallSpeakerActivity {
        CallSpeakerActivity(
            intervals: intervals,
            rosterNames: roster,
            selfNames: selfNames,
            sawSpeakingIndicator: indicator
        )
    }

    func testOneClearSpeakerNamesTheirVoice() {
        let outcome = Policy.attribute(
            activity: activity([interval("Alex Kim", 0, 10)]),
            clusters: ["1": spans([(1, 9)])]
        )
        XCTAssertEqual(outcome.names, ["1": "Alex Kim"])
        XCTAssertTrue(outcome.withheld.isEmpty)
    }

    func testTwoVoicesGetTheirOwnNames() {
        let outcome = Policy.attribute(
            activity: activity([interval("Alex Kim", 0, 10), interval("Blair Ng", 10, 20)]),
            clusters: ["1": spans([(0, 9)]), "2": spans([(11, 19)])]
        )
        XCTAssertEqual(outcome.names, ["1": "Alex Kim", "2": "Blair Ng"])
    }

    func testTheLocalUserIsNeverAnEvidenceName() {
        // The user's own tile lights up over the whole span, case and spacing
        // differ from selfNames; Alex is still the only other speaker.
        let outcome = Policy.attribute(
            activity: activity(
                [interval("  you ", 0, 10), interval("Alex Kim", 0, 10)],
                selfNames: ["You"]
            ),
            clusters: ["1": spans([(0, 10)])]
        )
        XCTAssertEqual(outcome.names, ["1": "Alex Kim"])
    }

    func testOnlySelfIntervalsGiveNoEvidence() {
        let outcome = Policy.attribute(
            activity: activity([interval("Me", 0, 10)], selfNames: ["me"]),
            clusters: ["1": spans([(0, 10)])]
        )
        XCTAssertTrue(outcome.names.isEmpty)
        XCTAssertEqual(outcome.withheld, ["1": .noEvidence])
    }

    func testTwoNamesAtOnceDoNotCount() {
        // Alex and Blair both lit for the whole voice: nothing is evidence.
        let outcome = Policy.attribute(
            activity: activity([interval("Alex Kim", 0, 10), interval("Blair Ng", 0, 10)]),
            clusters: ["1": spans([(0, 10)])]
        )
        XCTAssertEqual(outcome.withheld, ["1": .noEvidence])

        // Overlap only for part of it: the single-name part still counts.
        let partial = Policy.attribute(
            activity: activity([interval("Alex Kim", 0, 10), interval("Blair Ng", 0, 4)]),
            clusters: ["1": spans([(0, 10)])]
        )
        XCTAssertEqual(partial.names, ["1": "Alex Kim"])
    }

    func testUnderThreeSecondsIsWithheld() {
        let outcome = Policy.attribute(
            activity: activity([interval("Alex Kim", 0, 2.5)]),
            clusters: ["1": spans([(0, 2.5)])]
        )
        XCTAssertEqual(outcome.withheld, ["1": .tooLittleEvidence])

        let atBar = Policy.attribute(
            activity: activity([interval("Alex Kim", 0, 3)]),
            clusters: ["1": spans([(0, 3)])]
        )
        XCTAssertEqual(atBar.names, ["1": "Alex Kim"])
    }

    func testDisagreeingNamesAreWithheld() {
        // 6 s Alex, 4 s Blair over one voice: 60% share, under 70%.
        let outcome = Policy.attribute(
            activity: activity([interval("Alex Kim", 0, 6), interval("Blair Ng", 6, 10)]),
            clusters: ["1": spans([(0, 10)])]
        )
        XCTAssertEqual(outcome.withheld, ["1": .namesDisagree])

        // 8 s vs 2 s: 80%, passes.
        let mostly = Policy.attribute(
            activity: activity([interval("Alex Kim", 0, 8), interval("Blair Ng", 8, 10)]),
            clusters: ["1": spans([(0, 10)])]
        )
        XCTAssertEqual(mostly.names, ["1": "Alex Kim"])
    }

    func testLowCoverageIsWithheld() {
        // 4 s of evidence over 40 s of speech: 10% covered, under 20%.
        let outcome = Policy.attribute(
            activity: activity([interval("Alex Kim", 0, 4)]),
            clusters: ["1": spans([(0, 40)])]
        )
        XCTAssertEqual(outcome.withheld, ["1": .lowCoverage])

        // 10 s over 40 s: 25%, passes.
        let enough = Policy.attribute(
            activity: activity([interval("Alex Kim", 0, 10)]),
            clusters: ["1": spans([(0, 40)])]
        )
        XCTAssertEqual(enough.names, ["1": "Alex Kim"])
    }

    func testLoneVisibleRosterNameCannotNameUnrelatedSpeech() {
        // A pinned or partially recognized tile is not a complete roster.
        let outcome = Policy.attribute(
            activity: activity([], roster: ["Alex Kim"], indicator: false),
            clusters: ["1": spans([(0, 20)])]
        )
        XCTAssertTrue(outcome.names.isEmpty)
        XCTAssertEqual(outcome.withheld, ["1": .noEvidence])
    }

    func testPartialRosterWithKnownSelfStillCannotNameSpeech() {
        // Recognizing self does not prove every remote tile was visible.
        let outcome = Policy.attribute(
            activity: activity([], roster: ["Alex Kim", "You"], selfNames: ["You"], indicator: false),
            clusters: ["1": spans([(0, 20)]), "2": spans([(30, 31)])]
        )
        XCTAssertTrue(outcome.names.isEmpty)
        XCTAssertEqual(outcome.withheld, ["1": .noEvidence, "2": .noEvidence])
    }

    func testUnrecognizedSelfTileCannotNameRemoteSpeech() {
        // A missing self selector leaves the local display name in the roster.
        let outcome = Policy.attribute(
            activity: activity([], roster: ["Local Person"], indicator: false),
            clusters: ["1": spans([(0, 20)])]
        )
        XCTAssertTrue(outcome.names.isEmpty)
        XCTAssertEqual(outcome.withheld, ["1": .noEvidence])
    }

    func testKnownSelfOnlyRosterCannotNameRemoteSpeech() {
        let outcome = Policy.attribute(
            activity: activity([], roster: ["Local Person"], selfNames: ["Local Person"], indicator: false),
            clusters: ["1": spans([(0, 20)])]
        )
        XCTAssertTrue(outcome.names.isEmpty)
        XCTAssertEqual(outcome.withheld, ["1": .noEvidence])
    }

    func testRosterCannotNameSpeechWithoutOverlappingIndicatorEvidence() {
        let outcome = Policy.attribute(
            activity: activity([interval("Alex Kim", 30, 40)], roster: ["Alex Kim"]),
            clusters: ["1": spans([(0, 20)])]
        )
        XCTAssertTrue(outcome.names.isEmpty)
        XCTAssertEqual(outcome.withheld, ["1": .noEvidence])
    }

    func testOnePersonSplitIntoTwoVoicesNamesBothWhenEachPasses() {
        let outcome = Policy.attribute(
            activity: activity([interval("Alex Kim", 0, 20)]),
            clusters: ["1": spans([(0, 8)]), "2": spans([(10, 18)]), "3": spans([(19, 20)])]
        )
        XCTAssertEqual(outcome.names, ["1": "Alex Kim", "2": "Alex Kim"])
        XCTAssertEqual(outcome.withheld, ["3": .tooLittleEvidence])
    }

    func testMostFrequentSpellingIsUsed() {
        let outcome = Policy.attribute(
            activity: activity([
                interval("alex kim", 0, 2),
                interval("Alex Kim", 2, 4),
                interval("Alex  Kim", 4, 6),
                interval("Alex Kim", 6, 8),
            ]),
            clusters: ["1": spans([(0, 8)])]
        )
        XCTAssertEqual(outcome.names, ["1": "Alex Kim"])
    }

    func testEvidenceOutsideCoverageIsIgnored() {
        var activity = activity([interval("Alex Kim", 0, 10)])
        activity.coverage = [CallSpeakerActivity.Span(start: 0, end: 2)]
        let outcome = Policy.attribute(activity: activity, clusters: ["1": spans([(0, 10)])])
        XCTAssertEqual(outcome.withheld, ["1": .tooLittleEvidence])
    }
}
