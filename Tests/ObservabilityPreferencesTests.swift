import Foundation

func testObservabilityPreferences() {
    runSuite("AnalyticsPreferences defaults to enabled until the user chooses otherwise") {
        let suiteName = "ObservabilityPreferencesTests.analytics.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertTrue(AnalyticsPreferences.isEnabled(userDefaults: defaults), "analytics should start enabled by default")

        AnalyticsPreferences.setEnabled(false, userDefaults: defaults)
        assertFalse(AnalyticsPreferences.isEnabled(userDefaults: defaults), "analytics should stay off after an explicit opt-out")
    }

    runSuite("CrashReportingPreferences defaults to enabled until the user chooses otherwise") {
        let suiteName = "ObservabilityPreferencesTests.crash.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertTrue(CrashReportingPreferences.isEnabled(userDefaults: defaults), "crash reporting should start enabled by default")

        CrashReportingPreferences.setEnabled(false, userDefaults: defaults)
        assertFalse(CrashReportingPreferences.isEnabled(userDefaults: defaults), "crash reporting should stay off after an explicit opt-out")
    }
}
