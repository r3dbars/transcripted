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

    runSuite("Bundled sound files are exactly the active cue set") {
        let soundsDirectory = repoRoot()
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("Sounds", isDirectory: true)
        let soundFiles = ((try? FileManager.default.contentsOfDirectory(
            at: soundsDirectory,
            includingPropertiesForKeys: nil
        )) ?? [])
            .map(\.lastPathComponent)
            .sorted()

        assertEqual(
            soundFiles,
            [
                "dictation-delivered.m4a",
                "dictation-start.mp3",
                "meeting-transcript-complete.mp3",
            ],
            "Resources/Sounds is copied wholesale, so unused surprise cues should not ship"
        )
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

    runSuite("Feedback submit paths stay silent") {
        let supportActions = readRepoTextFile("Sources/UI/Shared/TranscriptedSupportActions.swift")
        assertFalse(
            supportActions.contains("AppSoundPlayer.shared.play(.feedbackSubmitted"),
            "support email actions should not play the feedback cue"
        )
        assertFalse(
            supportActions.contains("NSSound.beep()"),
            "support email actions should not fall back to a system beep"
        )

        let settingsView = readRepoTextFile("Sources/UI/Settings/TranscriptedSettingsView.swift")
        let homeFeedbackSubmit = sourceSlice(
            in: settingsView,
            from: "private func submitHomeFeedback",
            to: "private func flashCopied"
        )
        assertFalse(
            homeFeedbackSubmit.contains("AppSoundPlayer.shared.play"),
            "Home contextual feedback should open email without an app sound"
        )
        assertFalse(
            homeFeedbackSubmit.contains("NSSound.beep()"),
            "Home contextual feedback should not use a system beep on submit failure"
        )
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

private func readRepoTextFile(_ relativePath: String) -> String {
    let url = repoRoot().appendingPathComponent(relativePath)
    return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}

private func sourceSlice(in contents: String, from startMarker: String, to endMarker: String) -> String {
    guard let start = contents.range(of: startMarker) else { return "" }
    let remainder = contents[start.lowerBound...]
    guard let end = remainder.range(of: endMarker) else { return String(remainder) }
    return String(remainder[..<end.lowerBound])
}
