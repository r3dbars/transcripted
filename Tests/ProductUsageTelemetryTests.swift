import Foundation

func testProductUsageTelemetry() {
    runSuite("Product navigation separates explicit controls from automatic presentation") {
        for source in ProductUsageTelemetry.NavigationSource.allCases {
            let properties = ProductUsageTelemetry.navigationProperties(destination: .meetings, previous: .today, source: source)
            let expected = source == .appLaunch ? "automatic" : (source == .unknown ? "unknown" : "user")
            assertEqual(properties["initiation"], expected, "only known control sources count as deliberate")
            assertEqual(properties["destination"], "meetings", "canonical destination does not inherit the legacy home ambiguity")
            assertEqual(properties["previous_destination"], "today", "navigation path has a bounded origin")
            let sanitized = AnalyticsPayloadSanitizer.sanitizeProperties(properties, allowedKeys: Set(properties.keys))
            assertEqual(sanitized, properties, "every bounded navigation property survives privacy sanitization")
        }
        assertEqual(TranscriptedSettingsPage.home.telemetryDestination, .meetings, "legacy home page is Meetings")
        assertEqual(TranscriptedSettingsPage.today.telemetryDestination, .today, "Open Transcripted lands on Today")
        assertNil(ProductUsageTelemetry.NavigationSource(rawValue: "private window title"), "unknown source cannot enter typed properties")
    }

    runSuite("Saved result copy emits the clipboard outcome after the write") {
        for succeeds in [false, true] {
            var didWrite = false
            var emissions: [[String: String]] = []
            let result = ProductUsageTelemetry.copy(kind: .dictation, surface: .dictations, artifactDate: nil, write: {
                didWrite = true
                return succeeds
            }, emit: { properties in
                assertTrue(didWrite, "attempt must complete before outcome is emitted")
                emissions.append(properties)
            })
            assertEqual(result, succeeds, "clipboard failure is not success")
            assertEqual(emissions.count, 1, "each write has one terminal outcome")
            assertEqual(emissions.first?["result"], succeeds ? "success" : "failed", "telemetry reports the actual clipboard outcome")
            assertEqual(emissions.first?["artifact_kind"], "dictation", "saved kind is bounded")
        }
    }

    runSuite("Saved result outcomes contain only categorical metadata") {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let properties = ProductUsageTelemetry.resultProperties(
            kind: .meeting, action: .preview, surface: .meetings, succeeded: true,
            artifactDate: now.addingTimeInterval(-25 * 3600), now: now
        )
        assertEqual(properties["artifact_age_bucket"], "24_48h", "reuse age is bucketed rather than sent as a timestamp")
        assertEqual(Set(properties.keys), Set(["artifact_kind", "action_kind", "surface", "result", "artifact_age_bucket"]), "no artifact identity or content is included")
        let sanitized = AnalyticsPayloadSanitizer.sanitizeProperties(properties, allowedKeys: Set(properties.keys))
        assertEqual(sanitized, properties, "all approved result fields survive sanitization")
        for event in ["product_navigation", "saved_result_action"] {
            assertNotNil(AnalyticsEventPolicy.policy(forEvent: event), "new event must be registered")
        }
    }
}
