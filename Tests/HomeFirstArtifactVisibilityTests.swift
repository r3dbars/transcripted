// Home makes the saved Markdown artifact visible. Behavioral suites below:
//   - Copy for agent prefers the portable meeting bundle over raw Markdown (HomeCopyMeetingReader).
//   - Only active work spins; saved and failed activity shows a still status icon (HomeActivityIndicator).
// Still a source-text pin (2 reads, left in .agents/test-shape-baseline.json): the SwiftUI wiring that
// TranscriptedSettingsView and HomeSettingsPage hold, because each needs live app state
// (@ObservedObject STTRouter/MeetingSessionController/SparkleUpdaterController, HomeViewModel,
// CaptureUndoManager.shared) this Foundation-only runner can't construct. Pinned there: the shared
// "Open Markdown" menu wording, that Home renders in-flight activity as a QuietWorkingRow with the
// activity's tone, and a negative check that older vague copy doesn't come back.

import Foundation

func testHomeFirstArtifactVisibility() {
    runSuite("Copy for agent prefers the portable meeting bundle and falls back to raw Markdown") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("home-copy-reader-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        let missing = HomeCopyMeetingReader.read(
            title: "Planning", date: date, transcriptURL: dir.appendingPathComponent("gone.md")
        )
        assertEqual(missing, .missingFile, "a transcript that is no longer on disk is reported missing")

        let transcript = dir.appendingPathComponent("meeting.md")
        let body = "## Full Transcript\n\n**You** hello there from the planning call\n"
        try? "---\ncapture_type: meeting\n---\n\(body)".write(to: transcript, atomically: true, encoding: .utf8)
        guard case let .success(text, usedBundle) = HomeCopyMeetingReader.read(
            title: "Planning", date: date, transcriptURL: transcript
        ) else {
            assertTrue(false, "a saved meeting should be copyable")
            return
        }
        assertTrue(usedBundle, "Copy for agent should prefer the portable meeting bundle over raw Markdown")
        assertTrue(text.contains("<meeting_transcript>"), "the bundle wraps the transcript for any chat or agent")
        assertTrue(text.contains("hello there from the planning call"), "the bundle carries the meeting content")
        assertTrue(text.contains("Title: Planning"), "the bundle names the meeting")
        assertFalse(text.hasPrefix("---"), "the bundle is not the raw Markdown with its frontmatter")

        // A file with nothing in it can't make a bundle, so the raw text is what gets copied.
        let empty = dir.appendingPathComponent("empty.md")
        try? "".write(to: empty, atomically: true, encoding: .utf8)
        assertEqual(
            HomeCopyMeetingReader.read(title: "Empty", date: date, transcriptURL: empty),
            .success(text: "", usedBundle: false),
            "when no bundle can be built the raw Markdown is copied instead"
        )

        // Bytes that aren't UTF-8 can't be read as text at all.
        let binary = dir.appendingPathComponent("binary.md")
        try? Data([0xFF, 0xFE, 0xFD]).write(to: binary)
        assertEqual(
            HomeCopyMeetingReader.read(title: "Binary", date: date, transcriptURL: binary),
            .readFailure,
            "an unreadable transcript is a read failure, not an empty copy"
        )
    }

    runSuite("Only active work spins; saved and failed activity shows a still status icon") {
        assertEqual(HomeActivityIndicator.make(isWorking: true, isSuccess: false), .spinner)
        assertEqual(HomeActivityIndicator.make(isWorking: false, isSuccess: true), .statusIcon(isSuccess: true))
        assertEqual(HomeActivityIndicator.make(isWorking: false, isSuccess: false), .statusIcon(isSuccess: false))
    }

    runSuite("Home dictation rows make the saved Markdown artifact visible") {
        let settingsSource = (try? String(
            contentsOf: repoFixtureURL("Sources/UI/Settings/TranscriptedSettingsView.swift"),
            encoding: .utf8
        )) ?? ""
        // HomeSettingsPage.swift is the extracted Home page view; it renders the
        // in-flight transcription activity row.
        let homeSettingsPageSource = (try? String(
            contentsOf: repoFixtureURL("Sources/UI/Settings/Pages/HomeSettingsPage.swift"),
            encoding: .utf8
        )) ?? ""

        assertTrue(
            settingsSource.contains(#"HomeRowMenuItem(title: "Open Markdown", symbolName: "doc.text")"#),
            "the shell's dictation menu items should keep the Open Markdown wording meeting previews use (the Dictations card itself shows Show in Finder, not Open Markdown)"
        )
        assertTrue(
            homeSettingsPageSource.contains("QuietWorkingRow("),
            "Home should render in-flight transcription activity as a quiet row"
        )
        assertTrue(
            homeSettingsPageSource.contains("tone: activity.tone"),
            "Home should pass the terminal activity tone instead of making every state look busy"
        )
        assertFalse(
            settingsSource.contains(#"HomeRowMenuItem(title: "Open saved file""#)
                || settingsSource.contains(#"actionTitle: activity.transcriptURL == nil ? nil : "Open Transcript""#),
            "old vague saved-file copy should not return"
        )
    }
}
