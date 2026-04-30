import Foundation

func testSupportDiagnosticsBundle() {
    runSuite("SupportDiagnosticsBundle text excludes obvious sensitive values") {
        let snapshot = SupportDiagnosticsSnapshot(
            appVersion: "1.2.3",
            buildVersion: "456",
            osVersion: "Version 26.0",
            crashReportingAvailable: true,
            crashReportingEnabled: true,
            analyticsAvailable: true,
            analyticsEnabled: false,
            microphoneStatus: "authorized",
            systemAudioRecordingGranted: true,
            pastebackGranted: true,
            calendarGranted: false,
            audioRoute: [
                "input_device_class": "bluetooth",
                "input_rate_hz": "24000",
                "route_shape": "bluetooth_input_to_built_in_output",
            ],
            runtime: [
                "session_kind": "dictation",
                "session_stage": "recording",
                "session_active": "true",
            ],
            meetingState: "ready",
            meetingRecording: false,
            meetingDurationBucket: "lt_10s",
            recentLogLines: [
                "Opened /Users/redbars/Library/Application Support/Transcripted/logs/app.jsonl",
                "Email person@example.com should not leak",
            ]
        )

        let text = SupportDiagnosticsBundle.text(
            snapshot: snapshot,
            now: Date(timeIntervalSince1970: 100)
        )

        assertTrue(text.contains("Version: 1.2.3"), "diagnostics should include app version")
        assertTrue(text.contains("input_device_class: bluetooth"), "diagnostics should include coarse route facts")
        assertTrue(text.contains("session_stage: recording"), "diagnostics should include runtime session stage")
        assertFalse(text.contains("/Users/redbars"), "diagnostics should redact home paths")
        assertFalse(text.contains("person@example.com"), "diagnostics should redact emails")
        assertFalse(text.contains("Application Support/Transcripted"), "diagnostics should redact app support paths")
    }

    runSuite("SupportDiagnosticsBundle Sentry context avoids sanitizer-dropped audio keys") {
        let snapshot = SupportDiagnosticsSnapshot(
            appVersion: "1.2.3",
            buildVersion: "456",
            osVersion: "Version 26.0",
            crashReportingAvailable: true,
            crashReportingEnabled: true,
            analyticsAvailable: true,
            analyticsEnabled: true,
            microphoneStatus: "authorized",
            systemAudioRecordingGranted: true,
            pastebackGranted: true,
            calendarGranted: true,
            audioRoute: ["input_device_class": "bluetooth"],
            runtime: ["session_stage": "recording"],
            meetingState: "recording",
            meetingRecording: true,
            meetingDurationBucket: "2_9m",
            recentLogLines: []
        )

        let context = SupportDiagnosticsBundle.sentryContext(snapshot: snapshot)
        let sanitized = SentryPayloadSanitizer.sanitizeContext(context)

        assertEqual(sanitized["route_input_device_class"], "bluetooth", "route context should survive Sentry key sanitization")
        assertNil(sanitized["audio_input_device_class"], "support diagnostics should not use audio-prefixed Sentry keys")
    }
}
