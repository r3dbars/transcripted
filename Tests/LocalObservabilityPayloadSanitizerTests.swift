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

    runSuite("LocalObservabilityPayloadSanitizer keeps numeric measurements under sensitive-looking keys") {
        // Every one of these matches the "audio" fragment, so before the
        // measurement escape the whole dictation-start stage breakdown was
        // written to disk as the redaction marker.
        let event = makeObservabilityEvent(context: [
            "audio_engine_prepare_ms": "12",
            "audio_engine_start_ms": "84",
            "audio_tap_install_ms": "3",
            "audio_input_total_ms": "41",
            "audio_start_work_ms": "128",
            "audio_duration_s": "11.75",
            "audio_input_override_settle_sleep_ms": "0",
        ])

        let sanitized = LocalObservabilityPayloadSanitizer.sanitize(event)

        assertEqual(sanitized.context?["audio_engine_prepare_ms"], "12", "a bare integer under a _ms key should survive")
        assertEqual(sanitized.context?["audio_engine_start_ms"], "84", "a bare integer under a _ms key should survive")
        assertEqual(sanitized.context?["audio_tap_install_ms"], "3", "a bare integer under a _ms key should survive")
        assertEqual(sanitized.context?["audio_input_total_ms"], "41", "a bare integer under a _ms key should survive")
        assertEqual(sanitized.context?["audio_start_work_ms"], "128", "a bare integer under a _ms key should survive")
        assertEqual(sanitized.context?["audio_duration_s"], "11.75", "a bare decimal under a _s key should survive")
        assertEqual(sanitized.context?["audio_input_override_settle_sleep_ms"], "0", "zero is a real measurement, not a missing one")
    }

    runSuite("LocalObservabilityPayloadSanitizer still redacts non-numeric values under measurement-suffixed keys") {
        // The suffix alone must never be enough — otherwise a device label
        // under a _ms-suffixed key would leak through the escape.
        let event = makeObservabilityEvent(context: [
            "audio_device_ms": "MacBook Pro Microphone",
            "transcript_count": "hello there",
            "audio_path_s": "/Users/someone/Music/take.wav",
            "audio_engine_start_ms": "84ms",
            "audio_gap_ms": "1e3",
            "audio_offset_ms": "1,000",
            "audio_skew_ms": "",
        ])

        let sanitized = LocalObservabilityPayloadSanitizer.sanitize(event)

        assertEqual(sanitized.context?["audio_device_ms"], "[redacted-sensitive-value]", "a device label is still redacted under a measurement suffix")
        assertEqual(sanitized.context?["transcript_count"], "[redacted-sensitive-value]", "transcript text is still redacted under a measurement suffix")
        assertEqual(sanitized.context?["audio_path_s"], "[redacted-sensitive-value]", "a file path is still redacted under a measurement suffix")
        assertEqual(sanitized.context?["audio_engine_start_ms"], "[redacted-sensitive-value]", "a number with a unit suffix is not a bare number")
        assertEqual(sanitized.context?["audio_gap_ms"], "[redacted-sensitive-value]", "exponent notation is not accepted as a bare number")
        assertEqual(sanitized.context?["audio_offset_ms"], "[redacted-sensitive-value]", "grouped digits are not accepted as a bare number")
        assertEqual(sanitized.context?["audio_skew_ms"], "[redacted-sensitive-value]", "an empty value is not a measurement")
    }

    runSuite("LocalObservabilityPayloadSanitizer measurement escape does not apply to non-measurement keys") {
        let event = makeObservabilityEvent(context: [
            "speaker_name": "42",
            "meeting_title": "2026",
            "audio_device": "1.5",
        ])

        let sanitized = LocalObservabilityPayloadSanitizer.sanitize(event)

        assertEqual(sanitized.context?["speaker_name"], "[redacted-sensitive-value]", "a numeric-looking value under an identifier key is still redacted")
        assertEqual(sanitized.context?["meeting_title"], "[redacted-sensitive-value]", "a numeric-looking title is still redacted")
        assertEqual(sanitized.context?["audio_device"], "[redacted-sensitive-value]", "a numeric-looking device value is still redacted")
    }

    runSuite("LocalObservabilityPayloadSanitizer measurement escape accepts signed and fractional values") {
        let event = makeObservabilityEvent(context: [
            "audio_drift_ms": "-3",
            "audio_offset_ms": "+7",
            "audio_ratio_s": ".5",
            "audio_input_rate_hz": "48000",
            "audio_buffer_bytes": "262144",
            "rtf": "0.029",
        ])

        let sanitized = LocalObservabilityPayloadSanitizer.sanitize(event)

        assertEqual(sanitized.context?["audio_drift_ms"], "-3", "a negative measurement should survive")
        assertEqual(sanitized.context?["audio_offset_ms"], "+7", "an explicitly positive measurement should survive")
        assertEqual(sanitized.context?["audio_ratio_s"], ".5", "a leading-dot decimal should survive")
        assertEqual(sanitized.context?["audio_input_rate_hz"], "48000", "a _hz measurement should survive")
        assertEqual(sanitized.context?["audio_buffer_bytes"], "262144", "a _bytes measurement should survive")
        assertEqual(sanitized.context?["rtf"], "0.029", "the bare rtf key should survive")
    }
}
