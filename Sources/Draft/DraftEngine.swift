// DraftEngine.swift
// Manages the "rough text → polished message" workflow via Claude Haiku

import SwiftUI

@MainActor
class DraftEngine: ObservableObject {
    @Published var draftedText = ""
    @Published var isDrafting = false

    /// Snapshot of the AI's original draft — before user edits the output TextEditor.
    /// Used by StyleEngine to compare AI output vs. what the user actually sent.
    @Published var originalDraft = ""
    @Published var error: String?
    @Published var hasAPIKey = false

    private let apiKeyName = "anthropic-api-key"

    func checkAPIKey() {
        hasAPIKey = KeychainHelper.load(key: apiKeyName) != nil
    }

    func saveAPIKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let saved = KeychainHelper.save(key: apiKeyName, value: trimmed)
        if saved { hasAPIKey = true }
        return saved
    }

    func clearAPIKey() {
        KeychainHelper.delete(key: apiKeyName)
        hasAPIKey = false
    }

    /// Reference to style engine — set by ContentView after init
    var styleEngine: StyleEngine?

    /// Original drafting method — used when no screen context is available
    func draftMessage(from rawText: String) {
        guard let apiKey = KeychainHelper.load(key: apiKeyName) else {
            error = "No API key — please add your Anthropic key in settings"
            return
        }

        isDrafting = true
        error = nil
        draftedText = ""

        let customPrompt = styleEngine?.buildSystemPrompt()

        Task {
            do {
                let result = try await AnthropicAPI.draft(rawText: rawText, apiKey: apiKey, systemPrompt: customPrompt)
                self.draftedText = result
                self.originalDraft = result
            } catch {
                self.error = error.localizedDescription
            }
            self.isDrafting = false
        }
    }

    /// Context-aware drafting — uses full conversation context + user's voice instructions
    func draftWithContext(voiceText: String, context: CapturedContext?, platform: PlatformFormatter) {
        guard let apiKey = KeychainHelper.load(key: apiKeyName) else {
            error = "No API key — please add your Anthropic key in settings"
            return
        }

        isDrafting = true
        error = nil
        draftedText = ""

        // Build system prompt with style + platform formatting
        var systemPrompt = styleEngine?.buildSystemPrompt() ?? ""
        if !platform.formattingInstructions.isEmpty {
            systemPrompt += "\n\n" + platform.formattingInstructions
        }

        // Build the user message — context struct assembles everything
        let userMessage: String
        if let context = context {
            userMessage = context.draftingPrompt(userInstructions: voiceText)
        } else {
            userMessage = "The user said: \"\(voiceText.trimmingCharacters(in: .whitespacesAndNewlines))\"\n\nWrite the reply. Output ONLY the reply text, nothing else."
        }

        Task {
            do {
                let result = try await AnthropicAPI.draft(
                    rawText: userMessage,
                    apiKey: apiKey,
                    systemPrompt: systemPrompt.isEmpty ? nil : systemPrompt
                )
                // Apply platform post-processing as safety net
                let processed = platform.postProcess(result)
                self.draftedText = processed
                self.originalDraft = processed
            } catch {
                self.error = error.localizedDescription
            }
            self.isDrafting = false
        }
    }

    /// Get API key for style summary regeneration
    func getAPIKey() -> String? {
        KeychainHelper.load(key: apiKeyName)
    }

    func clear() {
        draftedText = ""
        originalDraft = ""
        error = nil
    }
}
