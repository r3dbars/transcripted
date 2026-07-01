import Foundation

func testHomeImportAudioAction() {
    runSuite("General settings exposes imported-audio transcription") {
        let settingsSource = settingsSurfaceContents()
        let homeSource = (try? String(
            contentsOf: repoFixtureURL("Sources/UI/Settings/HomeView.swift"),
            encoding: .utf8
        )) ?? ""

        assertTrue(
            settingsSource.contains("title: \"Transcribe audio file\""),
            "general settings should include an audio-file row"
        )
        assertTrue(
            settingsSource.contains("actions.importAudioFile()"),
            "general settings import action should call the existing audio import flow"
        )
        assertTrue(
            settingsSource.contains("title: \"Transcribe audio file\"")
                && settingsSource.contains("value: \"Choose\""),
            "general settings should expose a visible choose-file control"
        )
        assertTrue(
            settingsSource.contains("help: \"Choose an audio file to transcribe.\""),
            "general settings should keep imported-audio help simple"
        )
        assertTrue(
            !homeSource.contains("HomeMeetingImportActionRow")
                && !homeSource.contains("onImportAudio"),
            "meetings tab should not carry the imported-audio action"
        )
        assertTrue(
            HomeCaptureListCopy.emptyMeetings.contains("transcribe an audio file from General"),
            "home meeting empty state should point users back to the import location"
        )
    }
}
