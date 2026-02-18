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
}
