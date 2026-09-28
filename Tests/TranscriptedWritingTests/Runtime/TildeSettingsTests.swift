import Foundation
import Testing
@testable import TranscriptedWritingRuntime

@Suite("Tilde settings")
struct TildeSettingsTests {
    private func makeSettings() -> (TildeSettings, UserDefaults) {
        let keyboardName = "tilde.tests.keyboard.\(UUID().uuidString)"
        let keyboard = UserDefaults(suiteName: keyboardName)!
        keyboard.removePersistentDomain(forName: keyboardName)
        return (TildeSettings(keyboard: keyboard), keyboard)
    }

    @Test("Fresh keyboard settings enable suggestions")
    func absentKeysUseProductDefaults() {
        let (settings, _) = makeSettings()
        #expect(settings.suggestionsEnabled)
        #expect(settings.pausedUntil == nil)
        #expect(!settings.personalHistoryEnabled)
        #expect(settings.personalHistoryExcludedApps.isEmpty)
        // 2026-08-16 owner directive: Screen Memory is a first-class,
        // required-permission feature, not an opt-in — a fresh install with
        // no persisted key must read ON, same as every other product
        // default in this file (`suggestionsEnabled` above).
        #expect(settings.screenMemoryEnabled)
    }

    @Test("Launch at login defaults on and preserves an explicit choice")
    func launchAtLoginPreference() {
        let keyboardName = "tilde.tests.keyboard.\(UUID().uuidString)"
        let appName = "tilde.tests.app.\(UUID().uuidString)"
        let keyboard = UserDefaults(suiteName: keyboardName)!
        let app = UserDefaults(suiteName: appName)!
        keyboard.removePersistentDomain(forName: keyboardName)
        app.removePersistentDomain(forName: appName)
        let settings = TildeSettings(keyboard: keyboard, app: app)

        #expect(settings.launchAtLoginEnabled)
        settings.launchAtLoginEnabled = false
        #expect(!settings.launchAtLoginEnabled)
        #expect(app.object(forKey: "LaunchAtLoginEnabled") as? Bool == false)
    }

    @Test("Setup progress stays in the app defaults domain")
    func setupProgress() {
        let keyboardName = "tilde.tests.keyboard.\(UUID().uuidString)"
        let appName = "tilde.tests.app.\(UUID().uuidString)"
        let keyboard = UserDefaults(suiteName: keyboardName)!
        let app = UserDefaults(suiteName: appName)!
        keyboard.removePersistentDomain(forName: keyboardName)
        app.removePersistentDomain(forName: appName)
        let settings = TildeSettings(keyboard: keyboard, app: app)

        #expect(settings.setupVersion == 0)
        #expect(!settings.screenRecordingRequested)
        settings.setupVersion = TildeSettings.currentSetupVersion
        settings.screenRecordingRequested = true

        #expect(app.integer(forKey: "SetupVersion") == TildeSettings.currentSetupVersion)
        #expect(app.bool(forKey: "ScreenRecordingRequested"))
        #expect(keyboard.object(forKey: "SetupVersion") == nil)
    }

    @Test("Screen Memory's toggle lands in the keyboard domain, on by default, explicitly settable either way")
    func screenMemoryToggle() {
        let (settings, keyboard) = makeSettings()
        #expect(settings.screenMemoryEnabled)
        settings.screenMemoryEnabled = false
        #expect(!settings.screenMemoryEnabled)
        #expect(keyboard.object(forKey: "ScreenMemoryEnabled") as? Bool == false)
        settings.screenMemoryEnabled = true
        #expect(settings.screenMemoryEnabled)
    }

    @Test("An existing install that explicitly turned Screen Memory off keeps that choice — the changed default only affects fresh installs with no persisted key")
    func screenMemoryExplicitOffPersists() {
        let (settings, keyboard) = makeSettings()
        keyboard.set(false, forKey: "ScreenMemoryEnabled")
        #expect(!settings.screenMemoryEnabled)
    }

    @Test("Screen Memory shares its exclusion list with Personal History, per the covenant")
    func screenMemorySharesPersonalHistoryExclusions() {
        let (settings, _) = makeSettings()
        settings.personalHistoryExcludedApps = ["com.1password.1password"]
        // There is deliberately no separate `screenMemoryExcludedApps` —
        // Screen Memory reads the same set.
        #expect(settings.personalHistoryExcludedApps == ["com.1password.1password"])
    }

    @Test("Personal History controls stay in the keyboard domain")
    func personalHistorySettings() {
        let (settings, keyboard) = makeSettings()
        settings.personalHistoryEnabled = true
        settings.personalHistoryExcludedApps = ["com.example.Editor", "bad value"]
        settings.personalNextWordExperimentIdentifier = "experiment-id"

        #expect(settings.personalHistoryEnabled)
        #expect(settings.personalHistoryExcludedApps == ["com.example.Editor"])
        #expect(keyboard.object(forKey: "PersonalHistoryEnabled") as? Bool == true)
        #expect(keyboard.stringArray(forKey: "PersonalHistoryExcludedApps") == ["com.example.Editor"])
        #expect(settings.personalNextWordExperimentIdentifier == "experiment-id")
    }

    @Test("Keyboard settings stay in the keyboard defaults domain")
    func keyboardSettingsLandInKeyboardDomain() {
        let (settings, keyboard) = makeSettings()
        settings.suggestionsEnabled = false

        #expect(keyboard.object(forKey: "GhostSuggestionsEnabled") as? Bool == false)
    }

    @Test("Pause expires and resume clears it")
    func pauseLifecycle() {
        let (settings, keyboard) = makeSettings()
        settings.pause(for: 3600)
        #expect(settings.pausedUntil != nil)
        settings.resume()
        #expect(settings.pausedUntil == nil)

        keyboard.set(
            Date().addingTimeInterval(-60).timeIntervalSince1970,
            forKey: "GhostPausedUntil"
        )
        #expect(settings.pausedUntil == nil)
    }

}
