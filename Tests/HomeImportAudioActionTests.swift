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
            settingsSource.contains("SettingsSection(\n                title: \"Audio Files\""),
            "general settings should include an audio-file section"
        )
        assertTrue(
            settingsSource.contains("actions.importAudioFile()"),
            "general settings import action should call the existing audio import flow"
        )
        assertTrue(
            settingsSource.contains("Transcribe Audio File")
                && settingsSource.contains("title: \"Choose File\""),
            "general settings should expose a visible choose-file control"
        )
        assertTrue(
            !homeSource.contains("HomeMeetingImportActionRow")
                && !homeSource.contains("onImportAudio"),
            "meetings tab should not carry the imported-audio action"
        )
    }
}
