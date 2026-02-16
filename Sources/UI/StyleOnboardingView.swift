// StyleOnboardingView.swift
// Onboarding: intro → paste writing samples → Sonnet builds a style profile

import SwiftUI

struct StyleOnboardingView: View {
    @ObservedObject var styleEngine: StyleEngine
    @ObservedObject var draftEngine: DraftEngine

    enum Step { case intro, samples, result }

    @State private var step: Step = .intro
    @State private var nameInput = UserDefaults.standard.string(forKey: "user-display-name") ?? ""
    @State private var samplesText = ""
    @State private var isAnalyzing = false
    @State private var generatedProfile: String?
    @State private var analysisError: String?

    private var wordCount: Int {
        samplesText.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    var body: some View {
        VStack(spacing: 0) {
            switch step {
            case .intro:
                introView
            case .samples:
                sampleInputView
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
                TextField("e.g. r3dbars", text: $nameInput)
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
                withAnimation { step = .samples }
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

    // MARK: - Step 2: Paste Samples

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
                    // Go back to samples to add more
                    generatedProfile = nil
                    withAnimation { step = .samples }
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

    private func buildProfile() async {
        guard let apiKey = draftEngine.getAPIKey() else {
            analysisError = "No API key found"
            return
        }

        isAnalyzing = true
        analysisError = nil

        do {
            let profile = try await styleEngine.importBulkSamples(
                rawText: samplesText,
                apiKey: apiKey
            )
            generatedProfile = profile
            withAnimation { step = .result }
        } catch {
            analysisError = "Analysis failed: \(error.localizedDescription)"
        }

        isAnalyzing = false
    }
}
