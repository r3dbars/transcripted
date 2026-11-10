import Foundation

/// Calls only the actual resource-backed policy and pure sanitizer. No
/// AnalyticsReporter, app delegate, permission enrichment or defaults access.
func testMenuBarAnalyticsSchema() {
    runSuite("Menu opening keeps its five useful event properties after retiring the always-unknown field") {
        guard let policy = AnalyticsEventPolicy.policy(forEvent: "menu_bar_opened") else {
            assertTrue(false, "the menu-open event must remain registered")
            return
        }
        assertEqual(policy.allowedProperties, Set([
            "dictation_ready", "entrypoint", "meeting_recording_ready", "model_state", "update_state"
        ]))
    }

    runSuite("The actual allowlist sanitizer rejects the retired property while retaining menu and common metadata") {
        guard let policy = AnalyticsEventPolicy.policy(forEvent: "menu_bar_opened") else {
            assertTrue(false, "the resource-backed menu policy must load")
            return
        }
        let useful = [
            "dictation_ready": "true",
            "entrypoint": "status_item",
            "meeting_recording_ready": "false",
            "model_state": "ready",
            "update_state": "up_to_date",
        ]
        var expected = useful
        expected["app_version"] = "1.2.3"
        var input = expected
        input["recent_meetings_available"] = "unknown"
        input["synthetic_unreviewed"] = "synthetic"
        // Same immutable common-key set the reporter unions into its event
        // allowlist. Never call enrich(), which reads actual permissions.
        let commonKeys = PayloadSanitizationCore.commonTelemetryKeys
        assertFalse(commonKeys.contains("recent_meetings_available"))
        assertTrue(commonKeys.contains("app_version"))
        let output = AnalyticsPayloadSanitizer.sanitizeProperties(
            input, allowedKeys: policy.allowedProperties.union(commonKeys)
        )
        assertEqual(output, expected, "retirement must preserve all five useful fields and approved common metadata")
        assertNil(output["recent_meetings_available"], "the old constant must be rejected by the actual policy boundary")
        assertNil(output["synthetic_unreviewed"], "unreviewed keys must still fail closed")
    }
}
