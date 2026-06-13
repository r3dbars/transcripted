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
        let meetingOverlaySource = (try? String(
            contentsOf: repoFixtureURL("Sources/UI/Overlay/MeetingOverlayController.swift"),
            encoding: .utf8
        )) ?? ""
        let onboardingSource = (try? String(
            contentsOf: repoFixtureURL("Sources/UI/Settings/PermissionsOnboardingView.swift"),
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
        assertTrue(
            meetingOverlaySource.contains(#"titleLabel.stringValue = "Saved to Markdown""#),
            "the meeting saved overlay should name the Markdown artifact at the moment of first value"
        )
        assertTrue(
            onboardingSource.contains(#"command: "Open Markdown""#)
                && onboardingSource.contains(#"detail: "Your transcript is saved on this Mac.""#),
            "meeting onboarding should make the saved local Markdown artifact the visible first-value step"
        )
        assertTrue(
            settingsSource.contains("AgentConnectionGuide.portableMeetingBundle(")
                && settingsSource.contains(#"promptKind: .meetingBundle"#)
                && settingsSource.contains(#"result: bundle == nil ? .fallbackCopied : .success"#),
            "meeting preview Copy for agent should prefer the portable meeting bundle over raw Markdown"
        )
        assertFalse(
            homeSource.contains(#"HomeArtifactStatus(text: "Saved only""#)
                || settingsSource.contains(#"HomeRowMenuItem(title: "Open saved file""#)
                || settingsSource.contains(#"actionTitle: activity.transcriptURL == nil ? nil : "Open Transcript""#)
                || meetingOverlaySource.contains(#"titleLabel.stringValue = "Saved transcript""#)
                || onboardingSource.contains(#"command: "Open Transcript""#),
            "old vague saved-file copy should not return"
        )
    }
}
