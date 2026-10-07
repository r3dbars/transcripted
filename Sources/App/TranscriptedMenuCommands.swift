// TranscriptedMenuCommands.swift
// macOS menu-bar commands that surface Transcripted's top daily actions with
// conventional ⌘-based shortcuts.
//
// This is purely additive: every action routes through an existing app-delegate
// entry point, and none of the user's recordable dictation / meeting triggers
// (dictation, meeting) are remapped. The commands
// only fire while the app is active (a window is open), which is exactly when
// navigation, search, and in-app capture make sense; the global physical
// triggers remain the background path.

import SwiftUI

struct TranscriptedMenuCommands: Commands {
    let appDelegate: TranscriptedAppDelegate

    var body: some Commands {
        // Replace SwiftUI's native Settings action declaratively. A previous
        // one-shot AppKit menu mutation could miss menu construction and leave
        // the empty fallback scene on screen when the user pressed Command-,.
        CommandGroup(replacing: .appSettings) {
            button(for: TranscriptedMenuCommandCatalog.settings)
        }

        // Capture — the two recording actions plus file import.
        CommandMenu("Capture") {
            items(TranscriptedMenuCommandCatalog.capture)
        }

        // Go — jump straight to a sidebar section (opening the window if needed).
        CommandMenu("Go") {
            items(TranscriptedMenuCommandCatalog.go)
        }
    }

    private func items(_ items: [TranscriptedMenuCommandCatalog.Item]) -> some View {
        ForEach(items) { item in
            if item.startsGroup {
                Divider()
            }
            button(for: item)
        }
    }

    private func button(for item: TranscriptedMenuCommandCatalog.Item) -> some View {
        Button(item.title) {
            perform(item.action)
        }
        .keyboardShortcut(
            KeyEquivalent(item.key),
            modifiers: item.usesShift ? [.command, .shift] : .command
        )
    }

    private func perform(_ action: TranscriptedMenuCommandCatalog.Action) {
        switch action {
        case .openSettings:
            appDelegate.menuOpenSettings()
        case .startDictation:
            appDelegate.menuStartDictation()
        case .toggleMeetingRecording:
            appDelegate.menuToggleMeetingRecording()
        case .importAudio:
            appDelegate.menuImportAudio()
        case let .openPage(page):
            appDelegate.menuOpenPage(page)
        case .findCaptures:
            appDelegate.menuFindCaptures()
        case .findSpeaker:
            appDelegate.menuFindSpeaker()
        }
    }
}
