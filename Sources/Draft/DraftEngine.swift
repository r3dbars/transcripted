// DraftEngine.swift
// Manages draft state for the confirm/inject flow.
// Auth and direct API drafting removed — local inference handles generation.

import SwiftUI

@MainActor
class DraftEngine: ObservableObject {
    @Published var draftedText = ""
    @Published var isDrafting = false

    /// Snapshot of the AI's original draft — before user edits the output TextEditor.
    /// Used by StyleEngine to compare AI output vs. what the user actually sent.
    @Published var originalDraft = ""
    @Published var error: String?

    /// Reference to style engine — set by ContentView after init.
    var styleEngine: StyleEngine?

    /// Reference to PromptStore — set by ContentView after init.
    var promptStore: PromptStore?

    /// The raw text from the user's last draft request — exposed for FeedbackStore logging.
    var lastRawText = ""

    func clear() {
        draftedText = ""
        originalDraft = ""
        lastRawText = ""
        error = nil
    }
}
