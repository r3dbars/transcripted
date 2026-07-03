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

    runSuite("ActiveMeetingQuitConfirmationPolicy prompts for active and background meeting work") {
        assertTrue(
            ActiveMeetingQuitConfirmationPolicy.shouldConfirmQuit(
                preferenceEnabled: true,
                activeMeetingCapture: true
            ),
            "default-on preference should prompt while a meeting is recording or finishing"
        )
        assertTrue(
            ActiveMeetingQuitConfirmationPolicy.shouldConfirmQuit(
                preferenceEnabled: true,
                activeMeetingCapture: false,
                backgroundTranscriptionWork: true
            ),
            "default-on preference should also prompt while meeting transcription or imports are queued"
        )
        assertFalse(
            ActiveMeetingQuitConfirmationPolicy.shouldConfirmQuit(
                preferenceEnabled: true,
                activeMeetingCapture: false
            ),
            "idle quits should not show an extra dialog"
        )
        assertFalse(
            ActiveMeetingQuitConfirmationPolicy.shouldConfirmQuit(
                preferenceEnabled: false,
                activeMeetingCapture: true,
                backgroundTranscriptionWork: true
            ),
            "user opt-out should skip the dialog even during active or background meeting work"
        )
    }

    runSuite("ActiveMeetingQuitConfirmationPolicy copy explains the consequence") {
        let presentation = ActiveMeetingQuitConfirmationPolicy.presentation

        assertEqual(
            presentation.title,
            "Meeting work is still running",
            "alert title should cover recording and background transcription work"
        )
        assertTrue(
            presentation.message.contains("Keep Transcripted open"),
            "alert should offer the safe path of keeping the app open"
        )
        assertTrue(
            presentation.message.contains("save the audio and quit"),
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

        let backgroundPresentation = ActiveMeetingQuitConfirmationPolicy.backgroundPresentation
        assertEqual(
            backgroundPresentation.title,
            "Meeting transcript is still running",
            "background-only alert should name transcript work instead of active recording"
        )
        assertEqual(
            backgroundPresentation.keepOpenTitle,
            "Keep Open",
            "background-only alert should not offer a recording action"
        )
        assertEqual(
            backgroundPresentation.saveAudioAndQuitTitle,
            "Save Audio & Quit",
            "background-only quit should still describe preserved audio"
        )
    }
}

private func makeQuitConfirmationDefaults() -> (UserDefaults, String) {
    let suiteName = "QuitConfirmationPreferencesTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
}
