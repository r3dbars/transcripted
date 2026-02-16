// CapturedContext.swift
// Structured data extracted from a screenshot via Haiku Vision

import Foundation

struct CapturedContext: Codable {
    var platform: String?       // "slack", "email", "imessage", "discord", "teams", "other"
    var sender: String?         // "Sarah Graham"
    var message: String?        // "Can we move the sprint review to Thursday?"
    var context: String?        // "#engineering channel", "Re: Q4 Planning"
    var formality: String?      // "casual", "professional", "formal"
    var participants: String?   // Other visible people in the conversation

    /// Fallback: raw extracted text when JSON parsing fails
    var rawText: String?

    /// What the user sees in the input TextEditor
    var displayText: String {
        if let sender = sender, let message = message {
            return "\(sender): \(message)"
        }
        return rawText ?? ""
    }

    /// Build the context block for the drafting prompt
    var draftingContext: String {
        var parts: [String] = []

        if let platform = platform {
            parts.append("Platform: \(platform)")
        }
        if let sender = sender {
            parts.append("Replying to: \(sender)")
        }
        if let message = message {
            parts.append("Their message: \"\(message)\"")
        }
        if let context = context {
            parts.append("Context: \(context)")
        }
        if let formality = formality {
            parts.append("Formality: \(formality)")
        }

        if parts.isEmpty, let rawText = rawText {
            return "Conversation context:\n\(rawText)"
        }

        return parts.joined(separator: "\n")
    }
}
