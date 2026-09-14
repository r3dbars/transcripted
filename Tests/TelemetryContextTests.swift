import Foundation

func testTelemetryContext() {
    let permissions = ["mic_permission_granted": "true", "screen_permission_granted": "false", "accessibility_permission_granted": "true"]
    runSuite("Failures preserve identical safe metadata across both sinks") {
        let correlation = UUID().uuidString
        let properties = TelemetryContext.enrich(event: "meeting_recording_start_failed", properties: [
            "failure_kind": "mic_unavailable", "start_failure_stage": "microphone", "correlation_id": correlation,
            "session_id": UUID().uuidString, "input_device_class": "bluetooth", "output_device_class": "built_in",
            "selection_reason": "preferredBuiltInForBluetoothHeadset", "trigger": "hotkey",
            "transcript_text": "Private content", "speaker_name": "Private Person", "audio_path": "/private/audio.wav",
        ], environment: permissions)
        let analytics = AnalyticsPayloadSanitizer.sanitizeProperties(properties, allowedKeys: TelemetryContext.keys)
        let sentry = SentryEventPolicy.diagnosticTags(forEngine: "meeting", event: "meeting_start_failed", context: properties)
        for key in TelemetryContext.keys.subtracting(["quality_reason", "capture_outcome"]) {
            assertNotNil(analytics[key], "failure has required field \(key)")
            assertEqual(sentry[key], analytics[key], "same \(key) reaches both systems")
        }
        assertEqual(sentry["correlation_id"], correlation, "join survives filtering")
        assertEqual(sentry["failure_stage"], "microphone", "preserve precise start stage")
        assertFalse(analytics.values.contains("Private content"), "content is excluded")
        assertNil(sentry["audio_path"], "audio paths are excluded")
    }
    runSuite("Health and friction distinguish unknown metadata from success") {
        let health = TelemetryContext.enrich(event: "meeting_capture_health_snapshot", properties: [:], environment: permissions)
        assertEqual(health["quality_reason"], "unknown", "missing measurements never imply good health")
        assertEqual(health["capture_outcome"], "unknown", "missing outcome never implies completion")
        assertEqual(health["failure_kind"], "unknown", "unmeasured health does not claim no failure")
        for outcome in ["no_audio", "timed_out", "stop_timed_out"] {
            let failed = TelemetryContext.enrich(event: "meeting_capture_health_snapshot", properties: ["capture_outcome": outcome], environment: permissions)
            assertEqual(failed["failure_kind"], outcome, "failed outcome has a stable failure code")
            assertEqual(failed["failure_stage"], "capture_stop", "failed outcome has a stage")
        }
        let friction = TelemetryContext.enrich(event: "product_friction_observed", properties: ["stage": "dictation_start", "result": "started"], environment: permissions)
        assertEqual(friction["failure_kind"], "none", "normal friction observations are not failures")
        assertEqual(friction["failure_stage"], "dictation_start", "stage is explicit")
    }
    runSuite("Free text cannot impersonate shared taxonomy or identifiers") {
        let properties = TelemetryContext.enrich(event: "dictation_start_failed", properties: [
            "session_id": "private@example.com", "correlation_id": "private words", "failure_kind": "Private transcript words",
            "input_device_class": "Jane's AirPods", "trigger": "Private meeting title",
        ], environment: permissions)
        assertNotNil(UUID(uuidString: properties["session_id"]!), "session fallback is a UUID")
        assertNotNil(UUID(uuidString: properties["correlation_id"]!), "correlation fallback is a UUID")
        assertEqual(properties["input_device_class"], "unknown", "device names never become device classes")
        assertEqual(properties["trigger"], "unknown", "free text never becomes a trigger")
        assertEqual(properties["failure_kind"], "dictation_start_failed", "failure fallback is a code")
    }
}
