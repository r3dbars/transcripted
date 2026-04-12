import Foundation

func testAnalyticsEventPolicy() {
    runSuite("AnalyticsEventPolicy only permits reviewed analytics events") {
        let dictationCompleted = AnalyticsEventPolicy.policy(forEvent: "dictation_completed")
        let dictationNoSpeech = AnalyticsEventPolicy.policy(forEvent: "dictation_no_speech")
        let meetingFailed = AnalyticsEventPolicy.policy(forEvent: "meeting_transcript_failed")
        let unknown = AnalyticsEventPolicy.policy(forEvent: "raw_transcript_uploaded")

        assertEqual(dictationCompleted?.allowedProperties.contains("word_count_bucket"), true, "dictation completion should allow bucketed word counts")
        assertEqual(dictationNoSpeech?.allowedProperties.contains("duration_bucket"), true, "dictation no-speech should keep a coarse duration bucket")
        assertEqual(dictationNoSpeech?.allowedProperties.contains("trigger"), true, "dictation no-speech should preserve trigger attribution")
        assertEqual(meetingFailed?.allowedProperties.contains("failure_kind"), true, "meeting failures should allow normalized failure kinds")
        assertNil(unknown, "unreviewed analytics events should not be allowed")
    }

    runSuite("AnalyticsEventPolicy meeting_recording_stopped system_stream_present key is not silently filtered") {
        let policy = AnalyticsEventPolicy.policy(forEvent: "meeting_recording_stopped")
        assertEqual(policy?.allowedProperties.contains("system_stream_present"), true, "system_stream_present should be in the allowlist")

        // Verify the key passes sanitization — it must not contain a sensitive fragment
        let sanitized = AnalyticsPayloadSanitizer.sanitizeProperties(
            ["system_stream_present": "true"],
            allowedKeys: ["system_stream_present"]
        )
        assertEqual(sanitized["system_stream_present"], "true", "system_stream_present must survive sanitization — if empty the metric is always missing")
    }
}
