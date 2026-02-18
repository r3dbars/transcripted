// APIKeyEntryView.swift
// Auth setup overlay — collects user name + credentials on first launch.
//
// Supports two auth methods via segmented picker:
//   API Key:            console.anthropic.com → create key → paste here
//   Claude Subscription: `claude setup-token` in terminal → paste result here
//                        (uses Pro/Max subscription instead of per-token API billing)

import SwiftUI

enum AuthMethod: String, CaseIterable {
    case apiKey = "API Key"
    case subscription = "Claude Subscription"
}

struct APIKeyEntryView: View {
    @ObservedObject var draftEngine: DraftEngine
    @State private var nameInput = UserDefaults.standard.string(forKey: "user-display-name") ?? ""
    @State private var selectedMethod: AuthMethod = .apiKey
    @State private var input = ""
    @State private var showError = false
    @State private var errorMessage = ""

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "person.text.rectangle.fill")
                .font(.system(size: 40))
                .foregroundColor(.secondary)

            Text("Set up Draft")
                .font(.title3)
                .fontWeight(.semibold)

            // Name input
            VStack(spacing: 6) {
                Text("Your name helps Draft understand who you are in screenshots")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                TextField("Your name (e.g. Justin Betker)", text: $nameInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)
            }

            Divider()
                .frame(maxWidth: 360)

            // Auth method picker
            Picker("Auth Method", selection: $selectedMethod) {
                ForEach(AuthMethod.allCases, id: \.self) { method in
                    Text(method.rawValue).tag(method)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)
            .onChange(of: selectedMethod) {
                input = ""
                showError = false
            }

            // Method-specific content
            if selectedMethod == .apiKey {
                APIKeyForm(input: $input)
            } else {
                SubscriptionTokenForm(input: $input)
            }

            // Error
            if showError {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
            }

            // Save button
            Button("Connect") {
                save()
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                nameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
            .keyboardShortcut(.return)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }

    private func save() {
        let trimmedName = nameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            showError = true
            errorMessage = "Please enter your name"
            return
        }
        UserDefaults.standard.set(trimmedName, forKey: "user-display-name")

        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else { return }

        let success: Bool
        switch selectedMethod {
        case .apiKey:
            if trimmedInput.hasPrefix("sk-ant-oat") {
                showError = true
                errorMessage = "That's a subscription token (sk-ant-oat...). Switch to the Claude Subscription tab."
                return
            }
            guard trimmedInput.hasPrefix("sk-ant-api") else {
                showError = true
                errorMessage = "Anthropic API keys start with sk-ant-api..."
                return
            }
            success = draftEngine.saveAPIKey(trimmedInput)
        case .subscription:
            if trimmedInput.hasPrefix("sk-ant-api") {
                showError = true
                errorMessage = "That's an API key. Switch to the API Key tab."
                return
            }
            success = draftEngine.saveSubscriptionToken(trimmedInput)
        }

        if !success {
            showError = true
            errorMessage = "Failed to save credentials — try again"
        }
    }
}

// MARK: - API Key Form

private struct APIKeyForm: View {
    @Binding var input: String

    var body: some View {
        VStack(spacing: 8) {
            Text("Get your API key from console.anthropic.com")
                .font(.caption)
                .foregroundColor(.secondary)

            SecureField("sk-ant-...", text: $input)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 360)
        }
    }
}

// MARK: - Subscription Token Form

private struct SubscriptionTokenForm: View {
    @Binding var input: String
    @State private var copiedCommand = false

    private let command = "claude setup-token"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Use your Claude Pro or Max subscription instead of API billing.")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: 360)

            VStack(alignment: .leading, spacing: 10) {
                Step(number: "1", text: "Install the Claude CLI (if you haven't):")
                CodeBlock(text: "npm install -g @anthropic-ai/claude-code")

                Step(number: "2", text: "Generate a setup token:")
                HStack(spacing: 8) {
                    CodeBlock(text: command)
                    Button(copiedCommand ? "Copied!" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                        copiedCommand = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedCommand = false }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Step(number: "3", text: "Paste the token here:")
                SecureField("Paste setup-token output...", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)
            }

            Text("Tokens can expire. If you see an auth error, re-run `claude setup-token`.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: 360, alignment: .leading)
    }
}

// MARK: - Helper Views

private struct Step: View {
    let number: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(number + ".")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
                .frame(width: 14, alignment: .trailing)
            Text(text)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

private struct CodeBlock: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.gray.opacity(0.12))
            .cornerRadius(4)
    }
}
