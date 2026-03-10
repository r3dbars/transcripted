// StyleOnboardingView.swift
// Onboarding: intro (name) → build style profile with Claude or ChatGPT → paste back

import SwiftUI
import AppKit

struct StyleOnboardingView: View {
    @ObservedObject var styleEngine: StyleEngine

    enum Step { case intro, buildProfile }

    @State private var step: Step = .intro
    @State private var nameInput = UserDefaults.standard.string(forKey: "user-display-name") ?? ""
    @State private var pastedProfile = ""
    @State private var saveError: String?

    var body: some View {
        VStack(spacing: 0) {
            switch step {
            case .intro:
                introView
            case .buildProfile:
                buildProfileView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Step 1: Intro / Name

    private var introView: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "hand.wave.fill")
                .font(.system(size: 50))
                .foregroundColor(.purple)

            Text("Welcome to Draft")
                .font(.title)
                .fontWeight(.bold)

            Text("Draft writes messages in **your** voice — not generic AI.\nFirst, let's make sure we know who you are.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 450)

            VStack(alignment: .leading, spacing: 6) {
                Text("Your full name")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("e.g. r3dbars", text: $nameInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 350)
                    .font(.title3)
            }

            if !nameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let trimmedName = nameInput.trimmingCharacters(in: .whitespacesAndNewlines)
                Text("Nice to meet you, \(trimmedName)!")
                    .font(.headline)
                    .foregroundColor(.purple)
                    .transition(.opacity)
            }

            Button(action: {
                let trimmed = nameInput.trimmingCharacters(in: .whitespacesAndNewlines)
                UserDefaults.standard.set(trimmed, forKey: "user-display-name")
                withAnimation { step = .buildProfile }
            }) {
                HStack {
                    Text("Next — Build My Writing Profile")
                    Image(systemName: "arrow.right")
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 24)
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
            .disabled(nameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button("Skip for Now") {
                let trimmed = nameInput.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    UserDefaults.standard.set(trimmed, forKey: "user-display-name")
                }
                styleEngine.completeOnboarding()
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .font(.caption)

            Spacer()
        }
        .padding(30)
    }

    // MARK: - Step 2: Build Profile with Claude or ChatGPT

    private var buildProfileView: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "sparkles")
                    .font(.system(size: 36))
                    .foregroundColor(.purple)
                    .padding(.top, 16)

                Text("Build Your Writing Profile")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Click a button to open a prompt in Claude or ChatGPT.\nPaste the result back here.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)

                // Claude / ChatGPT buttons
                HStack(spacing: 12) {
                    Button(action: { openProfilePrompt(service: .claude) }) {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkle")
                                .font(.system(size: 14))
                            Text("Build with Claude")
                                .font(.subheadline)
                                .fontWeight(.medium)
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, 16)
                        .background(Color(red: 0.85, green: 0.65, blue: 0.45).opacity(0.15))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color(red: 0.85, green: 0.65, blue: 0.45).opacity(0.4), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)

                    Button(action: { openProfilePrompt(service: .chatgpt) }) {
                        HStack(spacing: 6) {
                            Image(systemName: "circle.hexagonpath")
                                .font(.system(size: 14))
                            Text("Build with ChatGPT")
                                .font(.subheadline)
                                .fontWeight(.medium)
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, 16)
                        .background(Color.green.opacity(0.08))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.green.opacity(0.3), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }

                // Paste box
                VStack(alignment: .leading, spacing: 6) {
                    Text("Paste your generated profile here:")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    TextEditor(text: $pastedProfile)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, minHeight: 150, maxHeight: 200)
                        .scrollContentBackground(.hidden)
                        .background(Color(nsColor: .textBackgroundColor))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                        )
                        .overlay(alignment: .topLeading) {
                            if pastedProfile.isEmpty {
                                Text("Copy the output from Claude or ChatGPT\nand paste it here...")
                                    .foregroundColor(.secondary)
                                    .italic()
                                    .font(.caption)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 8)
                                    .allowsHitTesting(false)
                            }
                        }
                }

                if let error = saveError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }

                // Save button
                Button(action: { saveProfile() }) {
                    HStack {
                        Image(systemName: "checkmark")
                        Text("Save My Profile")
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 24)
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .disabled(pastedProfile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("Skip for Now") {
                    styleEngine.completeOnboarding()
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .font(.caption)
                .padding(.bottom, 8)
            }
            .padding(.horizontal, 24)
        }
    }

    // MARK: - Actions

    private enum AIService { case claude, chatgpt }

    private func openProfilePrompt(service: AIService) {
        let prompt = Self.styleProfilePrompt
        guard let encoded = prompt.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return }

        let urlString: String
        switch service {
        case .claude:
            urlString = "https://claude.ai/new?q=\(encoded)"
        case .chatgpt:
            urlString = "https://chatgpt.com/?q=\(encoded)"
        }

        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    private func saveProfile() {
        let trimmed = pastedProfile.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            saveError = "Please paste your generated profile first"
            return
        }

        styleEngine.saveImportedProfile(trimmed)
        styleEngine.completeOnboarding()
    }

    // MARK: - Prompt

    /// The prompt injected into Claude or ChatGPT to generate a writing style profile.
    /// Short enough to fit in a URL query param. Leverages the AI's memory of the user's
    /// conversation history so they just hit enter and get the profile immediately.
    static let styleProfilePrompt = """
    Based on everything you know about how I write from our conversations, generate a writing style profile for me. Use these exact section headers in bold: Tone and Voice, Sentence Patterns, Openings and Closings, Punctuation and Formatting, Signature Phrases (bullet list of my phrases in quotes), ALWAYS (5-10 bullet rules a ghostwriter must follow), NEVER (5-10 bullet rules for things I would never write). Write in second person. Be specific and quote my actual phrases. Start directly with the first section, no title. Output plain text I can copy-paste.
    """
}
