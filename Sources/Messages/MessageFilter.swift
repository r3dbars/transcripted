// MessageFilter.swift
// Extracted message quality filtering for testability

import Foundation

enum MessageFilter {
    /// Returns true if the message should be skipped (too short, emoji-only, tapback, URL-only).
    /// Used by iMessageReader to filter low-quality messages from style training data.
    static func shouldSkip(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        let words = trimmed.split(whereSeparator: { $0.isWhitespace || $0.isNewline })

        // Single-character messages (just "k", "y", etc.) — not enough signal
        if trimmed.count < 2 { return true }

        // Pure emoji / reactions (fewer than 3 non-emoji ASCII scalars)
        let nonEmojiCount = trimmed.unicodeScalars.filter { !$0.properties.isEmoji || $0.isASCII }.count
        if nonEmojiCount < 3 { return true }

        // Tapback / reaction messages — catch both "Liked a message" and 'Liked "quoted text"' formats
        let lower = trimmed.lowercased()
        let tapbackVerbs = ["loved", "liked", "laughed at", "emphasized", "questioned", "disliked", "reacted"]
        if tapbackVerbs.contains(where: { lower.hasPrefix($0) }) {
            // It's a tapback if it starts with a verb + follows with "a message/an image" or a quoted string
            if lower.contains("an image") || lower.contains("a message") { return true }
            // "Liked "morning! dogs are out"" or "Reacted 💯 to "something""
            if trimmed.contains("\"") || trimmed.contains("\u{201C}") { return true }
            // "Reacted 💯 to" pattern
            if lower.contains(" to ") && tapbackVerbs.contains(where: { lower.hasPrefix($0) }) { return true }
        }

        // URL-only messages
        if lower.hasPrefix("http") && words.count <= 2 { return true }

        return false
    }
}
