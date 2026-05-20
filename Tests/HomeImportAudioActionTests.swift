import Foundation

func testHomeImportAudioAction() {
    runSuite("General settings exposes imported-audio transcription") {
        let settingsSource = (try? String(
            contentsOf: repoFixtureURL("Sources/UI/Settings/TranscriptedSettingsView.swift"),
            encoding: .utf8
        )) ?? ""
        let homeSource = (try? String(
            contentsOf: repoFixtureURL("Sources/UI/Settings/HomeView.swift"),
            encoding: .utf8
        )) ?? ""

        assertTrue(
            settingsSource.contains("title: \"Audio files\""),
            "general settings should include an audio-file row"
        )
        assertTrue(
            settingsSource.contains("actions.importAudioFile()"),
            "general settings import action should call the existing audio import flow"
        )
        assertTrue(
            settingsSource.contains("title: \"Audio files\"")
                && settingsSource.contains("value: \"Choose File\""),
            "general settings should expose a visible choose-file control"
        )
        assertTrue(
            settingsSource.contains("WAV, MP3, M4A, AAC, or AIFF"),
            "general settings should name common supported audio formats"
        )
        assertTrue(
            !homeSource.contains("HomeMeetingImportActionRow")
                && !homeSource.contains("onImportAudio"),
            "meetings tab should not carry the imported-audio action"
        )
        assertTrue(
            homeSource.contains("transcribe an audio file from General"),
            "home meeting empty state should point users back to the import location"
        )
    }
}
