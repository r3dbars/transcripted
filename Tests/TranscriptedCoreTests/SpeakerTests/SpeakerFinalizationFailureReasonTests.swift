import XCTest
@testable import TranscriptedCore

/// These raw values go off-device as Sentry tags and PostHog properties, and
/// dashboards group on them. Renaming one silently splits a series, so any
/// add, rename, or removal has to show up here as a deliberate edit.
final class SpeakerFinalizationFailureReasonTests: XCTestCase {
    func testReasonCodesAreStable() {
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
