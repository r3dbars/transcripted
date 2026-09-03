import Foundation

private func makeObservabilityEvent(
    message: String = "hello world",
    context: [String: String]? = nil
) -> ObservabilityEvent {
    ObservabilityEvent(
        timestamp: "2026-07-04T00:00:00Z",
        level: "info",
        engine: "parakeet",
        event: "test_event",
        message: message,
        context: context,
        appVersion: "1.0.0",
        osVersion: "26.0"
    )
}

func testLocalObservabilityPayloadSanitizer() {
    runSuite("LocalObservabilityPayloadSanitizer redacts sensitive context keys to a fixed marker") {
        let event = makeObservabilityEvent(context: [
            "audio_device": "MacBook Pro Microphone",
            "transcript_text": "hello there",
            "duration_bucket": "10_29s",
        ])

        let sanitized = LocalObservabilityPayloadSanitizer.sanitize(event)

        assertEqual(sanitized.context?["audio_device"], "[redacted-sensitive-value]", "audio_device is an exact sensitive-context key match")
        assertEqual(sanitized.context?["transcript_text"], "[redacted-sensitive-value]", "transcript_text is an exact sensitive-context key match")
        assertEqual(sanitized.context?["duration_bucket"], "10_29s", "non-sensitive keys with nothing to redact should pass through unchanged")
    }

    runSuite("LocalObservabilityPayloadSanitizer keeps every legacy sensitive key covered by the shared predicate") {
        let legacyExactMatchKeys = [
            "audio_device",
            "audio_path",
            "bundle_id",
            "default_input_device",
            "default_input_name",
            "default_output_device",
            "default_output_name",
            "device_name",
            "download_url",
            "file_path",
            "input_device",
            "input_device_name",
            "input_name",
            "meeting_name",
            "meeting_title",
            "meeting_url",
            "microphone_name",
            "output_device",
            "output_device_name",
            "output_name",
            "prompt_text",
            "raw_url",
            "selected_input_device",
            "source_app",
            "source_app_bundle",
            "source_app_bundle_id",
            "source_app_name",
            "speaker_name",
            "title",
            "transcript",
            "transcript_path",
            "transcript_text",
            "transcript_title",
            "url",
        ]
        let sanitized = LocalObservabilityPayloadSanitizer.sanitize(
            makeObservabilityEvent(
                context: Dictionary(uniqueKeysWithValues: legacyExactMatchKeys.map { ($0, "private") })
            )
        )

        for key in legacyExactMatchKeys {
            assertTrue(
                PayloadSanitizationCore.shouldDrop(
                    key: key,
                    sensitiveFragments: LocalObservabilityPayloadSanitizer.sensitiveKeyFragments
                ),
                "legacy sensitive key \(key) should still be dropped by the shared predicate"
            )
            assertEqual(
                sanitized.context?[key],
                "[redacted-sensitive-value]",
                "legacy sensitive key \(key) should still be redacted by the local sanitizer"
            )
        }
    }

    runSuite("LocalObservabilityPayloadSanitizer matches sensitive context keys case-insensitively but keeps the original key casing") {
        let event = makeObservabilityEvent(context: ["Title": "My Secret Meeting"])

        let sanitized = LocalObservabilityPayloadSanitizer.sanitize(event)

        assertEqual(sanitized.context?["Title"], "[redacted-sensitive-value]", "key matching should lowercase before comparing against the sensitive-context set")
        assertNil(sanitized.context?["title"], "the original key casing should be preserved in the output, not lowercased")
    }

    runSuite("LocalObservabilityPayloadSanitizer runs non-sensitive context values through ObservabilityTextRedactor") {
        let event = makeObservabilityEvent(context: ["note": "https://example.com/foo"])

        let sanitized = LocalObservabilityPayloadSanitizer.sanitize(event)

        assertEqual(sanitized.context?["note"], "[redacted-url]", "non-sensitive values should still be redacted for embedded secrets like raw URLs")
    }

    runSuite("LocalObservabilityPayloadSanitizer always redacts the message field") {
        let rawMessage = "Failed to load /Users/redbars/Library/Application Support/Transcripted/logs/app.jsonl"
        let event = makeObservabilityEvent(message: rawMessage)

        let sanitized = LocalObservabilityPayloadSanitizer.sanitize(event)

        assertEqual(sanitized.message, ObservabilityTextRedactor.redact(rawMessage), "message should always be passed through the shared redactor")
        assertFalse(sanitized.message.contains("/Users/redbars/"), "the redacted message should not retain the raw user path")
    }

    runSuite("LocalObservabilityPayloadSanitizer keeps a nil context nil") {
        let event = makeObservabilityEvent(context: nil)

        let sanitized = LocalObservabilityPayloadSanitizer.sanitize(event)

        assertNil(sanitized.context, "a nil context should stay nil after sanitizing")
    }

    runSuite("LocalObservabilityPayloadSanitizer only returns nil for a context that is empty, not one whose values redacted to a fixed marker") {
        let emptyEvent = makeObservabilityEvent(context: [:])
        let sanitizedEmpty = LocalObservabilityPayloadSanitizer.sanitize(emptyEvent)
        assertNil(sanitizedEmpty.context, "an originally-empty context dictionary should sanitize to nil")

        let allSensitiveEvent = makeObservabilityEvent(context: [
            "audio_device": "MacBook Pro Microphone",
            "title": "Weekly Sync",
        ])
        let sanitizedAllSensitive = LocalObservabilityPayloadSanitizer.sanitize(allSensitiveEvent)
        assertNotNil(sanitizedAllSensitive.context, "a non-empty context should stay non-nil even when every value collapses to the redacted marker")
        assertEqual(sanitizedAllSensitive.context?.count, 2, "keys are preserved even though every value was redacted")
    }

    runSuite("LocalObservabilityPayloadSanitizer keeps coarse device-class and audio-signal facts readable") {
        // These keys sit next to `default_input_class` / `route_shape` on
        // every dictation record and carry the same coarse enum, boolean, or
        // number. Blanking them because the key contains "device" or "audio"
        // left "[redacted-sensitive-value]" in events.jsonl while the
        // sibling keys said "built_in".
        let event = makeObservabilityEvent(context: [
            "input_device_class": "built_in",
            "output_device_class": "bluetooth",
            "system_output_device_class": "external",
            "audio_has_signal": "true",
            "audio_gaps": "2",
            "device_switches": "1",
            "mic_file_present": "true",
            "system_file_present": "false",
            "audio_duration_s": "8.8",
            "audio_peak": "0.31",
            "audio_rms": "0.012",
            "audio_active_ratio": "0.42",
        ])

        let sanitized = LocalObservabilityPayloadSanitizer.sanitize(event)

        for (key, value) in event.context ?? [:] {
            assertEqual(sanitized.context?[key], value, "categorical value under \(key) should survive")
        }
    }

    runSuite("LocalObservabilityPayloadSanitizer still redacts raw labels written under a categorical key") {
        let event = makeObservabilityEvent(context: [
            "input_device_class": "MacBook Pro Microphone",
            "output_device_class": "Justin's AirPods Pro",
            "audio_peak": "/Users/someone/Music/take.wav",
            "audio_has_signal": "True Tone Mic",
            "audio_device": "built_in",
            "default_input_device": "built_in",
            "selected_input_device": "bluetooth",
        ])

        let sanitized = LocalObservabilityPayloadSanitizer.sanitize(event)

        for key in event.context?.keys ?? Dictionary<String, String>().keys {
            assertEqual(
                sanitized.context?[key],
                "[redacted-sensitive-value]",
                "\(key) must stay redacted: either the value is not categorical or the key is a raw device label"
            )
        }
    }
}
