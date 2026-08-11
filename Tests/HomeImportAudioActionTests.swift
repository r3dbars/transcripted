import Foundation

func testHomeImportAudioAction() {
    runSuite("General settings exposes imported-audio transcription") {
        let settingsSource = (try? String(
            contentsOf: repoFixtureURL("Sources/UI/Settings/TranscriptedSettingsView.swift"),
            encoding: .utf8
        )) ?? ""
        let generalSettingsSource = (try? String(
            contentsOf: repoFixtureURL("Sources/UI/Settings/Pages/GeneralSettingsPage.swift"),
            encoding: .utf8
        )) ?? ""
        let homeSource = (try? String(
            contentsOf: repoFixtureURL("Sources/UI/Settings/HomeView.swift"),
            encoding: .utf8
        )) ?? ""
        // HomeSettingsPage.swift is the extracted Home page view (pure
        // rendering only); the shell (TranscriptedSettingsView.swift) still
        // owns the injected onImportAudioFile closure body that calls
        // actions.importAudioFile() and tracks the action.
        let homeSettingsPageSource = (try? String(
            contentsOf: repoFixtureURL("Sources/UI/Settings/Pages/HomeSettingsPage.swift"),
            encoding: .utf8
        )) ?? ""

        assertTrue(
            generalSettingsSource.contains("title: \"Transcribe a file\""),
            "general settings should include an audio-file row"
        )
        assertTrue(
            settingsSource.contains("actions.importAudioFile()"),
            "general settings import action should call the existing audio import flow"
        )
        assertTrue(
            generalSettingsSource.contains("title: \"Transcribe a file\"")
                && generalSettingsSource.contains("value: \"Choose\""),
            "general settings should expose a visible choose-file control"
        )
        assertTrue(
            generalSettingsSource.contains("help: \"Pick an audio or video file. The transcript lands with your meetings.\""),
            "general settings should keep imported-audio help simple"
        )
        assertTrue(
            homeSettingsPageSource.contains("secondaryActionTitle: \"Transcribe audio file\"")
                && homeSettingsPageSource.contains("secondaryAutomationIdentifier: \"transcripted.home.meetings.empty.import-audio\"")
                && settingsSource.contains("trackSettingsAction(\"empty_import_audio\", page: .home)")
                && settingsSource.contains("actions.importAudioFile()"),
            "Home meetings empty state should expose a visible imported-audio route"
        )
        assertTrue(
            homeSource.contains("secondaryActionTitle")
                && homeSource.contains("secondaryAutomationIdentifier")
                && homeSource.contains("secondaryAction"),
            "Home empty states should render the optional secondary action route"
        )
        assertTrue(
            HomeCaptureListCopy.emptyMeetings.contains("transcribe an existing audio file"),
            "Home meeting empty copy should name imported-audio transcription directly"
        )
    }
}
