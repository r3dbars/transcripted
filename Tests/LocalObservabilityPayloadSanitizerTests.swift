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
}
