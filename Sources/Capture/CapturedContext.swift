// CapturedContext.swift
// Structured data extracted from a screenshot via Haiku Vision

import Foundation

struct CapturedContext {
    var platform: String?       // "slack", "email", "imessage", "discord", "teams", "other"
    var talkingTo: String?      // "Sarah Graham" — the main person the user is conversing with
    var formality: String?      // "casual", "professional", "formal"
    var conversation: String?   // Full conversation thread text

    /// Whether we successfully extracted a conversation from the screenshot
    var hasConversation: Bool {
        conversation != nil && !conversation!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// What the user sees in the input TextEditor — transparent labeled sections
    var displayText: String {
        var lines: [String] = []

        if let platform = platform {
            lines.append("PLATFORM: \(platform.capitalized)")
        }
        if let talkingTo = talkingTo {
            lines.append("TALKING TO: \(talkingTo)")
        }
        if let formality = formality {
            lines.append("FORMALITY: \(formality)")
        }

        if let conversation = conversation, !conversation.isEmpty {
            lines.append("")
            lines.append("CONVERSATION:")
            lines.append(conversation)
        }

        return lines.joined(separator: "\n")
    }

    /// Build the full drafting prompt — conversation context + user's voice instructions
    func draftingPrompt(userInstructions: String) -> String {
        var prompt = ""

        if let platform = platform {
            prompt += "PLATFORM: \(platform)\n"
        }
        if let talkingTo = talkingTo {
            prompt += "TALKING TO: \(talkingTo)\n"
        }
        if let formality = formality {
            prompt += "FORMALITY: \(formality)\n"
        }

        if let conversation = conversation {
            prompt += "\nCONVERSATION:\n\(conversation)\n"
        }

        let trimmedInstructions = userInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedInstructions.isEmpty {
            prompt += "\nUSER'S INSTRUCTIONS:\n\(trimmedInstructions)\n"
        }

        prompt += "\nWrite the reply. The USER'S INSTRUCTIONS section is the highest priority — "
        prompt += "it contains what the user wants to say and how they want to say it. "
        prompt += "The CONVERSATION section is context so you understand what's being discussed. "
        prompt += "Output ONLY the reply text, nothing else."

        return prompt
    }

    /// Parse Haiku's plain-text response into a CapturedContext
    static func parse(from text: String) -> CapturedContext {
        var context = CapturedContext()

        let lines = text.components(separatedBy: "\n")
        var conversationLines: [String] = []
        var inConversation = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.uppercased().hasPrefix("PLATFORM:") {
                context.platform = String(trimmed.dropFirst("PLATFORM:".count)).trimmingCharacters(in: .whitespaces).lowercased()
                inConversation = false
            } else if trimmed.uppercased().hasPrefix("TALKING TO:") {
                context.talkingTo = String(trimmed.dropFirst("TALKING TO:".count)).trimmingCharacters(in: .whitespaces)
                inConversation = false
            } else if trimmed.uppercased().hasPrefix("FORMALITY:") {
                context.formality = String(trimmed.dropFirst("FORMALITY:".count)).trimmingCharacters(in: .whitespaces).lowercased()
                inConversation = false
            } else if trimmed.uppercased().hasPrefix("CONVERSATION:") {
                inConversation = true
            } else if inConversation {
                conversationLines.append(line)
            }
        }

        let conversationText = conversationLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !conversationText.isEmpty {
            context.conversation = conversationText
        }

        return context
    }
}
