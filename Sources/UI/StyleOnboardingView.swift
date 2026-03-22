// StyleOnboardingView.swift
// Onboarding: intro (name) → agentImport (clipboard prompt builder) → result

import SwiftUI
import AppKit

struct StyleOnboardingView: View {
    @ObservedObject var styleEngine: StyleEngine
    @ObservedObject var localInference: LocalInferenceManager

    enum Step { case intro, agentImport, samples, result }

    @State private var step: Step = .intro
    @State private var nameInput = UserDefaults.standard.string(forKey: "user-display-name") ?? ""
    @State private var pastedSamples = ""
    @State private var generatedProfile = ""
    @State private var errorMessage: String?
    @State private var isAnalyzing = false

    // Agent import state
    @State private var pastedProfile = ""
    @State private var promptCopied = false

    private static let agentPrompt = """
        Analyze how I write based on our conversation history. Give me a style profile in this exact format:

        TONE: [1-2 sentences — casual/formal, warm/direct, etc.]
        SENTENCE LENGTH: [short/medium/long, any patterns]
        OPENINGS: [how I typically start messages]
        CLOSINGS: [how I typically end messages]
        PUNCTUATION: [habits — Oxford comma, ellipses, exclamation points, etc.]
        WORDS I USE: [phrases or words that show up a lot]
        WORDS I NEVER USE: [things that would sound wrong coming from me]
        FORMALITY BY CONTEXT: [how I shift between Slack vs email vs iMessage]
        EXAMPLE: [write one sample message in my voice about anything]
        """

    var body: some View {
        VStack(spacing: 0) {
            switch step {
            case .intro:
                introView
            case .agentImport:
                agentImportView
            case .samples:
                samplesView
            case .result:
                resultView
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
                TextField("e.g. Justin Betker", text: $nameInput)
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
                withAnimation { step = .agentImport }
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

    // MARK: - Step 2: Agent Import (Clipboard Prompt Builder)

    private var agentImportView: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "sparkles")
                    .font(.system(size: 36))
                    .foregroundColor(.purple)
                    .padding(.top, 16)

                Text("Build your style profile")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Ask any AI that knows you — Claude, ChatGPT, OpenAI — to describe how you write. Copy the prompt below, paste it into your AI, then paste the result back here.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)

                // Read-only prompt box
                Text(Self.agentPrompt)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.purple.opacity(0.3), lineWidth: 1)
                    )
                    .onTapGesture {
                        copyPromptToClipboard()
                    }

                // Copy Prompt button
                Button(action: { copyPromptToClipboard() }) {
                    HStack(spacing: 6) {
                        Image(systemName: promptCopied ? "checkmark" : "doc.on.doc")
                        Text(promptCopied ? "Copied!" : "Copy Prompt")
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 14)
                }
                .buttonStyle(.bordered)
                .tint(.purple)

                // Paste area for AI-generated profile
                TextEditor(text: $pastedProfile)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, minHeight: 120, maxHeight: 180)
                    .scrollContentBackground(.hidden)
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )
                    .overlay(alignment: .topLeading) {
                        if pastedProfile.isEmpty {
                            Text("Paste the AI-generated style profile here...")
                                .foregroundColor(.secondary)
                                .italic()
                                .font(.caption)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                    }

                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }

                // Import Profile button
                Button(action: { importAgentProfile() }) {
                    HStack {
                        Image(systemName: "arrow.down.doc")
                        Text("Import Profile")
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 16)
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .disabled(pastedProfile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                // Alternative: paste raw samples for local analysis
                Button("Or paste writing samples for local analysis") {
                    withAnimation { step = .samples }
                }
                .buttonStyle(.plain)
                .foregroundColor(.purple)
                .font(.caption)

                Button("Skip — I'll build my profile from scratch") {
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

    // MARK: - Step 3: Paste Samples (alternative path)

    private var samplesView: some View {
        ScrollView {
            VStack(spacing: 14) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 32))
                    .foregroundColor(.purple)
                    .padding(.top, 16)

                Text("Paste Your Writing")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Paste messages you've written — Slack, texts, emails.\nMessy is fine. The more, the better.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)

                TextEditor(text: $pastedSamples)
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
                        if pastedSamples.isEmpty {
                            Text("Paste your messages here...\ne.g. Slack threads, text conversations, emails")
                                .foregroundColor(.secondary)
                                .italic()
                                .font(.caption)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                    }

                HStack {
                    let wordCount = pastedSamples.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
                    Text("\(wordCount) words")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }

                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }

                HStack(spacing: 12) {
                    Button("Back") {
                        withAnimation { step = .agentImport }
                    }
                    .buttonStyle(.bordered)

                    Button(action: { analyzePastedSamples() }) {
                        HStack {
                            if isAnalyzing {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(isAnalyzing ? "Analyzing..." : "Build My Profile")
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 16)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .disabled(pastedSamples.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAnalyzing || !localInference.isReady)
                }

                if !localInference.isReady {
                    Text("Waiting for language model to load...")
                        .font(.caption)
                        .foregroundColor(.orange)
                }

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

    // MARK: - Step 4: Result

    private var resultView: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 32))
                .foregroundColor(.green)
                .padding(.top, 16)

            Text("Your Writing Profile")
                .font(.title2)
                .fontWeight(.semibold)

            ScrollView {
                Text(generatedProfile)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.green.opacity(0.3), lineWidth: 1)
            )
            .padding(.horizontal, 20)

            HStack(spacing: 12) {
                Button("Start Over") {
                    withAnimation { step = .agentImport }
                }
                .buttonStyle(.bordered)

                Button(action: {
                    styleEngine.completeOnboarding()
                    EventTracker.track("onboarding.completed", with: ["source": "local"])
                }) {
                    HStack {
                        Image(systemName: "checkmark")
                        Text("Looks Good")
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 16)
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
            }
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Actions

    private func copyPromptToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.agentPrompt, forType: .string)
        promptCopied = true
        // Reset after 2 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            promptCopied = false
        }
    }

    private func importAgentProfile() {
        let text = pastedProfile.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        styleEngine.importProfile(text)
        generatedProfile = text
        withAnimation { step = .result }
    }

    private func analyzePastedSamples() {
        guard localInference.isReady else { return }
        let text = pastedSamples.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        isAnalyzing = true
        errorMessage = nil
        Task {
            do {
                let profile = try await styleEngine.importBulkSamples(rawText: text, draftEngine: localInference.draftEngine)
                generatedProfile = profile
                isAnalyzing = false
                withAnimation { step = .result }
            } catch {
                isAnalyzing = false
                errorMessage = "Analysis failed: \(error.localizedDescription)"
            }
        }
    }
}
