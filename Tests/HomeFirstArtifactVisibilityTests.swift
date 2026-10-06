// Source-text pins: this test reads Sources/UI/Settings/{HomeView,TranscriptedSettingsView,
// QuietHomeLibrary,Pages/HomeSettingsPage}.swift
// as text rather than rendering them, because each is a SwiftUI view
// wired to live app state this Foundation-only runner can't construct —
// TranscriptedSettingsView holds @ObservedObject STTRouter/MeetingSessionController/SparkleUpdaterController,
// and HomeSettingsPage carries an @ObservedObject HomeViewModel plus CaptureUndoManager.shared and real
// domain closures; HomeViewModel's own init is cheap, but its data only loads once the shell calls
// refresh() from navigation state. What's pinned: the shared "Open Markdown" menu wording, and QuietWorkingRow's presence and terminal-state icon behavior on Home —
// plus a negative check that older vague copy doesn't come back. If you rename these views or move this
// wording, update the literal strings here; they're standing in for a real UX regression check.

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
        let quietHomeLibrarySource = (try? String(
            contentsOf: repoFixtureURL("Sources/UI/Settings/QuietHomeLibrary.swift"),
            encoding: .utf8
        )) ?? ""
        // HomeSettingsPage.swift is the extracted Home page view; it now
        // renders the in-flight transcription activity row that used to be
        // inline in TranscriptedSettingsView.swift.
        let homeSettingsPageSource = (try? String(
            contentsOf: repoFixtureURL("Sources/UI/Settings/Pages/HomeSettingsPage.swift"),
            encoding: .utf8
        )) ?? ""

        // The Dictations cards (2026-10) dropped the row's "Open file" and
        // tap-to-open pins; the "saved only" wording is a promise test now
        // (DictationCardPresentationTests), and Show in Finder reveals the file.
        assertTrue(
            settingsSource.contains(#"HomeRowMenuItem(title: "Open Markdown", symbolName: "doc.text")"#),
            "the shell's dictation menu items should keep the Open Markdown wording meeting previews use (the Dictations card itself shows Show in Finder, not Open Markdown)"
        )
        // Quiet-library redesign: the activity card became a row
        // (QuietWorkingRow); a just-saved meeting settles into the day list
        // where its row and expansion expose the Markdown.
        assertTrue(
            homeSettingsPageSource.contains("QuietWorkingRow("),
            "Home should render in-flight transcription activity as a quiet row"
        )
        assertTrue(
            homeSettingsPageSource.contains("tone: activity.tone"),
            "Home should pass the terminal activity tone instead of making every state look busy"
        )
        assertTrue(
            quietHomeLibrarySource.contains("if tone == .working")
                && quietHomeLibrarySource.contains("Image(systemName: symbolName)"),
            "only active work should spin; saved and failed activity should show a static status icon"
        )
        // Quiet-library onboarding redesign: the old 14-step flow's dedicated
        // "meeting value" recap step (with its own Open Markdown action card)
        // is gone. Onboarding is now three quiet steps (welcome, permissions,
        // done); the saved-Markdown artifact is taught by Home itself, covered
        // above and by the dictation-row assertions in this suite.
        assertTrue(
            settingsSource.contains("AgentConnectionGuide.portableMeetingBundle(")
                && settingsSource.contains(#"promptKind: usedBundle ? .meetingBundle : .meetingMarkdown"#)
                && settingsSource.contains(#"result: copied ? (usedBundle ? .success : .fallbackCopied) : .failed"#),
            "meeting preview Copy for agent should prefer the portable meeting bundle over raw Markdown"
        )
        assertFalse(
            homeSource.contains(#"HomeArtifactStatus(text: "Saved only""#)
                || settingsSource.contains(#"HomeRowMenuItem(title: "Open saved file""#)
                || settingsSource.contains(#"actionTitle: activity.transcriptURL == nil ? nil : "Open Transcript""#),
            "old vague saved-file copy should not return"
        )
    }
}
