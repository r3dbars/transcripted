// DraftEngine.swift
// Manages the "rough text → polished message" workflow via Claude.
//
// Supports both API key auth and Claude subscription token auth via AuthCredential.

import SwiftUI

@MainActor
class DraftEngine: ObservableObject {
    @Published var draftedText = ""
    @Published var isDrafting = false

    /// Snapshot of the AI's original draft — before user edits the output TextEditor.
    /// Used by StyleEngine to compare AI output vs. what the user actually sent.
    @Published var originalDraft = ""
    @Published var error: String?
    @Published var hasCredential = false

    /// Reference to style engine — set by ContentView after init.
    var styleEngine: StyleEngine?

    /// Reference to PromptStore — set by ContentView after init.
    var promptStore: PromptStore?

    /// The raw text from the user's last draft request — exposed for FeedbackStore logging.
    private(set) var lastRawText = ""

    func checkCredential() {
        hasCredential = AuthCredential.load() != nil
    }

    func saveAPIKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let saved = AuthCredential.saveAPIKey(trimmed)
        if saved { hasCredential = true }
        return saved
    }

    func saveSubscriptionToken(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let saved = AuthCredential.saveSubscriptionToken(trimmed)
        if saved { hasCredential = true }
        return saved
    }

    func clearCredential() {
        AuthCredential.clear()
        hasCredential = false
    }

    /// Returns the current auth mode name for display ("API Key" or "Claude Subscription").
    var authModeName: String {
        AuthCredential.load()?.modeName ?? "None"
    }

    /// Original drafting method — used when no screen context is available
    func draftMessage(from rawText: String) {
        guard let auth = AuthCredential.load() else {
            error = "No credentials — add your API key or Claude subscription token in settings"
            return
        }

        isDrafting = true
        error = nil
        draftedText = ""
        lastRawText = rawText

        let customPrompt = styleEngine?.buildSystemPrompt()
        let model = promptStore?.config.model ?? DefaultPrompts.model

        Task {
            do {
                let result = try await AnthropicAPI.draft(rawText: rawText, auth: auth, model: model, systemPrompt: customPrompt)
                self.draftedText = result
                self.originalDraft = result
            } catch AnthropicAPIError.subscriptionTokenExpired {
                self.error = "Subscription token expired — run `claude setup-token` and update in Settings"
            } catch {
                self.error = error.localizedDescription
            }
            self.isDrafting = false
        }
    }

    /// Context-aware drafting — uses full conversation context + user's voice instructions
    func draftWithContext(voiceText: String, context: CapturedContext?, platform: PlatformFormatter) {
        guard let auth = AuthCredential.load() else {
            error = "No credentials — add your API key or Claude subscription token in settings"
            return
        }

        isDrafting = true
        error = nil
        draftedText = ""
        lastRawText = voiceText

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
                let draftModel = self.promptStore?.config.model ?? DefaultPrompts.model
                let result = try await AnthropicAPI.draft(
                    rawText: userMessage,
                    auth: auth,
                    model: draftModel,
                    systemPrompt: systemPrompt.isEmpty ? nil : systemPrompt
                )
                // Apply platform post-processing as safety net
                let processed = platform.postProcess(result)
                self.draftedText = processed
                self.originalDraft = processed
            } catch AnthropicAPIError.subscriptionTokenExpired {
                self.error = "Subscription token expired — run `claude setup-token` and update in Settings"
            } catch {
                self.error = error.localizedDescription
            }
            self.isDrafting = false
        }
    }

    /// Get current auth credential for style summary regeneration
    func getAuth() -> AuthCredential? {
        AuthCredential.load()
    }

    func clear() {
        draftedText = ""
        originalDraft = ""
        lastRawText = ""
        error = nil
    }
}
