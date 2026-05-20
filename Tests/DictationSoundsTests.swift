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

    runSuite("AppSoundPlayer uses expected bundled files only") {
        assertEqual(AppSoundPlayer.Cue.dictationStart.bundledFileName, "dictation-start.mp3", "start cue file")
        assertEqual(AppSoundPlayer.Cue.dictationDelivered.bundledFileName, "dictation-delivered.m4a", "delivery cue file")
        assertEqual(AppSoundPlayer.Cue.noSpeech.bundledFileName, "dictation-delivered.m4a", "no speech cue file")
        assertEqual(AppSoundPlayer.Cue.meetingTranscriptComplete.bundledFileName, "meeting-transcript-complete.mp3", "meeting cue file")
        assertNil(AppSoundPlayer.Cue.feedbackSubmitted.bundledFileName, "feedback should open email silently")
        assertNil(AppSoundPlayer.Cue.dictationCancelled.bundledFileName, "cancel cue should skip playback instead of using system sounds")
        assertEqual(AppSoundPlayer.Cue.dictationStart.volumeMultiplier, 1.0, "start cue volume")
        assertEqual(AppSoundPlayer.Cue.dictationDelivered.volumeMultiplier, TranscriptedConstants.deliveredCueVolumeMultiplier, "delivery cue volume")
        assertEqual(AppSoundPlayer.Cue.noSpeech.volumeMultiplier, TranscriptedConstants.deliveredCueVolumeMultiplier, "no speech cue volume")
        assertEqual(AppSoundPlayer.Cue.feedbackSubmitted.volumeMultiplier, 1.0, "feedback cue volume")
    }

    runSuite("Bundled sound files exist in Resources/Sounds") {
        let soundsDirectory = repoRoot()
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("Sounds", isDirectory: true)

        assertTrue(FileManager.default.fileExists(atPath: soundsDirectory.appendingPathComponent("dictation-start.mp3").path), "dictation-start.mp3 should exist")
        assertTrue(FileManager.default.fileExists(atPath: soundsDirectory.appendingPathComponent("dictation-delivered.m4a").path), "dictation-delivered.m4a should exist")
        assertTrue(FileManager.default.fileExists(atPath: soundsDirectory.appendingPathComponent("meeting-transcript-complete.mp3").path), "meeting-transcript-complete.mp3 should exist")
    }

    runSuite("AppSoundPlayer playback entrypoints are best effort") {
        let key = "enableUISounds"
        let original = UserDefaults.standard.object(forKey: key)
        defer {
            restoreUserDefault(original, forKey: key)
        }

        UISoundPreferences.setEnabled(false)
        AppSoundPlayer.shared.play(.dictationStart)
        AppSoundPlayer.shared.play(.feedbackSubmitted, respectingPreferences: false)
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
