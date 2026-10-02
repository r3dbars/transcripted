// Promise: Settings has a "Transcribe a file" row, and Home's empty meetings
// list offers the same picker, so imported audio is never more than one click
// away. The rows read their copy and identifiers from HomeCaptureListCopy,
// which this runner compiles, so most of this checks real values.
//
// Source-text pins left: the shell's closure that calls
// actions.importAudioFile() and tracks "empty_import_audio" lives in
// TranscriptedSettingsView.swift, a SwiftUI view wired to the live app graph
// this runner can't build, and that file is being split right now. Convert it
// once the split lands and the action table compiles here.

import Foundation

func testHomeImportAudioAction() {
    runSuite("General settings exposes imported-audio transcription") {
        let row = HomeCaptureListCopy.ImportFileRow.self
        assertEqual(row.title, "Transcribe a file", "the Settings row should say what it does in plain words")
        assertEqual(row.value, "Choose", "the row should show a visible choose-file control")
        assertTrue(
            row.help.contains("audio or video file") && row.help.contains("meetings"),
            "the help should say what files work and where the transcript lands"
        )

        // The QA import smoke presses the row by this identifier.
        let smoke = (try? String(
            contentsOf: repoFixtureURL("Tools/TranscriptedQA/Sources/TranscriptedQA/Commands/ImportedAudioNativeSmoke.swift"),
            encoding: .utf8
        )) ?? ""
        let smokeIdentifiers = automationIdentifierLiterals(in: smoke)
        assertTrue(
            smokeIdentifiers.contains(row.automationIdentifier),
            "the import smoke should press the identifier the Settings row exposes"
        )
    }

    runSuite("Home's empty meetings list routes to the same import") {
        let action = HomeCaptureListCopy.EmptyMeetingsImportAction.self
        assertEqual(action.title, "Transcribe audio file", "the empty state should offer import as its second button")
        assertTrue(action.automationIdentifier.hasPrefix("transcripted.home."), "the empty-state button should be scriptable")
        assertTrue(
            HomeCaptureListCopy.emptyMeetings.contains("transcribe an existing audio file"),
            "Home meeting empty copy should name imported-audio transcription directly"
        )
    }

    runSuite("The Settings shell wires both import buttons to the import flow") {
        let settingsSource = (try? String(
            contentsOf: repoFixtureURL("Sources/UI/Settings/TranscriptedSettingsView.swift"),
            encoding: .utf8
        )) ?? ""
        assertTrue(
            settingsSource.contains("actions.importAudioFile()"),
            "general settings import action should call the existing audio import flow"
        )
        assertTrue(
            settingsSource.contains("trackSettingsAction(\"empty_import_audio\", page: .home)"),
            "Home meetings empty state should track its imported-audio route"
        )
    }
}
