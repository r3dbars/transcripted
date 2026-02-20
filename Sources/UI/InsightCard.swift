// InsightCard.swift
// Model for agent insight cards streamed via SSE from the orchestrator agent.

import Foundation

enum CardStatus {
    case pending   // Awaiting user decision
    case applied   // User clicked Apply
    case skipped   // User clicked Skip
}

struct InsightCard: Identifiable {
    let id = UUID()
    let suggestionId: String
    let promptKey: String        // Key in prompts.json (e.g., "ghostwriting_system")
    let saw: String              // Evidence from feedback data
    let why: String              // Reasoning about what's wrong
    let currentValue: String     // Current prompt text (relevant section)
    let proposedValue: String    // Proposed new text
    let changeDescription: String // Human-readable diff summary
    var status: CardStatus = .pending

    /// Human-friendly label for the prompt key
    var promptKeyLabel: String {
        switch promptKey {
        case "drafting_system": return "Drafting Prompt"
        case "ghostwriting_system": return "Ghostwriting Prompt"
        case "context_extraction": return "Vision Extraction"
        case "style_analysis_early": return "Style Analysis (Early)"
        case "style_analysis_growing": return "Style Analysis (Growing)"
        case "style_analysis_mature": return "Style Analysis (Mature)"
        case "model": return "Model"
        default: return promptKey
        }
    }

    // MARK: - Shared Tool Definition

    /// Anthropic tool schema for propose_prompt_change — used by both
    /// StreamingChatEngine (chat) and AnalysisEngine (background analysis).
    static let toolDefinition: [String: Any] = [
        "name": "propose_prompt_change",
        "description": "Propose a focused prompt improvement based on feedback patterns.",
        "input_schema": [
            "type": "object",
            "properties": [
                "prompt_key": ["type": "string", "description": "Key in prompts.json to change"],
                "saw": ["type": "string", "description": "Evidence from feedback data"],
                "why": ["type": "string", "description": "Why the current prompt is wrong"],
                "current_value": ["type": "string", "description": "Current prompt value (relevant section)"],
                "proposed_value": ["type": "string", "description": "Full new value for the key"]
            ],
            "required": ["prompt_key", "saw", "why", "proposed_value"]
        ]
    ]

    /// Create an InsightCard from a tool call's parsed JSON input.
    /// Returns nil if the required `prompt_key` field is missing.
    static func from(toolId: String, input: [String: Any]) -> InsightCard? {
        guard let promptKey = input["prompt_key"] as? String else { return nil }
        return InsightCard(
            suggestionId: toolId,
            promptKey: promptKey,
            saw: input["saw"] as? String ?? "",
            why: input["why"] as? String ?? "",
            currentValue: input["current_value"] as? String ?? "",
            proposedValue: input["proposed_value"] as? String ?? "",
            changeDescription: input["why"] as? String ?? ""
        )
    }
}
