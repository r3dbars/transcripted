import Foundation

func testAnalyticsEventPolicy() {
    runSuite("AnalyticsEventPolicy only permits reviewed analytics events") {
        let dictationCompleted = AnalyticsEventPolicy.policy(forEvent: "dictation_completed")
        let meetingFailed = AnalyticsEventPolicy.policy(forEvent: "meeting_transcript_failed")
        let unknown = AnalyticsEventPolicy.policy(forEvent: "raw_transcript_uploaded")

        assertEqual(dictationCompleted?.allowedProperties.contains("word_count_bucket"), true, "dictation completion should allow bucketed word counts")
        assertEqual(meetingFailed?.allowedProperties.contains("failure_kind"), true, "meeting failures should allow normalized failure kinds")
        assertNil(unknown, "unreviewed analytics events should not be allowed")
    }
}
