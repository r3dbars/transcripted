// DraftEngine.swift
// Manages draft state for the confirm/inject flow.
// Auth and direct API drafting removed — local inference handles generation.

import SwiftUI

@MainActor
class DraftEngine: ObservableObject {
    /// Snapshot of the AI's original draft — before user edits the output TextEditor.
    /// Used by StyleEngine to compare AI output vs. what the user actually sent.
    @Published var originalDraft = ""

    /// Reference to style engine — set by DraftAppState.initialize().
    var styleEngine: StyleEngine?

    /// Reference to PromptStore — set by DraftAppState.initialize().
    var promptStore: PromptStore?

    /// The raw text from the user's last draft request — exposed for FeedbackStore logging.
    var lastRawText = ""

    func clear() {
        originalDraft = ""
        lastRawText = ""
    }
}
