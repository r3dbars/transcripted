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
                "audio_device": "MacBook Pro Microphone",
                "input_device_class": "bluetooth",
                "input_rate_hz": "24000",
                "raw_url": "https://meet.example.com/private-room",
                "route_shape": "bluetooth_input_to_built_in_output",
            ],
            runtime: [
                "file_path": "/Users/redbars/private-runtime.json",
                "session_kind": "dictation",
                "session_stage": "recording",
                "session_active": "true",
                "transcript_title": "Private Customer Call",
            ],
            meetingState: "ready",
            meetingRecording: false,
            meetingDurationBucket: "lt_10s",
            reliabilityPackets: [
                "2026-05-03T01:15:11Z meeting.stop recovered event=meeting_recording_stopped route_change_count_bucket=2_3 path=/Users/redbars/private.txt"
            ],
            recentLogLines: [
                "Opened /Users/redbars/Library/Application Support/Transcripted/logs/app.jsonl",
                "DIAG | capture.dictation_toggle_requested | source_app_bundle_id=com.openai.codex source_app_name=Codex trigger=physical_key",
                "DIAG | dictation.dictation_started | audio_device=MacBook Pro Microphone route_shape=built_in_input_to_built_in_output",
                "DICTATION | started after 120ms wait (parakeet, MacBook Pro Microphone)",
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
        assertTrue(text.contains("meeting.stop recovered"), "diagnostics should include recent reliability packet summaries")
        assertFalse(text.contains("/Users/redbars"), "diagnostics should redact home paths")
        assertFalse(text.contains("person@example.com"), "diagnostics should redact emails")
        assertFalse(text.contains("Application Support/Transcripted"), "diagnostics should redact app support paths")
        assertFalse(text.contains("com.openai.codex"), "diagnostics should redact source app bundle IDs from recent logs")
        assertFalse(text.contains("source_app_name=Codex"), "diagnostics should redact source app names from recent logs")
        assertFalse(text.contains("MacBook Pro Microphone"), "diagnostics should redact raw device names from recent logs")
        assertFalse(text.contains("https://meet.example.com/private-room"), "diagnostics should redact raw route URLs")
        assertFalse(text.contains("private-runtime.json"), "diagnostics should redact runtime file paths")
        assertFalse(text.contains("Private Customer Call"), "diagnostics should redact runtime transcript titles")
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
            reliabilityPackets: [
                "2026-05-03T01:15:11Z meeting.stop recovered event=meeting_recording_stopped"
            ],
            recentLogLines: []
        )

        let context = SupportDiagnosticsBundle.sentryContext(snapshot: snapshot)
        let sanitized = SentryPayloadSanitizer.sanitizeContext(context)

        assertEqual(sanitized["route_input_device_class"], "bluetooth", "route context should survive Sentry key sanitization")
        assertEqual(sanitized["reliability_packet_count"], "1", "support diagnostics should include packet count")
        assertNil(sanitized["audio_input_device_class"], "support diagnostics should not use audio-prefixed Sentry keys")
    }
}
