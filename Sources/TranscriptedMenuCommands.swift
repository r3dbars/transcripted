// TranscriptedMenuCommands.swift
// macOS menu-bar commands that surface Transcripted's top daily actions with
// conventional ⌘-based shortcuts.
//
// This is purely additive: every action routes through an existing app-delegate
// entry point, and none of the user's recordable dictation / meeting triggers
// (push-to-talk, hands-free, meeting, paste-last) are remapped. The commands
// only fire while the app is active (a window is open), which is exactly when
// navigation, search, and in-app capture make sense; the global physical
// triggers remain the background path.

import SwiftUI

struct TranscriptedMenuCommands: Commands {
    let appDelegate: TranscriptedAppDelegate

    var body: some Commands {
        // Capture — the two recording actions plus file import.
        CommandMenu("Capture") {
            Button("Start Dictation") {
                appDelegate.menuStartDictation()
            }
            .keyboardShortcut("d", modifiers: .command)

            Button("Start / Stop Meeting Recording") {
                appDelegate.menuToggleMeetingRecording()
            }
            .keyboardShortcut("r", modifiers: .command)

            Divider()

            Button("Transcribe Audio File…") {
                appDelegate.menuImportAudio()
            }
            .keyboardShortcut("o", modifiers: .command)
        }

        // Go — jump straight to a sidebar section (opening the window if needed).
        CommandMenu("Go") {
            Button("Home") {
                appDelegate.menuOpenPage(.home)
            }
            .keyboardShortcut("1", modifiers: .command)

            Button("Dictations") {
                appDelegate.menuOpenPage(.dictations)
            }
            .keyboardShortcut("2", modifiers: .command)

            Button("Speakers") {
                appDelegate.menuOpenPage(.people)
            }
            .keyboardShortcut("3", modifiers: .command)

            Button("Agent") {
                appDelegate.menuOpenPage(.connectAgent)
            }
            .keyboardShortcut("4", modifiers: .command)

            Divider()

            Button("Find Speaker…") {
                appDelegate.menuFindSpeaker()
            }
            .keyboardShortcut("f", modifiers: .command)
        }
    }
}
