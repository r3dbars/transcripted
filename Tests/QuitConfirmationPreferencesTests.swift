import Foundation

func testQuitConfirmationPreferences() {
    runSuite("QuitConfirmationPreferences defaults to enabled") {
        let (defaults, suiteName) = makeQuitConfirmationDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertTrue(
            QuitConfirmationPreferences.confirmQuitDuringActiveMeetingRecording(userDefaults: defaults),
            "active meeting quit confirmation should protect new installs by default"
        )
    }

    runSuite("QuitConfirmationPreferences persists disabled and enabled states") {
        let (defaults, suiteName) = makeQuitConfirmationDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        QuitConfirmationPreferences.setConfirmQuitDuringActiveMeetingRecording(false, userDefaults: defaults)
        assertFalse(
            QuitConfirmationPreferences.confirmQuitDuringActiveMeetingRecording(userDefaults: defaults),
            "explicit opt-out should round-trip through injected defaults"
        )

        QuitConfirmationPreferences.setConfirmQuitDuringActiveMeetingRecording(true, userDefaults: defaults)
        assertTrue(
            QuitConfirmationPreferences.confirmQuitDuringActiveMeetingRecording(userDefaults: defaults),
            "explicit opt-in should round-trip through injected defaults"
        )
    }

    runSuite("QuitConfirmationPreferences uses a stable storage key") {
        assertEqual(
            QuitConfirmationPreferences.confirmQuitDuringActiveMeetingRecordingKey,
            "confirm-quit-during-active-meeting-recording",
            "storage key must stay stable across releases"
        )
    }

    runSuite("ActiveMeetingQuitConfirmationPolicy only prompts for active meeting capture") {
        assertTrue(
            ActiveMeetingQuitConfirmationPolicy.shouldConfirmQuit(
                preferenceEnabled: true,
                activeMeetingCapture: true
            ),
            "default-on preference should prompt while a meeting is recording or finishing"
        )
        assertFalse(
            ActiveMeetingQuitConfirmationPolicy.shouldConfirmQuit(
                preferenceEnabled: true,
                activeMeetingCapture: false
            ),
            "idle or transcription-only quits should not show an extra dialog"
        )
        assertFalse(
            ActiveMeetingQuitConfirmationPolicy.shouldConfirmQuit(
                preferenceEnabled: false,
                activeMeetingCapture: true
            ),
            "user opt-out should skip the dialog even during active capture"
        )
    }

    runSuite("ActiveMeetingQuitConfirmationPolicy copy explains the consequence") {
        let presentation = ActiveMeetingQuitConfirmationPolicy.presentation

        assertEqual(
            presentation.title,
            "Meeting is still recording",
            "alert title should name the active meeting quit"
        )
        assertTrue(
            presentation.message.contains("stop and make the transcript"),
            "alert should offer the normal stop and transcribe path"
        )
        assertTrue(
            presentation.message.contains("save the captured audio and quit"),
            "alert should explain that quit preserves retry audio"
        )
        assertEqual(
            presentation.keepRecordingTitle,
            "Keep Recording",
            "safe default button should keep recording"
        )
        assertEqual(
            presentation.stopAndTranscribeTitle,
            "Stop & Transcribe",
            "middle path should keep the app open and make a transcript"
        )
        assertEqual(
            presentation.saveAudioAndQuitTitle,
            "Save Audio & Quit",
            "confirm button should describe the recoverable quit path"
        )
    }
}

private func makeQuitConfirmationDefaults() -> (UserDefaults, String) {
    let suiteName = "QuitConfirmationPreferencesTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
}
