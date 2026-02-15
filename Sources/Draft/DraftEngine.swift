// DraftEngine.swift
// Manages the "rough text → polished message" workflow via Claude Haiku

import SwiftUI

@MainActor
class DraftEngine: ObservableObject {
    @Published var draftedText = ""
    @Published var isDrafting = false
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
        error = nil
    }
}
