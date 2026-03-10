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
            prompt += "\nSCREEN TEXT (OCR from the user's current conversation window):\n\(conversation)\n"
        }

        let trimmedInstructions = userInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedInstructions.isEmpty {
            prompt += "\nUSER'S INSTRUCTIONS:\n\(trimmedInstructions)\n"
        }

        prompt += """

        INSTRUCTIONS:
        You are ghostwriting a reply for the user in this conversation.

        1. USER'S INSTRUCTIONS are your primary directive — accomplish this goal above all else.
           Don't let style patterns override or distort what the user is trying to say. They may be:
           - A specific idea: "say yes to lunch" → draft a message expressing that intent
           - A tone/style directive: "make it short and funny" → you decide WHAT to say based on the conversation, applying their constraint
           - A mix of both: "decline politely, say I'm busy" → use their intent with their tone guidance

        2. SCREEN TEXT is OCR-captured text from the user's messaging window. It may contain UI chrome, timestamps, and formatting artifacts — focus on the actual messages. You are replying to the most recent message directed at the user.

        3. Match the conversational energy. If messages in the thread are 5-10 words, don't write a paragraph. If they're detailed, match that depth. Read the room.

        4. Don't parrot. Never echo back what the other person just said. "Thanks for the update on the deployment" is robotic — "nice, thanks" is human.

        5. Don't add AI fluff. No "Hey!" greetings unless the conversation warrants one. No sign-offs like "Let me know!" unless the user asked for that. No exclamation points unless the user's style uses them.

        6. Output ONLY the reply text. No labels, no quotes, no explanations, no alternatives.

        7. Don't prepend agreement phrases ("Yeah exactly..", "This is interesting!") unless \
        the user's instructions or the conversation genuinely call for agreement. Most \
        replies work better jumping straight to the point.
        """

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
