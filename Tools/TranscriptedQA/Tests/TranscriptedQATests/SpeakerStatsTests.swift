import XCTest
@testable import transcripted_qa

final class SpeakerStatsTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    private func outcome(
        profile: String,
        kind: String,
        callCount: Int? = nil,
        transcript: String? = nil,
        daysAgo: Double
    ) -> SpeakerLifelineOutcome {
        SpeakerLifelineOutcome(
            profileId: profile,
            kind: kind,
            callCountAtMatch: callCount,
            transcriptId: transcript,
            recordedAt: now.addingTimeInterval(-daysAgo * 24 * 3600)
        )
    }

    private func confirmation(
        profile: String,
        transcript: String,
        id: String? = nil,
        daysAgo: Double
    ) -> SpeakerLifelineConfirmation {
        SpeakerLifelineConfirmation(
            id: id ?? "\(profile)-\(transcript)-\(daysAgo)",
            profileId: profile,
            transcriptId: transcript,
            confirmedAt: now.addingTimeInterval(-daysAgo * 24 * 3600)
        )
    }

    func testMetricsComputeFunnelPrecisionAndWindows() {
        let outcomes = [
            // Profile A graduates on its 6th appearance, inside the last 30 days.
            outcome(profile: "A", kind: "confirmed", callCount: 3, transcript: "m1", daysAgo: 45),
            outcome(profile: "A", kind: "auto_accepted", callCount: 6, transcript: "m2", daysAgo: 10),
            outcome(profile: "A", kind: "auto_accepted", callCount: 7, transcript: "m3", daysAgo: 5),
            // Profile B got corrected in the prior window and confirmed recently.
            outcome(profile: "B", kind: "corrected", callCount: 2, transcript: "m4", daysAgo: 40),
            outcome(profile: "B", kind: "confirmed", callCount: 3, transcript: "m2", daysAgo: 10),
            // Profile C is a fresh enrollment.
            outcome(profile: "C", kind: "named", transcript: "m2", daysAgo: 10),
        ]

        let confirmations = [
            confirmation(profile: "A", transcript: "c1", daysAgo: 50),
            confirmation(profile: "A", transcript: "c2", daysAgo: 40),
            confirmation(profile: "A", transcript: "c3", daysAgo: 30),
            confirmation(profile: "A", transcript: "c4", daysAgo: 20),
            confirmation(profile: "A", transcript: "c5", daysAgo: 11),
            // The unique profile + transcript rule means this duplicate proof
            // must never inflate maturity.
            confirmation(profile: "A", transcript: "c5", daysAgo: 10.5),
            // Evidence written after graduation must not count retroactively.
            confirmation(profile: "A", transcript: "c6", daysAgo: 5),
        ]

        let metrics = SpeakerLifelineMetrics.compute(
            outcomes: outcomes,
            confirmations: confirmations,
            now: now
        )

        XCTAssertEqual(metrics.graduatedProfiles, 1)
        XCTAssertEqual(
            metrics.confirmedMeetingsToGraduation,
            [5],
            "graduation is measured from distinct explicit confirmations present before the first auto-recognition"
        )
        XCTAssertEqual(metrics.medianConfirmedMeetingsToGraduation, 5.0)

        XCTAssertEqual(metrics.allTime.autoRecognitions, 2)
        XCTAssertEqual(metrics.allTime.questions, 4)
        XCTAssertEqual(metrics.allTime.meetings, 4)
        XCTAssertEqual(metrics.allTime.suggestionPrecision ?? -1, 2.0 / 3.0, accuracy: 0.0001)

        XCTAssertEqual(metrics.last30Days.questions, 2)
        XCTAssertEqual(metrics.last30Days.meetings, 2)
        XCTAssertEqual(metrics.last30Days.suggestionPrecision ?? -1, 1.0, accuracy: 0.0001)
        XCTAssertEqual(metrics.last30Days.questionsPerMeeting ?? -1, 1.0, accuracy: 0.0001)

        // Prior window (30–60 days ago) holds two verdicts: A's confirmed at
        // day 45 and B's corrected at day 40 → precision 1/2.
        XCTAssertEqual(metrics.prior30Days.questions, 2)
        XCTAssertEqual(metrics.prior30Days.suggestionPrecision ?? -1, 0.5, accuracy: 0.0001)
    }

    func testMetricsWithNoOutcomes() {
        let metrics = SpeakerLifelineMetrics.compute(
            outcomes: [],
            confirmations: [],
            now: now
        )
        XCTAssertEqual(metrics.graduatedProfiles, 0)
        XCTAssertNil(metrics.medianConfirmedMeetingsToGraduation)
        XCTAssertNil(metrics.allTime.suggestionPrecision)
        XCTAssertNil(metrics.allTime.questionsPerMeeting)
    }

    func testMetricsExposeUnavailableConfirmationLedger() {
        let metrics = SpeakerLifelineMetrics.compute(
            outcomes: [outcome(
                profile: "legacy",
                kind: "auto_accepted",
                callCount: 8,
                transcript: "m1",
                daysAgo: 10
            )],
            confirmations: nil,
            now: now
        )
        XCTAssertNil(metrics.confirmedMeetingsToGraduation)
        XCTAssertNil(metrics.medianConfirmedMeetingsToGraduation)
    }

    func testMedianAveragesTheTwoMiddleGraduationCounts() {
        let outcomes = [
            outcome(profile: "A", kind: "auto_accepted", transcript: "a-auto", daysAgo: 1),
            outcome(profile: "B", kind: "auto_accepted", transcript: "b-auto", daysAgo: 1),
        ]
        let confirmations = [
            confirmation(profile: "A", transcript: "a1", daysAgo: 2),
            confirmation(profile: "B", transcript: "b1", daysAgo: 6),
            confirmation(profile: "B", transcript: "b2", daysAgo: 5),
            confirmation(profile: "B", transcript: "b3", daysAgo: 4),
            confirmation(profile: "B", transcript: "b4", daysAgo: 3),
            confirmation(profile: "B", transcript: "b5", daysAgo: 2),
        ]

        let metrics = SpeakerLifelineMetrics.compute(
            outcomes: outcomes,
            confirmations: confirmations,
            now: now
        )

        XCTAssertEqual(metrics.confirmedMeetingsToGraduation, [1, 5])
        XCTAssertEqual(metrics.medianConfirmedMeetingsToGraduation, 3.0)
    }

    func testReportDoesNotHideAutoRecognitionWhenConfirmationHistoryIsEmpty() {
        let metrics = SpeakerLifelineMetrics.compute(
            outcomes: [outcome(
                profile: "legacy-auto",
                kind: "auto_accepted",
                transcript: "legacy-meeting",
                daysAgo: 1
            )],
            confirmations: [],
            now: now
        )
        let report = SpeakerLifelineReport(
            embedder: "test",
            databasePath: "/tmp/test.sqlite",
            hasOutcomeTable: true,
            hasConfirmationLedger: true,
            totalProfiles: 1,
            namedProfiles: 1,
            disputedProfiles: 0,
            metrics: metrics
        )

        XCTAssertEqual(metrics.graduatedProfiles, 1)
        XCTAssertEqual(metrics.confirmedMeetingsToGraduation, [0])
        XCTAssertTrue(report.renderText().contains("median 0 explicitly confirmed meetings"))
        XCTAssertFalse(report.renderText().contains("no profile has been auto-recognized yet"))
    }

    func testGraduationExcludesConfirmationFromAmbiguousAutoRecognitionSecond() {
        let eventTime = now.addingTimeInterval(-24 * 3600)
        let metrics = SpeakerLifelineMetrics.compute(
            outcomes: [SpeakerLifelineOutcome(
                profileId: "A",
                kind: "auto_accepted",
                callCountAtMatch: 5,
                transcriptId: "auto-meeting",
                recordedAt: eventTime
            )],
            confirmations: [
                SpeakerLifelineConfirmation(
                    id: "clearly-before",
                    profileId: "A",
                    transcriptId: "before-meeting",
                    confirmedAt: eventTime.addingTimeInterval(-1)
                ),
                SpeakerLifelineConfirmation(
                    id: "same-second-ambiguous",
                    profileId: "A",
                    transcriptId: "ambiguous-meeting",
                    confirmedAt: eventTime
                ),
            ],
            now: now
        )

        XCTAssertEqual(
            metrics.confirmedMeetingsToGraduation,
            [1],
            "same-second legacy evidence must be excluded because cross-table ordering is unknowable"
        )
    }

    func testGraduationProofFollowsHistoricalProfileAcrossLaterMerge() {
        let event = SpeakerLifelineMergeEvent(
            id: "merge-source-into-target",
            sourceProfileId: "source",
            targetProfileId: "target",
            mergedAt: now.addingTimeInterval(-5 * 24 * 3600),
            undoneAt: nil,
            sequence: 1
        )
        let sourceProof = (1...5).map { index in
            confirmation(
                profile: "target",
                transcript: "source-\(index)",
                id: "source-proof-\(index)",
                daysAgo: Double(16 - index)
            )
        }
        let targetProof = (1...2).map { index in
            confirmation(
                profile: "target",
                transcript: "target-\(index)",
                id: "target-proof-\(index)",
                daysAgo: Double(20 - index)
            )
        }
        let moves = sourceProof.map { proof in
            SpeakerLifelineConfirmationMove(
                mergeEventId: event.id,
                confirmationId: proof.id,
                sourceProfileId: "source",
                targetProfileId: "target",
                transcriptId: proof.transcriptId,
                confirmedAt: proof.confirmedAt
            )
        }
        let outcomes = [
            // Before the merge, only the source's five proofs belong to it.
            outcome(profile: "source", kind: "auto_accepted", transcript: "source-auto", daysAgo: 10),
            // After the merge, the keeper owns both disjoint proof sets.
            outcome(profile: "target", kind: "auto_accepted", transcript: "target-auto", daysAgo: 4),
        ]

        let metrics = SpeakerLifelineMetrics.compute(
            outcomes: outcomes,
            confirmations: sourceProof + targetProof,
            confirmationMoves: moves,
            mergeEvents: [event],
            now: now
        )

        XCTAssertEqual(
            metrics.confirmedMeetingsToGraduation,
            [5, 7],
            "a later merge must preserve historical source proof without lending it the target's earlier confirmations"
        )
    }

    func testGraduationProofSurvivesChainedMergeUnmergeWithDuplicateMeetings() {
        let firstMerge = SpeakerLifelineMergeEvent(
            id: "merge-a-into-b",
            sourceProfileId: "A",
            targetProfileId: "B",
            mergedAt: now.addingTimeInterval(-12 * 24 * 3600),
            undoneAt: nil,
            sequence: 1
        )
        let activeSecondMerge = SpeakerLifelineMergeEvent(
            id: "merge-b-into-c",
            sourceProfileId: "B",
            targetProfileId: "C",
            mergedAt: now.addingTimeInterval(-8 * 24 * 3600),
            undoneAt: nil,
            sequence: 2
        )
        let undoneSecondMerge = SpeakerLifelineMergeEvent(
            id: activeSecondMerge.id,
            sourceProfileId: activeSecondMerge.sourceProfileId,
            targetProfileId: activeSecondMerge.targetProfileId,
            mergedAt: activeSecondMerge.mergedAt,
            undoneAt: now.addingTimeInterval(-4 * 24 * 3600),
            sequence: activeSecondMerge.sequence
        )

        let aUnique = confirmation(profile: "C", transcript: "a-only", id: "a-only", daysAgo: 20)
        let aShared = confirmation(profile: "B", transcript: "shared", id: "a-shared", daysAgo: 19)
        let bUnique = confirmation(profile: "C", transcript: "b-only", id: "b-only", daysAgo: 18)
        let bShared = confirmation(profile: "C", transcript: "shared", id: "b-shared", daysAgo: 17)
        let cUnique = confirmation(profile: "C", transcript: "c-only", id: "c-only", daysAgo: 16)
        let cShared = confirmation(profile: "C", transcript: "shared", id: "c-shared", daysAgo: 15)

        func move(
            _ proof: SpeakerLifelineConfirmation,
            event: SpeakerLifelineMergeEvent,
            source: String,
            target: String
        ) -> SpeakerLifelineConfirmationMove {
            SpeakerLifelineConfirmationMove(
                mergeEventId: event.id,
                confirmationId: proof.id,
                sourceProfileId: source,
                targetProfileId: target,
                transcriptId: proof.transcriptId,
                confirmedAt: proof.confirmedAt
            )
        }

        let moves = [
            move(aUnique, event: firstMerge, source: "A", target: "B"),
            // This duplicate was deleted when A merged into B, so it has no
            // second move. The surviving B copy still carries "shared" onward.
            move(aShared, event: firstMerge, source: "A", target: "B"),
            move(aUnique, event: activeSecondMerge, source: "B", target: "C"),
            move(bUnique, event: activeSecondMerge, source: "B", target: "C"),
            move(bShared, event: activeSecondMerge, source: "B", target: "C"),
        ]
        let confirmations = [aUnique, bUnique, bShared, cUnique, cShared]

        let whileMerged = SpeakerLifelineMetrics.compute(
            outcomes: [outcome(
                profile: "C",
                kind: "auto_accepted",
                transcript: "c-auto-merged",
                daysAgo: 6
            )],
            confirmations: confirmations,
            confirmationMoves: moves,
            mergeEvents: [firstMerge, activeSecondMerge],
            now: now
        )
        XCTAssertEqual(
            whileMerged.confirmedMeetingsToGraduation,
            [4],
            "A, B, and C proof should form one four-meeting union while the chain is merged"
        )

        let afterUnmerge = SpeakerLifelineMetrics.compute(
            outcomes: [
                outcome(profile: "A", kind: "auto_accepted", transcript: "a-auto", daysAgo: 13),
                outcome(profile: "B", kind: "auto_accepted", transcript: "b-auto", daysAgo: 3),
                outcome(profile: "C", kind: "auto_accepted", transcript: "c-auto", daysAgo: 3),
            ],
            confirmations: confirmations,
            confirmationMoves: moves,
            mergeEvents: [firstMerge, undoneSecondMerge],
            now: now
        )
        XCTAssertEqual(
            afterUnmerge.confirmedMeetingsToGraduation,
            [2, 2, 3],
            "undoing B into C must restore B's A+B union and leave C's duplicate meeting counted once"
        )
    }

    func testTrendLineDirections() {
        // Precision rising is improving.
        XCTAssertTrue(
            SpeakerLifelineReport.trendLine(
                current: 0.95, previous: 0.85,
                format: SpeakerLifelineReport.percent, improvesWhenRising: true
            ).contains("↑ improving")
        )
        // Questions-per-meeting falling is improving.
        XCTAssertTrue(
            SpeakerLifelineReport.trendLine(
                current: 1.0, previous: 2.0,
                format: { String(format: "%.1f", $0) }, improvesWhenRising: false
            ).contains("↓ improving")
        )
        // Precision falling is regressing.
        XCTAssertTrue(
            SpeakerLifelineReport.trendLine(
                current: 0.7, previous: 0.9,
                format: SpeakerLifelineReport.percent, improvesWhenRising: true
            ).contains("↓ regressing")
        )
        XCTAssertTrue(
            SpeakerLifelineReport.trendLine(
                current: 0.9, previous: 0.9001,
                format: SpeakerLifelineReport.percent, improvesWhenRising: true
            ).contains("→ steady")
        )
        XCTAssertEqual(
            SpeakerLifelineReport.trendLine(
                current: nil, previous: 0.9,
                format: SpeakerLifelineReport.percent, improvesWhenRising: true
            ),
            "no data in the last 30 days"
        )
    }
}
