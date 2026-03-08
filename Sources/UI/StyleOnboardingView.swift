// StyleOnboardingView.swift
// Onboarding: intro → source choice → (iMessage preview OR paste samples) → Sonnet builds a style profile

import SwiftUI
import AppKit

struct StyleOnboardingView: View {
    @ObservedObject var styleEngine: StyleEngine
    @ObservedObject var draftEngine: DraftEngine

    enum Step { case intro, sourceChoice, samples, imessagePreview, result }

    @State private var step: Step = .intro
    @State private var nameInput = UserDefaults.standard.string(forKey: "user-display-name") ?? ""
    @State private var samplesText = ""
    @State private var isAnalyzing = false
    @State private var generatedProfile: String?
    @State private var analysisError: String?

    // iMessage import state
    @State private var importedMessages: [iMessageReader.ImportedMessage] = []
    @State private var isLoadingMessages = false
    @State private var messageLoadError: String?
    @State private var formattedMessageText = ""
    @State private var showSupplementInput = false
    @State private var supplementText = ""

    private var wordCount: Int {
        samplesText.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    var body: some View {
        VStack(spacing: 0) {
            switch step {
            case .intro:
                introView
            case .sourceChoice:
                sourceChoiceView
            case .samples:
                sampleInputView
            case .imessagePreview:
                imessagePreviewView
            case .result:
                if let profile = generatedProfile {
                    profileResultView(profile: profile)
                }
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
                Text("We use this to find your messages when you paste conversations")
                    .font(.caption2)
                    .foregroundColor(.secondary)
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
                #if BETA_BUILD
                withAnimation { step = .samples }
                #else
                withAnimation { step = .sourceChoice }
                #endif
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

    // MARK: - Step 2: Source Choice

    private var sourceChoiceView: some View {
        let name = nameInput.trimmingCharacters(in: .whitespacesAndNewlines)

        return VStack(spacing: 24) {
            Spacer()

            Image(systemName: "sparkles")
                .font(.system(size: 40))
                .foregroundColor(.purple)

            Text("How should we learn \(name)'s style?")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Choose how to provide writing samples for your style profile.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 450)

            HStack(spacing: 16) {
                // iMessage card
                Button(action: { loadIMessages() }) {
                    VStack(spacing: 12) {
                        Image(systemName: "message.fill")
                            .font(.system(size: 32))
                            .foregroundColor(.blue)

                        Text("Import from iMessages")
                            .font(.headline)

                        Text("Recommended")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.blue)

                        Text("Automatically reads your recent texts.\nZero effort, rich data.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)

                        Text("One-time read. Raw messages\nare discarded after analysis.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .italic()
                            .padding(.top, 4)
                    }
                    .frame(maxWidth: 220, minHeight: 200)
                    .padding(20)
                    .background(Color.blue.opacity(0.05))
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.blue.opacity(0.3), lineWidth: 1.5)
                    )
                }
                .buttonStyle(.plain)

                // Manual paste card
                Button(action: { withAnimation { step = .samples } }) {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 32))
                            .foregroundColor(.purple)

                        Text("Paste Samples Manually")
                            .font(.headline)

                        Text("Copy-paste messages from\nSlack, email, or texts.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.top, 4)
                    }
                    .frame(maxWidth: 220, minHeight: 200)
                    .padding(20)
                    .background(Color.purple.opacity(0.05))
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.purple.opacity(0.2), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }

            Button("Skip for Now") {
                styleEngine.completeOnboarding()
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .font(.caption)

            Spacer()
        }
        .padding(30)
    }

    // MARK: - Step 3a: iMessage Preview

    private var imessagePreviewView: some View {
        let name = nameInput.trimmingCharacters(in: .whitespacesAndNewlines)

        return VStack(spacing: 20) {
            Spacer()

            if isLoadingMessages {
                // Loading state
                ProgressView()
                    .controlSize(.regular)
                Text("Reading \(name)'s messages...")
                    .font(.headline)
                    .foregroundColor(.secondary)
                Text("This may take a moment.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if let error = messageLoadError {
                // Error state
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.orange)

                Text("Couldn't Read iMessages")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text(error)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 450)

                HStack(spacing: 12) {
                    if error.contains("Full Disk Access") || error.contains("authorization") || error.contains("permission") {
                        Button(action: {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                                NSWorkspace.shared.open(url)
                            }
                        }) {
                            HStack {
                                Image(systemName: "gear")
                                Text("Open System Settings")
                            }
                            .padding(.vertical, 8)
                            .padding(.horizontal, 16)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)

                        Button("Try Again") { loadIMessages() }
                            .buttonStyle(.bordered)
                    }

                    Button("Use Manual Paste Instead") {
                        messageLoadError = nil
                        withAnimation { step = .samples }
                    }
                    .buttonStyle(.bordered)
                }
            } else if isAnalyzing {
                // Analyzing state
                ProgressView()
                    .controlSize(.regular)
                Text("Analyzing \(name)'s writing style...")
                    .font(.headline)
                    .foregroundColor(.secondary)
                Text("Building your personalized style profile...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                // Preview state — messages loaded, awaiting approval
                Image(systemName: "message.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.blue)

                Text("Preview Your Messages")
                    .font(.title2)
                    .fontWeight(.semibold)

                // Privacy notice
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield.fill")
                        .foregroundColor(.blue)
                    Text("This is a one-time analysis. Your raw messages are never saved — only the generated writing profile is kept.")
                        .font(.caption)
                }
                .padding(12)
                .frame(maxWidth: 560)
                .background(Color.blue.opacity(0.08))
                .cornerRadius(8)

                // Message preview
                ScrollView {
                    Text(formattedMessageText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: 530, alignment: .leading)
                        .padding(10)
                }
                .frame(maxWidth: 560, maxHeight: 250)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )

                Text("\(importedMessages.count) messages from your iMessage history")
                    .font(.caption)
                    .foregroundColor(.secondary)

                // Supplement with additional samples
                VStack(spacing: 8) {
                    Button(action: { withAnimation { showSupplementInput.toggle() } }) {
                        HStack(spacing: 6) {
                            Image(systemName: showSupplementInput ? "chevron.down" : "chevron.right")
                                .font(.caption2)
                            Image(systemName: "plus.circle")
                                .foregroundColor(.purple)
                            Text("Add Slack, email, or other writing samples")
                                .font(.caption)
                                .foregroundColor(.purple)
                        }
                    }
                    .buttonStyle(.plain)

                    if showSupplementInput {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Paste additional writing samples to enrich your profile:")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            TextEditor(text: $supplementText)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: 560, minHeight: 100, maxHeight: 150)
                                .scrollContentBackground(.hidden)
                                .background(Color(nsColor: .textBackgroundColor))
                                .cornerRadius(8)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.purple.opacity(0.3), lineWidth: 1)
                                )
                                .overlay(alignment: .topLeading) {
                                    if supplementText.isEmpty {
                                        Text("Paste Slack messages, emails, etc...")
                                            .foregroundColor(.secondary)
                                            .italic()
                                            .font(.caption)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 8)
                                            .allowsHitTesting(false)
                                    }
                                }

                            let supplementWords = supplementText.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
                            if supplementWords > 0 {
                                Text("+ \(supplementWords) words from pasted samples")
                                    .font(.caption2)
                                    .foregroundColor(.purple)
                            }
                        }
                    }
                }
                .frame(maxWidth: 560)

                if let error = analysisError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }

                // Actions
                HStack(spacing: 12) {
                    Button(action: {
                        let combined: String
                        let trimmedSupplement = supplementText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmedSupplement.isEmpty {
                            combined = formattedMessageText
                        } else {
                            combined = formattedMessageText + "\n\n---\n\n" + trimmedSupplement
                        }
                        Task { await buildProfile(from: combined) }
                    }) {
                        HStack {
                            Image(systemName: "sparkles")
                            Text("Analyze These Messages")
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 20)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)

                    Button("Go Back") {
                        importedMessages = []
                        formattedMessageText = ""
                        withAnimation { step = .sourceChoice }
                    }
                    .buttonStyle(.bordered)
                }
            }

            Button("Skip for Now") {
                styleEngine.completeOnboarding()
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .font(.caption)
            .disabled(isAnalyzing || isLoadingMessages)

            Spacer()
        }
        .padding(30)
    }

    // MARK: - Step 3b: Paste Samples

    private var sampleInputView: some View {
        let name = nameInput.trimmingCharacters(in: .whitespacesAndNewlines)

        return VStack(spacing: 20) {
            Spacer()

            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 40))
                .foregroundColor(.purple)

            Text("Let's learn how \(name) writes")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Paste your real messages below — Slack threads, text conversations, emails, anything.\nOther people's messages are fine — we'll look for **\(name)** and focus on yours.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 500)

            // Input area
            VStack(alignment: .leading, spacing: 6) {
                TextEditor(text: $samplesText)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: 550, minHeight: 250, maxHeight: 350)
                    .scrollContentBackground(.hidden)
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )
                    .overlay(alignment: .topLeading) {
                        if samplesText.isEmpty {
                            Text("Paste your Slack messages, texts, emails here...\n\nOther people's messages, timestamps, reactions — all fine.\nWe'll find \(name)'s messages and learn from those.")
                                .foregroundColor(.secondary)
                                .italic()
                                .padding(.horizontal, 5)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                    }
                    .disabled(isAnalyzing)

                HStack {
                    Text("\(wordCount) words")
                        .font(.caption)
                        .foregroundColor(wordCount > 50 ? .green : .secondary)

                    if wordCount > 0 && wordCount < 50 {
                        Text("— more is better! Aim for 100+ words")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }

                    Spacer()
                }
                .frame(maxWidth: 550)
            }

            if let error = analysisError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            // Actions
            if isAnalyzing {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Analyzing \(name)'s writing style...")
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 8)
            } else {
                Button(action: { Task { await buildProfile() } }) {
                    HStack {
                        Image(systemName: "sparkles")
                        Text("Build My Profile")
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 20)
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .disabled(samplesText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Button("Skip for Now") {
                styleEngine.completeOnboarding()
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .font(.caption)
            .disabled(isAnalyzing)

            Spacer()
        }
        .padding(30)
    }

    // MARK: - Step 3: Profile Result

    private func profileResultView(profile: String) -> some View {
        let name = nameInput.trimmingCharacters(in: .whitespacesAndNewlines)

        return VStack(spacing: 20) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundColor(.green)

            Text("\(name)'s Writing Profile")
                .font(.title2)
                .fontWeight(.semibold)

            ScrollView {
                Text(profile)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: 550, alignment: .leading)
                    .padding()
            }
            .frame(maxWidth: 580, maxHeight: 300)
            .background(Color.purple.opacity(0.05))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.purple.opacity(0.2), lineWidth: 1)
            )

            HStack(spacing: 16) {
                Button(action: {
                    styleEngine.completeOnboarding()
                }) {
                    HStack {
                        Image(systemName: "checkmark")
                        Text("Looks Good — Let's Go")
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 20)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)

                Button(action: {
                    // Go back to source choice to add more
                    generatedProfile = nil
                    withAnimation { step = .sourceChoice }
                }) {
                    HStack {
                        Image(systemName: "plus")
                        Text("Add More & Regenerate")
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 20)
                }
                .buttonStyle(.bordered)
            }

            Spacer()
        }
        .padding(30)
    }

    // MARK: - Analysis

    private func buildProfile(from text: String? = nil) async {
        guard let auth = draftEngine.getAuth() else {
            analysisError = "No credentials configured"
            return
        }

        let sourceText = text ?? samplesText

        isAnalyzing = true
        analysisError = nil

        do {
            let profile = try await styleEngine.importBulkSamples(
                rawText: sourceText,
                auth: auth
            )
            generatedProfile = profile
            withAnimation { step = .result }
            EventTracker.track("onboarding.completed", with: ["example_count": "\(styleEngine.exampleCount)"])
        } catch {
            analysisError = "Analysis failed: \(error.localizedDescription)"
        }

        isAnalyzing = false
    }

    // MARK: - iMessage Loading

    private func loadIMessages() {
        isLoadingMessages = true
        messageLoadError = nil
        withAnimation { step = .imessagePreview }

        Task {
            let reader = iMessageReader()
            do {
                let messages = try await reader.readMessages()
                let formatted = await reader.formatForAnalysis(messages)
                await MainActor.run {
                    importedMessages = messages
                    formattedMessageText = formatted
                    isLoadingMessages = false
                }
            } catch {
                await MainActor.run {
                    messageLoadError = error.localizedDescription
                    isLoadingMessages = false
                }
            }
        }
    }
}
