import Foundation

func testHomeFirstArtifactVisibility() {
    runSuite("Home dictation rows make the saved Markdown artifact visible") {
        let homeSource = (try? String(
            contentsOf: repoFixtureURL("Sources/UI/Settings/HomeView.swift"),
            encoding: .utf8
        )) ?? ""
        let settingsSource = (try? String(
            contentsOf: repoFixtureURL("Sources/UI/Settings/TranscriptedSettingsView.swift"),
            encoding: .utf8
        )) ?? ""

        assertTrue(
            homeSource.contains(#"return HomeArtifactStatus(text: "Saved to Markdown", tone: .ready)"#),
            "successful dictations should show that a Markdown artifact was saved"
        )
        assertTrue(
            homeSource.contains(#"return HomeArtifactStatus(text: "Saved to Markdown only", tone: .warning)"#),
            "failed paste-back should still tell users the Markdown was saved"
        )
        assertTrue(
            homeSource.contains("Button(action: onOpen)")
                && homeSource.contains(#".help("Open Markdown")"#),
            "the saved Markdown label should open the dictation file"
        )
        assertTrue(
            settingsSource.contains(#"HomeRowMenuItem(title: "Open Markdown", symbolName: "doc.text")"#),
            "dictation row menu should use the same Open Markdown language as meeting previews"
        )
        assertTrue(
            settingsSource.contains(#"actionTitle: activity.transcriptURL == nil ? nil : "Open Markdown""#),
            "the just-saved meeting activity card should name the Markdown artifact"
        )
        assertFalse(
            homeSource.contains(#"HomeArtifactStatus(text: "Saved only""#)
                || settingsSource.contains(#"HomeRowMenuItem(title: "Open saved file""#)
                || settingsSource.contains(#"actionTitle: activity.transcriptURL == nil ? nil : "Open Transcript""#),
            "old vague saved-file copy should not return"
        )
    }
}
