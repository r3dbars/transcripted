import Foundation
import TranscriptedWritingCore
import Testing
@testable import TranscriptedWritingRuntime

@Suite("Tilde settings")
struct TildeSettingsTests {
    private func makeSettings() -> (TildeSettings, UserDefaults) {
        let keyboard = WritingTestDefaults()
        return (TildeSettings(keyboard: keyboard, app: WritingTestDefaults()), keyboard)
    }

    @Test("Fresh settings keep writing capture off by default")
    func absentKeysUseProductDefaults() {
        let (settings, _) = makeSettings()
        #expect(settings.pausedUntil == nil)
        #expect(!settings.personalHistoryEnabled)
        #expect(settings.personalHistoryExcludedApps.isEmpty)
    }

    @Test("Writing capture controls stay in the keyboard domain")
    func personalHistorySettings() {
        let (settings, keyboard) = makeSettings()
        settings.personalHistoryEnabled = true
        settings.personalHistoryExcludedApps = ["com.example.Editor", "bad value"]

        #expect(settings.personalHistoryEnabled)
        #expect(settings.personalHistoryExcludedApps == ["com.example.Editor"])
        #expect(keyboard.object(forKey: "PersonalHistoryEnabled") as? Bool == true)
        #expect(keyboard.stringArray(forKey: "PersonalHistoryExcludedApps") == ["com.example.Editor"])
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

    @Test("The app's pause lands under the key and suite the keyboard reads")
    func pauseUsesTheKeyboardContract() {
        let (settings, keyboard) = makeSettings()
        let now = Date(timeIntervalSince1970: 1_786_485_600)
        settings.pause(for: 3600, now: now)
        let stamp = keyboard.double(forKey: PersonalHistorySettingsContract.pausedUntilKey)
        #expect(PersonalHistorySettingsContract.isPaused(pausedUntil: stamp, now: now))
        #expect(PersonalHistorySettingsContract.isPaused(pausedUntil: stamp, now: now.addingTimeInterval(3599)))
        #expect(!PersonalHistorySettingsContract.isPaused(pausedUntil: stamp, now: now.addingTimeInterval(3600)))

        settings.resume()
        let cleared = keyboard.double(forKey: PersonalHistorySettingsContract.pausedUntilKey)
        #expect(!PersonalHistorySettingsContract.isPaused(pausedUntil: cleared, now: now))
        #expect(TildeSettings.keyboardSuiteName == PersonalHistorySettingsContract.keyboardSuiteName)
    }
}
