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
            storage: [
                "model_cache_total": "3 GB",
                "known_stale_model_count": "2",
            ],
            meetingState: "ready",
            meetingRecording: false,
            meetingDurationBucket: "lt_10s",
            meetingDisplayStatus: "finishing",
            speakerReviewPending: true,
            queuedMeetingCount: 1,
            meetingShortcut: "⌥C",
            reliabilityPacketCount: 1
        )

        let text = SupportDiagnosticsBundle.text(
            snapshot: snapshot,
            now: Date(timeIntervalSince1970: 100)
        )

        assertTrue(text.contains("Version: 1.2.3"), "diagnostics should include app version")
        assertTrue(text.contains("input_device_class: bluetooth"), "diagnostics should include coarse route facts")
        assertTrue(text.contains("session_stage: recording"), "diagnostics should include runtime session stage")
        assertTrue(text.contains("model_cache_total: 3 GB"), "diagnostics should include coarse model cache size")
        assertTrue(text.contains("Display status: finishing"), "diagnostics should include meeting display status")
        assertTrue(text.contains("Speaker review pending: true"), "diagnostics should include pending speaker review state")
        assertTrue(text.contains("Queued meetings: 1"), "diagnostics should include queued meeting count")
        assertTrue(text.contains("Meeting shortcut: ⌥C"), "diagnostics should include the active meeting shortcut")
        assertFalse(text.contains("/Users/redbars"), "diagnostics should redact home paths")
        assertFalse(text.contains("MacBook Pro Microphone"), "diagnostics should redact raw route device names")
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
            storage: ["known_stale_model_count": "1"],
            meetingState: "recording",
            meetingRecording: true,
            meetingDurationBucket: "2_9m",
            meetingDisplayStatus: "transcribing",
            speakerReviewPending: false,
            queuedMeetingCount: 2,
            meetingShortcut: "⌥M",
            reliabilityPacketCount: 1
        )

        let context = SupportDiagnosticsBundle.sentryContext(snapshot: snapshot)
        let sanitized = SentryPayloadSanitizer.sanitizeContext(context)

        assertEqual(sanitized["route_input_device_class"], "bluetooth", "route context should survive Sentry key sanitization")
        assertEqual(sanitized["storage_known_stale_model_count"], "1", "storage context should survive Sentry key sanitization")
        assertEqual(sanitized["meeting_display_status"], "transcribing", "display status should survive Sentry key sanitization")
        assertEqual(sanitized["meeting_review_pending"], "false", "speaker review state should survive under a privacy-safe key")
        assertEqual(sanitized["queued_meeting_count"], "2", "queued meeting count should survive Sentry key sanitization")
        assertEqual(sanitized["meeting_shortcut"], "⌥M", "meeting shortcut should survive Sentry key sanitization")
        assertEqual(sanitized["reliability_packet_count"], "1", "support diagnostics should include packet count")
        assertEqual(sanitized["system_recording_granted"], "true", "system recording permission should survive Sentry key sanitization")
        assertNil(sanitized["system_audio_recording_granted"], "support diagnostics should avoid audio-prefixed permission keys")
        assertNil(sanitized["audio_input_device_class"], "support diagnostics should not use audio-prefixed Sentry keys")
    }

    runSuite("SupportDiagnosticsBundle Sentry context is positive-allowlist gated") {
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
            // Adversarial injection: each entry hides a sensitive value behind a
            // route_/runtime_/storage_ prefix or an off-allowlist key.
            audioRoute: [
                "input_device_class": "bluetooth",
                "raw_url": "https://meet.example.com/private-room",
                "audio_device": "MacBook Pro Microphone",
            ],
            runtime: [
                "session_stage": "recording",
                "file_path": "/Users/redbars/private-runtime.json",
                "transcript_title": "Private Customer Call",
                "speaker_name": "Alice Customer",
                "email": "person@example.com",
            ],
            storage: [
                "known_stale_model_count": "1",
            ],
            meetingState: "recording",
            meetingRecording: true,
            meetingDurationBucket: "2_9m",
            meetingDisplayStatus: "transcribing",
            speakerReviewPending: false,
            queuedMeetingCount: 2,
            meetingShortcut: "⌥M",
            reliabilityPacketCount: 1
        )

        let rawContext = SupportDiagnosticsBundle.sentryContext(snapshot: snapshot)
        // Mirror the real send path: positive allowlist, then the Sentry
        // payload sanitizer (fragment drop + redaction) as defense-in-depth.
        let allowlisted = SupportDiagnosticsBundle.allowlistedSentryContext(rawContext)
        let sent = SentryPayloadSanitizer.sanitizeContext(allowlisted)

        // Known-safe coarse keys survive.
        assertEqual(sent["app_version"], "1.2.3", "coarse app version should survive the allowlist")
        assertEqual(sent["meeting_state"], "recording", "coarse meeting state should survive the allowlist")
        assertEqual(sent["route_input_device_class"], "bluetooth", "coarse route facts should survive the allowlist")
        assertEqual(sent["runtime_session_stage"], "recording", "coarse runtime session stage should survive the allowlist")
        assertEqual(sent["storage_known_stale_model_count"], "1", "coarse storage facts should survive the allowlist")
        assertEqual(sent["reliability_packet_count"], "1", "the coarse packet count should survive the allowlist")

        // The free-text reliability packet blob must never leave under its key.
        assertNil(rawContext["latest_reliability_packet"], "sentryContext should no longer emit the free-text reliability packet blob")
        assertNil(allowlisted["latest_reliability_packet"], "the allowlist should drop the free-text reliability packet blob")
        assertNil(sent["latest_reliability_packet"], "the free-text reliability packet blob must not reach Sentry")

        // Sensitive values hidden behind prefixed keys must be dropped by the
        // downstream fragment-drop sanitizer.
        assertNil(sent["route_raw_url"], "raw route URLs must not reach Sentry even behind a route_ prefix")
        assertNil(sent["route_audio_device"], "raw device names must not reach Sentry even behind a route_ prefix")
        assertNil(sent["runtime_file_path"], "runtime file paths must not reach Sentry even behind a runtime_ prefix")
        assertNil(sent["runtime_transcript_title"], "runtime transcript titles must not reach Sentry even behind a runtime_ prefix")
        assertNil(sent["runtime_speaker_name"], "runtime speaker names must not reach Sentry even behind a runtime_ prefix")
        assertNil(sent["runtime_email"], "runtime emails must not reach Sentry even behind a runtime_ prefix")

        // Defense-in-depth: any value that still slipped through must not carry
        // the raw injected secrets.
        for value in sent.values {
            assertFalse(value.contains("/Users/redbars"), "no allowlisted value should retain a home path")
            assertFalse(value.contains("person@example.com"), "no allowlisted value should retain an email")
            assertFalse(value.contains("Private Customer Call"), "no allowlisted value should retain a meeting title")
            assertFalse(value.contains("https://meet.example.com"), "no allowlisted value should retain a raw URL")
        }
    }

    runSuite("SupportDiagnosticsBundle allowlist drops unknown off-allowlist keys") {
        let injected = [
            "app_version": "1.2.3",
            "route_input_device_class": "bluetooth",
            "latest_reliability_packet": "free text with /Users/redbars/private.txt",
            "device_name": "Justin's MacBook Pro",
            "meeting_title": "Private Customer Call",
            "operator_email": "person@example.com",
            "arbitrary_blob": "anything not on the allowlist",
        ]

        let allowlisted = SupportDiagnosticsBundle.allowlistedSentryContext(injected)

        assertEqual(allowlisted["app_version"], "1.2.3", "static allowlisted keys should survive")
        assertEqual(allowlisted["route_input_device_class"], "bluetooth", "bucketed prefix keys should survive")
        assertNil(allowlisted["latest_reliability_packet"], "free-text reliability blob should be dropped")
        assertNil(allowlisted["device_name"], "off-allowlist device keys should be dropped")
        assertNil(allowlisted["meeting_title"], "off-allowlist title keys should be dropped")
        assertNil(allowlisted["operator_email"], "off-allowlist email keys should be dropped")
        assertNil(allowlisted["arbitrary_blob"], "arbitrary off-allowlist keys should be dropped")
    }
}
