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
            contentsOf: repoFixtureURL("Sources/UI/Overlay/MeetingOverlayRootView.swift"),
            encoding: .utf8
        )) ?? ""
        let dictationLibrarySource = (try? String(
            contentsOf: repoFixtureURL("Sources/UI/Settings/QuietDictationLibrary.swift"),
            encoding: .utf8
        )) ?? ""

        // Quiet-library redesign: dictations are individual rows
        // (QuietDictationRow); the saved Markdown artifact is surfaced by
        // opening the row into its inline expansion (QuietDictationExpansion),
        // whose footer offers an explicit Open file action.
        assertTrue(
            dictationLibrarySource.contains(#"title: "Open file","#)
                && dictationLibrarySource.contains("action: onOpenFile")
                && dictationLibrarySource.contains(#""transcripted.dictations.expansion.open""#),
            "successful dictations should show that a Markdown artifact was saved"
        )
        assertTrue(
            dictationLibrarySource.contains(#"case .failed, .savedWithoutPaste:"#)
                && dictationLibrarySource.contains(#"return "saved only""#),
            "failed paste-back should still tell users the Markdown was saved"
        )
        assertTrue(
            dictationLibrarySource.contains("struct QuietDictationRow: View")
                && dictationLibrarySource.contains(".onTapGesture(perform: onOpen)"),
            "the saved Markdown label should open the dictation file"
        )
        assertTrue(
            settingsSource.contains(#"HomeRowMenuItem(title: "Open Markdown", symbolName: "doc.text")"#),
            "dictation row menu should use the same Open Markdown language as meeting previews"
        )
        // Quiet-library redesign: the activity card became a row
        // (QuietWorkingRow); a just-saved meeting settles into the day list
        // where its row and expansion expose the Markdown.
        assertTrue(
            settingsSource.contains("QuietWorkingRow("),
            "Home should render in-flight transcription activity as a quiet row"
        )
        assertTrue(
            meetingOverlaySource.contains(#"titleLabel.stringValue = "Saved to Markdown""#),
            "the meeting saved overlay should name the Markdown artifact at the moment of first value"
        )
        // Quiet-library onboarding redesign: the old 14-step flow's dedicated
        // "meeting value" recap step (with its own Open Markdown action card)
        // is gone. Onboarding is now three quiet steps (welcome, permissions,
        // done); the saved-Markdown artifact is taught by Home itself, covered
        // above and by the dictation-row assertions in this suite.
        assertTrue(
            settingsSource.contains("AgentConnectionGuide.portableMeetingBundle(")
                && settingsSource.contains(#"promptKind: usedBundle ? .meetingBundle : .meetingMarkdown"#)
                && settingsSource.contains(#"result: usedBundle ? .success : .fallbackCopied"#),
            "meeting preview Copy for agent should prefer the portable meeting bundle over raw Markdown"
        )
        assertFalse(
            homeSource.contains(#"HomeArtifactStatus(text: "Saved only""#)
                || settingsSource.contains(#"HomeRowMenuItem(title: "Open saved file""#)
                || settingsSource.contains(#"actionTitle: activity.transcriptURL == nil ? nil : "Open Transcript""#)
                || meetingOverlaySource.contains(#"titleLabel.stringValue = "Saved transcript""#),
            "old vague saved-file copy should not return"
        )
    }
}
