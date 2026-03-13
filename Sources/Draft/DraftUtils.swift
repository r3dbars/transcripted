// DraftUtils.swift
// Extracted pure utility functions for testability

import Foundation

enum DraftUtils {
    /// Detect if a draft is the AI refusing/asking for clarification rather than an actual message.
    /// Used to prevent poisoning the style profile with non-message training pairs.
    static func looksLikeRefusal(_ text: String) -> Bool {
        let lower = text.lowercased()
        let refusalPhrases = [
            "i need the actual",
            "i need more context",
            "could you provide",
            "i'd need to see",
            "please provide",
            "i can't write",
            "i don't have enough",
            "i'm ready to help",
            "i don't see a conversation",
            "the screenshot shows",
            "go ahead and share",
            "what did the person say",
            "not a messaging conversation"
        ]
        return refusalPhrases.contains { lower.contains($0) }
    }
}
