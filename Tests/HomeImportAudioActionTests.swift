import Foundation

func testHomeImportAudioAction() {
    runSuite("Home meetings tab exposes imported-audio transcription") {
        let settingsSource = (try? String(
            contentsOf: repoFixtureURL("Sources/UI/Settings/TranscriptedSettingsView.swift"),
            encoding: .utf8
        )) ?? ""
        let homeSource = (try? String(
            contentsOf: repoFixtureURL("Sources/UI/Settings/HomeView.swift"),
            encoding: .utf8
        )) ?? ""

        assertTrue(
            settingsSource.contains("onImportAudio: {"),
            "settings home should pass an import-audio action into the meetings tab"
        )
        assertTrue(
            settingsSource.contains("actions.importAudioFile()"),
            "settings home import action should call the existing audio import flow"
        )
        assertTrue(
            homeSource.contains("Transcribe Audio File"),
            "meetings tab should show a visible audio import affordance"
        )
        assertTrue(
            homeSource.contains("SettingsInlineActionButton(")
                && homeSource.contains("title: \"Choose File\""),
            "meetings tab should expose a clickable choose-file control"
        )
    }
}
