import Foundation

func testTimelinePreferences() {
    runSuite("TimelinePreferences defaults to opt-in timeline capture") {
        let (defaults, suiteName) = makeTimelineDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertFalse(TimelinePreferences.isEnabled(userDefaults: defaults), "timeline capture should default off")
        assertEqual(TimelinePreferences.provider(userDefaults: defaults), .localFoundation, "local provider should be the default")
        assertEqual(TimelinePreferences.ollamaEndpoint(userDefaults: defaults), "http://localhost:1234", "Ollama-compatible endpoint should default to the local server")
        assertEqual(TimelinePreferences.storageCapBytes(userDefaults: defaults), 5_368_709_120, "timeline storage cap should default to 5 GB")
        assertEqual(TimelinePreferences.blockedBundleIDs(userDefaults: defaults), [], "timeline blocklist should start empty")
        assertFalse(TimelinePreferences.onboardingCompleted(userDefaults: defaults), "timeline onboarding should start incomplete")
    }

    runSuite("TimelinePreferences persists timeline settings") {
        let (defaults, suiteName) = makeTimelineDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        TimelinePreferences.setEnabled(true, userDefaults: defaults)
        TimelinePreferences.setProvider(.ollama, userDefaults: defaults)
        TimelinePreferences.setOllamaEndpoint("http://127.0.0.1:11434", userDefaults: defaults)
        TimelinePreferences.setStorageCapBytes(1234, userDefaults: defaults)
        TimelinePreferences.setBlockedBundleIDs([" com.apple.Safari ", "", "com.openai.chat"], userDefaults: defaults)
        TimelinePreferences.setOnboardingCompleted(true, userDefaults: defaults)

        assertTrue(TimelinePreferences.isEnabled(userDefaults: defaults), "enabled state should round-trip")
        assertEqual(TimelinePreferences.provider(userDefaults: defaults), .ollama, "provider should round-trip")
        assertEqual(TimelinePreferences.ollamaEndpoint(userDefaults: defaults), "http://127.0.0.1:11434", "endpoint should round-trip")
        assertEqual(TimelinePreferences.storageCapBytes(userDefaults: defaults), 1234, "storage cap should round-trip")
        assertEqual(TimelinePreferences.blockedBundleIDs(userDefaults: defaults), ["com.apple.Safari", "com.openai.chat"], "blocklist should trim and drop empty values")
        assertTrue(TimelinePreferences.onboardingCompleted(userDefaults: defaults), "onboarding state should round-trip")
    }

    runSuite("TimelinePreferences falls back from invalid stored values") {
        let (defaults, suiteName) = makeTimelineDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("custom", forKey: TimelinePreferences.providerKey)
        defaults.set("   ", forKey: TimelinePreferences.ollamaEndpointKey)
        defaults.set("not-json".data(using: .utf8), forKey: TimelinePreferences.blockedBundleIDsKey)

        assertEqual(TimelinePreferences.provider(userDefaults: defaults), .localFoundation, "unknown providers should fall back to local")
        assertEqual(TimelinePreferences.ollamaEndpoint(userDefaults: defaults), "http://localhost:1234", "blank endpoint should fall back")
        assertEqual(TimelinePreferences.blockedBundleIDs(userDefaults: defaults), [], "invalid blocklist JSON should fall back")
    }
}

private func makeTimelineDefaults() -> (UserDefaults, String) {
    let suiteName = "TimelinePreferencesTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
}
