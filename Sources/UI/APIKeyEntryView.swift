// APIKeyEntryView.swift
// Simple overlay for entering the Anthropic API key on first launch

import SwiftUI

struct APIKeyEntryView: View {
    @ObservedObject var draftEngine: DraftEngine
    @State private var apiKeyInput = ""
    @State private var showError = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "key.fill")
                .font(.system(size: 40))
                .foregroundColor(.secondary)

            Text("Enter your Anthropic API key")
                .font(.title3)
                .fontWeight(.medium)

            Text("Get your key from console.anthropic.com")
                .font(.caption)
                .foregroundColor(.secondary)

            SecureField("sk-ant-...", text: $apiKeyInput)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 400)

            if showError {
                Text("Please enter a valid API key")
                    .font(.caption)
                    .foregroundColor(.red)
            }

            Button("Save") {
                if draftEngine.saveAPIKey(apiKeyInput) {
                    // Key saved — view will dismiss via hasAPIKey check
                } else {
                    showError = true
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }
}
