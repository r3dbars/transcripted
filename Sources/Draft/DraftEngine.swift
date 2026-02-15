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

    func draftMessage(from rawText: String) {
        guard let apiKey = KeychainHelper.load(key: apiKeyName) else {
            error = "No API key — please add your Anthropic key in settings"
            return
        }

        isDrafting = true
        error = nil
        draftedText = ""

        Task {
            do {
                let result = try await AnthropicAPI.draft(rawText: rawText, apiKey: apiKey)
                self.draftedText = result
            } catch {
                self.error = error.localizedDescription
            }
            self.isDrafting = false
        }
    }

    func clear() {
        draftedText = ""
        error = nil
    }
}
