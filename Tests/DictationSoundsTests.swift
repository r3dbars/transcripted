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

    runSuite("DictationSounds uses expected system sound names") {
        assertEqual(DictationSounds.systemSoundName(for: .start), "Pop", "start cue")
        assertEqual(DictationSounds.systemSoundName(for: .stop), "Tink", "stop cue")
        assertEqual(DictationSounds.systemSoundName(for: .pasted), "Glass", "paste cue")
        assertEqual(DictationSounds.systemSoundName(for: .cancel), "Basso", "cancel cue")
        assertEqual(DictationSounds.systemSoundName(for: .noSpeech), "Basso", "no speech cue")
        assertEqual(DictationSounds.systemSoundName(for: .error), "Basso", "error cue")
    }

    runSuite("DictationSounds system sounds exist") {
        assertNotNil(NSSound(named: NSSound.Name(DictationSounds.systemSoundName(for: .start))), "Pop should exist")
        assertNotNil(NSSound(named: NSSound.Name(DictationSounds.systemSoundName(for: .stop))), "Tink should exist")
        assertNotNil(NSSound(named: NSSound.Name(DictationSounds.systemSoundName(for: .pasted))), "Glass should exist")
        assertNotNil(NSSound(named: NSSound.Name(DictationSounds.systemSoundName(for: .error))), "Basso should exist")
    }
}

private func restoreUserDefault(_ value: Any?, forKey key: String) {
    if let value {
        UserDefaults.standard.set(value, forKey: key)
    } else {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
