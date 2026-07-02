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

        let metrics = SpeakerLifelineMetrics.compute(outcomes: outcomes, now: now)

        XCTAssertEqual(metrics.graduatedProfiles, 1)
        XCTAssertEqual(
            metrics.appearancesToGraduation,
            [7],
            "call_count_at_match is the pre-meeting count, so appearance number is 6 + 1, from the first auto-recognition only"
        )

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
        let metrics = SpeakerLifelineMetrics.compute(outcomes: [], now: now)
        XCTAssertEqual(metrics.graduatedProfiles, 0)
        XCTAssertNil(metrics.medianAppearancesToGraduation)
        XCTAssertNil(metrics.allTime.suggestionPrecision)
        XCTAssertNil(metrics.allTime.questionsPerMeeting)
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
