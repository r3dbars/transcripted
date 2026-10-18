// lint-fixture-path: Sources/UI/Settings/ExampleSettingsView+Pages.swift
// Shape of 5f7a490b8^: a Settings view deletes a dictation and stages undo,
// all on the main actor.
import SwiftUI

struct ExampleSettingsView: View {
    var body: some View { Text("x") }
}

extension ExampleSettingsView {
    private func deleteDictationWithUndo(_ entry: SavedDictationEntry) {
        do {
            let undoPayload = try DictationTranscriptStore.deleteEntryReversibly(entry)
            captureUndo.stage(
                id: DictationUndoID.id(for: entry),
                undoAction: {
                    do {
                        try DictationTranscriptStore.restoreDeletedEntry(undoPayload)
                    } catch {
                        presentFailure(error)
                    }
                },
                finalize: {
                    DictationAudioArchive.deleteKeptAudio(for: entry)
                }
            )
        } catch {
            presentFailure(error)
        }
    }
}
