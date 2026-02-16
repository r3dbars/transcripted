// APIKeyEntryView.swift
// Onboarding overlay for name + Anthropic API key on first launch

import SwiftUI

struct APIKeyEntryView: View {
    @ObservedObject var draftEngine: DraftEngine
    @State private var nameInput = UserDefaults.standard.string(forKey: "user-display-name") ?? ""
    @State private var apiKeyInput = ""
    @State private var showError = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "person.text.rectangle.fill")
                .font(.system(size: 40))
                .foregroundColor(.secondary)

            Text("Set up Draft")
                .font(.title3)
                .fontWeight(.medium)

            Text("Your name helps Draft understand who you are in screenshots")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            TextField("Your name (e.g. r3dbars)", text: $nameInput)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 400)

            Divider()
                .frame(maxWidth: 400)

            Text("Anthropic API Key")
                .font(.caption)
                .foregroundColor(.secondary)

            SecureField("sk-ant-...", text: $apiKeyInput)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 400)

            Text("Get your key from console.anthropic.com")
                .font(.caption2)
                .foregroundColor(.secondary)

            if showError {
                Text("Please enter your name and a valid API key")
                    .font(.caption)
                    .foregroundColor(.red)
            }

            Button("Save") {
                let trimmedName = nameInput.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedName.isEmpty else {
                    showError = true
                    return
                }
                UserDefaults.standard.set(trimmedName, forKey: "user-display-name")

                if draftEngine.saveAPIKey(apiKeyInput) {
                    // Key saved — view will dismiss via hasAPIKey check
                } else {
                    showError = true
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                nameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }
}
