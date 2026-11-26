import Foundation

func testWritingAnalytics() {
    let allApps = WritingAnalytics.Setup(
        saveEnabled: true,
        appScope: .all
    )

    runSuite("WritingAnalytics setup properties carry exactly the reviewed keys") {
        let setup = WritingAnalytics.setupProperties(
            .init(saveEnabled: false, appScope: .picked)
        )
        assertEqual(
            setup,
            [
                "save_enabled": "false",
                "autocomplete_enabled": "false",
                "app_scope": "picked",
                "model_choice": "none",
            ],
            "setup completion carries the four reviewed setup keys with autocomplete off"
        )
        assertEqual(WritingAnalytics.AppScope.all.rawValue, "all", "all apps")
        assertEqual(WritingAnalytics.AppScope.picked.rawValue, "picked", "only apps I pick")
    }

    runSuite("WritingAnalytics properties match the allowlist and survive the sanitizer") {
        let setup = WritingAnalytics.setupProperties(allApps)
        let event = "writing_setup_completed"
        let policy = AnalyticsEventPolicy.policy(forEvent: event)
        assertEqual(
            policy?.allowedProperties,
            Set(setup.keys),
            "\(event) allows exactly the keys WritingAnalytics sends"
        )
        for key in setup.keys {
            for fragment in PayloadSanitizationCore.baseSensitiveKeyFragments {
                assertFalse(key.contains(fragment), "\(event).\(key) must not contain \(fragment)")
            }
        }
        let sanitized = AnalyticsPayloadSanitizer.sanitizeProperties(
            setup,
            allowedKeys: policy?.allowedProperties ?? []
        )
        assertEqual(sanitized, setup, "\(event) reaches PostHog unchanged")
    }
}
