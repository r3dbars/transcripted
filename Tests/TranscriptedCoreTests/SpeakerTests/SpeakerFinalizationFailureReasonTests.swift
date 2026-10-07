import XCTest
@testable import TranscriptedCore

/// The telemetry suites (AnalyticsEventPolicyTests, SentryEventPolicyTests) can't
/// link this Core type, so they carry a copy of these codes. This test keeps that
/// copy honest: if a reason is added, renamed, or removed, it goes red until the
/// list here and in those suites is updated together.
final class SpeakerFinalizationFailureReasonTests: XCTestCase {
    func testReasonCodesMatchTheListTelemetrySuitesCheck() {
        XCTAssertEqual(
            Set(SpeakerFinalizationFailureReason.allCases.map(\.rawValue)),
            [
                "plan_missing_embedding",
                "transcript_unresolved",
                "transcript_unreadable",
                "name_rewrite_failed",
                "deferred_marker_failed",
                "collapse_failed",
                "discard_failed",
                "merge_profile_missing",
                "merge_embedding_invalid",
                "confirmation_profile_missing",
                "database_unavailable",
                "database_write_failed",
            ]
        )
    }
}
