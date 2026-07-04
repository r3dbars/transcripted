import Foundation

func testTimelinePreferences() {
    runSuite("TimelinePreferences defaults keep timeline opt-in") {
        let defaults = UserDefaults(suiteName: "TimelinePreferencesTests.defaults.\(UUID().uuidString)")!

        assertEqual(TimelinePreferences.isEnabled(userDefaults: defaults), false, "timeline must default off")
        assertEqual(TimelinePreferences.hasCompletedOnboarding(userDefaults: defaults), false, "timeline onboarding must default incomplete")
        assertEqual(TimelinePreferences.provider(userDefaults: defaults), .localFoundation, "provider should default local")
        assertEqual(TimelinePreferences.ollamaEndpoint(userDefaults: defaults), TimelinePreferences.defaultOllamaEndpoint, "endpoint should have a local default")
        assertEqual(TimelinePreferences.storageCapBytes(userDefaults: defaults), TimelinePreferences.defaultStorageCapBytes, "storage cap should default to 5 GB")
        assertEqual(TimelinePreferences.blockedBundleIDs(userDefaults: defaults), [], "blocklist should default empty")
    }

    runSuite("TimelinePreferences sanitizes user-controlled lists") {
        let defaults = UserDefaults(suiteName: "TimelinePreferencesTests.blocklist.\(UUID().uuidString)")!
        TimelinePreferences.setBlockedBundleIDs(
            [" com.apple.Safari ", "", "com.tinyspeck.slackmacgap", "com.apple.Safari"],
            userDefaults: defaults
        )

        assertEqual(
            TimelinePreferences.blockedBundleIDs(userDefaults: defaults),
            ["com.apple.Safari", "com.tinyspeck.slackmacgap"],
            "blocked bundle IDs should trim, dedupe, and sort"
        )
    }

    runSuite("TimelinePreferences clamps storage caps") {
        let defaults = UserDefaults(suiteName: "TimelinePreferencesTests.storage.\(UUID().uuidString)")!
        TimelinePreferences.setStorageCapBytes(1, userDefaults: defaults)
        assertEqual(TimelinePreferences.storageCapBytes(userDefaults: defaults), TimelinePreferences.minimumStorageCapBytes, "storage cap should clamp low")

        TimelinePreferences.setStorageCapBytes(Int64.max, userDefaults: defaults)
        assertEqual(TimelinePreferences.storageCapBytes(userDefaults: defaults), TimelinePreferences.maximumStorageCapBytes, "storage cap should clamp high")
    }
}
