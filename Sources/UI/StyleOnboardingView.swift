// StyleOnboardingView.swift
// Onboarding: intro (name) → source choice → (iMessage / paste samples) → local analysis → result

import SwiftUI
import AppKit

struct StyleOnboardingView: View {
    @ObservedObject var styleEngine: StyleEngine
    @ObservedObject var localInference: LocalInferenceManager

    enum Step { case intro, sourceChoice, imessagePreview, samples, result }

    @State private var step: Step = .intro
    @State private var nameInput = UserDefaults.standard.string(forKey: "user-display-name") ?? ""
    @State private var pastedSamples = ""
    @State private var generatedProfile = ""
    @State private var errorMessage: String?
    @State private var isAnalyzing = false

    // iMessage state
    @State private var loadedMessages: [iMessageReader.ImportedMessage] = []
    @State private var imessageError: String?
    @State private var isLoadingMessages = false
    @State private var supplementText = ""
    @State private var showSupplement = false

    private let reader = iMessageReader()

    var body: some View {
        VStack(spacing: 0) {
            switch step {
            case .intro:
                introView
            case .sourceChoice:
                sourceChoiceView
            case .imessagePreview:
                imessagePreviewView
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
                withAnimation { step = .sourceChoice }
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
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "sparkles")
                .font(.system(size: 36))
                .foregroundColor(.purple)

            Text("Build Your Writing Profile")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Draft analyzes your writing on-device to learn your style.\nChoose how to provide samples:")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            VStack(spacing: 12) {
                // iMessage import card
                Button(action: { loadIMessages() }) {
                    HStack(spacing: 12) {
                        Image(systemName: "message.fill")
                            .font(.title2)
                            .foregroundColor(.blue)
                            .frame(width: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Import from iMessages")
                                .font(.body)
                                .fontWeight(.medium)
                            Text("Recommended — zero effort, best results")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundColor(.secondary)
                    }
                    .padding(14)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.blue.opacity(0.3), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

                // Paste samples card
                Button(action: { withAnimation { step = .samples } }) {
                    HStack(spacing: 12) {
                        Image(systemName: "doc.on.clipboard")
                            .font(.title2)
                            .foregroundColor(.purple)
                            .frame(width: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Paste Writing Samples")
                                .font(.body)
                                .fontWeight(.medium)
                            Text("Paste Slack messages, emails, or texts")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundColor(.secondary)
                    }
                    .padding(14)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.purple.opacity(0.3), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 30)

            if isLoadingMessages {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading messages...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if let error = imessageError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
            }

            Button("Skip for Now") {
                styleEngine.completeOnboarding()
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .font(.caption)

            Spacer()
        }
        .padding(24)
    }

    // MARK: - Step 3a: iMessage Preview

    private var imessagePreviewView: some View {
        VStack(spacing: 12) {
            Text("Your Messages")
                .font(.title2)
                .fontWeight(.semibold)
                .padding(.top, 16)

            Text("\(loadedMessages.count) messages loaded — these stay on your device.")
                .font(.callout)
                .foregroundColor(.secondary)

            // Message preview
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(loadedMessages.prefix(50), id: \.text) { msg in
                        Text(msg.text)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if loadedMessages.count > 50 {
                        Text("... and \(loadedMessages.count - 50) more")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .italic()
                    }
                }
                .padding(10)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
            )
            .padding(.horizontal, 20)

            // Supplement section
            DisclosureGroup(isExpanded: $showSupplement) {
                TextEditor(text: $supplementText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 60)
                    .scrollContentBackground(.hidden)
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )
            } label: {
                Text("Add Slack, email, or other writing samples")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 20)

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            HStack(spacing: 12) {
                Button("Back") {
                    withAnimation { step = .sourceChoice }
                }
                .buttonStyle(.bordered)

                Button(action: { analyzeIMessages() }) {
                    HStack {
                        if isAnalyzing {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(isAnalyzing ? "Analyzing..." : "Analyze These Messages")
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 16)
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .disabled(isAnalyzing || !localInference.isReady)
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
        .padding(.horizontal, 4)
    }

    // MARK: - Step 3b: Paste Samples

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
                        withAnimation { step = .sourceChoice }
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
                Button("Add More & Regenerate") {
                    withAnimation { step = .sourceChoice }
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

    private func loadIMessages() {
        isLoadingMessages = true
        imessageError = nil
        Task {
            do {
                let messages = try await reader.readMessages(limit: DraftConstants.imessageDefaultLimit)
                loadedMessages = messages
                isLoadingMessages = false
                withAnimation { step = .imessagePreview }
            } catch let error as iMessageReader.ReaderError {
                isLoadingMessages = false
                switch error {
                case .accessDenied:
                    imessageError = "Full Disk Access required. Open System Settings > Privacy & Security > Full Disk Access and add Draft."
                case .databaseNotFound:
                    imessageError = "iMessage database not found. Try pasting samples instead."
                case .databaseEmpty:
                    imessageError = "No substantive messages found. Try pasting samples instead."
                case .queryFailed(let msg):
                    imessageError = "Failed to read messages: \(msg)"
                }
            } catch {
                isLoadingMessages = false
                imessageError = "Failed to load messages: \(error.localizedDescription)"
            }
        }
    }

    private func analyzeIMessages() {
        guard localInference.isReady else { return }
        isAnalyzing = true
        errorMessage = nil
        Task {
            do {
                var rawText = await reader.formatForAnalysis(loadedMessages, maxMessages: DraftConstants.imessageAnalysisLimit)
                let supplement = supplementText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !supplement.isEmpty {
                    rawText += "\n\n--- Additional Samples ---\n\n" + supplement
                }
                let profile = try await styleEngine.importBulkSamples(rawText: rawText, draftEngine: localInference.draftEngine)
                generatedProfile = profile
                isAnalyzing = false
                withAnimation { step = .result }
            } catch {
                isAnalyzing = false
                errorMessage = "Analysis failed: \(error.localizedDescription)"
            }
        }
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
