import AppKit
import Foundation

func testDictationSounds() {
    runSuite("UISoundPreferences defaults to enabled") {
        let key = "enableUISounds"
        let original = UserDefaults.standard.object(forKey: key)
        defer {
            restoreUserDefault(original, forKey: key)
        }

        UserDefaults.standard.removeObject(forKey: key)
        assertTrue(UISoundPreferences.isEnabled(), "unset preference should default to enabled")
    }

    runSuite("UISoundPreferences respects explicit values") {
        let key = "enableUISounds"
        let original = UserDefaults.standard.object(forKey: key)
        defer {
            restoreUserDefault(original, forKey: key)
        }

        UISoundPreferences.setEnabled(false)
        assertFalse(UISoundPreferences.isEnabled(), "explicit false should disable sounds")

        UISoundPreferences.setEnabled(true)
        assertTrue(UISoundPreferences.isEnabled(), "explicit true should enable sounds")
    }

    runSuite("AppSoundPlayer uses expected bundled files and fallbacks") {
        assertEqual(AppSoundPlayer.Cue.dictationStart.bundledFileName, "dictation-start.mp3", "start cue file")
        assertEqual(AppSoundPlayer.Cue.dictationDelivered.bundledFileName, "dictation-delivered.m4a", "delivery cue file")
        assertEqual(AppSoundPlayer.Cue.noSpeech.bundledFileName, "dictation-delivered.m4a", "no speech cue file")
        assertEqual(AppSoundPlayer.Cue.meetingTranscriptComplete.bundledFileName, "meeting-transcript-complete.mp3", "meeting cue file")
        assertEqual(AppSoundPlayer.Cue.dictationCancelled.fallbackSystemSoundName, "Basso", "cancel cue fallback")
        assertEqual(AppSoundPlayer.Cue.noSpeech.fallbackSystemSoundName, "Tink", "no speech cue fallback")
        assertEqual(AppSoundPlayer.Cue.dictationDelivered.fallbackSystemSoundName, "Funk", "delivery cue fallback")
    }

    runSuite("Bundled sound files exist in Resources/Sounds") {
        let soundsDirectory = repoRoot()
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("Sounds", isDirectory: true)

        assertTrue(FileManager.default.fileExists(atPath: soundsDirectory.appendingPathComponent("dictation-start.mp3").path), "dictation-start.mp3 should exist")
        assertTrue(FileManager.default.fileExists(atPath: soundsDirectory.appendingPathComponent("dictation-delivered.m4a").path), "dictation-delivered.m4a should exist")
        assertTrue(FileManager.default.fileExists(atPath: soundsDirectory.appendingPathComponent("meeting-transcript-complete.mp3").path), "meeting-transcript-complete.mp3 should exist")
    }

    runSuite("Fallback system sounds exist") {
        assertNotNil(NSSound(named: NSSound.Name(AppSoundPlayer.Cue.dictationStart.fallbackSystemSoundName)), "Pop should exist")
        assertNotNil(NSSound(named: NSSound.Name(AppSoundPlayer.Cue.dictationDelivered.fallbackSystemSoundName)), "Funk should exist")
        assertNotNil(NSSound(named: NSSound.Name(AppSoundPlayer.Cue.dictationCancelled.fallbackSystemSoundName)), "Basso should exist")
        assertNotNil(NSSound(named: NSSound.Name(AppSoundPlayer.Cue.noSpeech.fallbackSystemSoundName)), "Tink should exist")
    }
}

private func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func restoreUserDefault(_ value: Any?, forKey key: String) {
    if let value {
        UserDefaults.standard.set(value, forKey: key)
    } else {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
