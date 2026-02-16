// StyleEngine.swift
// Manages style.md — the single file that teaches Haiku how the user writes

import Foundation
import SwiftUI

@MainActor
class StyleEngine: ObservableObject {
    @Published var exampleCount = 0
    @Published var styleFileContents = ""
    @Published var hasCompletedOnboarding: Bool

    private let storageDir: URL
    private let styleFileURL: URL

    private static let defaultSystemPrompt = """
        You are a writing assistant. Take the user's rough spoken text and rewrite it as a clear, \
        well-structured message. Preserve the original meaning, intent, and tone. Don't add \
        information that wasn't in the original. Keep it concise and natural-sounding.
        """

    /// Returns a progressively deeper analysis prompt based on how many examples exist
    private static func styleAnalysisPrompt(forExampleCount count: Int) -> String {
        let baseInstruction = """
            You are analyzing writing samples from a single person to build their writing style profile. \
            Study every sample carefully. Write in second person ("You..."). Be specific — quote actual \
            phrases and patterns you observe. Never be generic. Every claim must be backed by evidence \
            from the samples. \
            IMPORTANT: Do NOT include a title or top-level heading. Start directly with the first section.
            """

        if count < 10 {
            // Early: foundation profile
            return baseInstruction + """

                Write a style profile covering these dimensions:

                **Tone & Voice**: What's their default register? Formal, casual, somewhere between? \
                How do they balance authority with approachability?

                **Sentence Patterns**: Short and punchy? Long and flowing? How do they vary length for effect?

                **Openings & Closings**: How do they start messages? How do they end them? \
                Do they use greetings? Sign-offs? Action-oriented closings?

                **Punctuation & Emphasis**: Exclamation marks, em dashes, italics, ellipses — \
                what's their punctuation fingerprint? How do they use formatting for emphasis?

                **Signature Phrases**: Any recurring words, expressions, or verbal tics that show up across samples?

                Format as a structured profile with the bold section headers above. Be thorough but concise.
                """
        } else if count < 20 {
            // Growing: add deeper patterns
            return baseInstruction + """

                Write a detailed style profile covering these dimensions:

                **Tone & Voice**: Default register, how they balance authority with warmth. \
                Do they use humor? How?

                **Sentence Patterns**: Length variation, rhythm. How do they use short sentences \
                for impact vs. longer ones for explanation?

                **Openings & Closings**: How they start and end messages. Greeting patterns, \
                sign-off patterns, action-oriented closings.

                **Punctuation & Emphasis**: Their punctuation fingerprint — exclamation marks, \
                em dashes, italics, formatting choices. How heavily do they use each?

                **Argument Structure**: How do they build a point? Do they lead with the conclusion \
                or build up to it? How do they handle agreement vs. disagreement?

                **Paragraph Flow**: How do they transition between ideas? Short paragraphs or long? \
                Do they use one-line paragraphs for emphasis?

                **Emotional Range**: How do they express enthusiasm, concern, criticism, agreement? \
                What's their range from most casual to most serious?

                **Signature Phrases**: Recurring words, expressions, verbal tics, and characteristic \
                ways of phrasing things.

                Format as a structured profile with the bold section headers above. Be thorough — \
                this profile will be used to write messages in this person's voice.
                """
        } else {
            // Mature: full persona
            return baseInstruction + """

                Write a comprehensive style profile covering these dimensions:

                **Tone & Voice**: Default register, authority-warmth balance, use of humor. \
                How does their voice differ from generic professional writing?

                **Sentence Patterns**: Length variation and rhythm. How they use fragments, \
                how they build momentum, where they place their strongest words.

                **Openings & Closings**: Exact opening and closing patterns. How they vary \
                these based on context (quick reply vs. detailed response).

                **Punctuation & Emphasis**: Full fingerprint — exclamation frequency, em dash usage, \
                italics patterns, double punctuation habits, formatting choices.

                **Argument Structure**: How they build and defend points. Lead with conclusion or build up? \
                How they handle agreement, partial agreement, and disagreement. How they give feedback.

                **Paragraph Flow & Transitions**: Paragraph length patterns, how they transition \
                between topics, use of one-line paragraphs for emphasis.

                **Emotional Range**: Full spectrum — enthusiasm, concern, criticism, encouragement, \
                urgency. How do they modulate intensity?

                **Vocabulary Signatures**: Words and phrases that are uniquely theirs. Jargon preferences. \
                Filler words they use or avoid. How technical vs. accessible they aim to be.

                **Contextual Adaptation**: How their style shifts between quick acknowledgments, \
                detailed feedback, brainstorming, and formal communication.

                **What Makes Them Them**: The 2-3 qualities that most distinguish this person's writing \
                from a generic AI or average professional. What would be lost if you smoothed out \
                their style?

                Format as a structured profile with the bold section headers above. This profile will be \
                used to write messages that are indistinguishable from this person's actual writing. \
                Be as specific and evidence-based as possible.
                """
        }
    }

    init() {
        hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "style-onboarding-completed")

        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        storageDir = appSupport.appendingPathComponent("Draft", isDirectory: true)
        styleFileURL = storageDir.appendingPathComponent("style.md")

        // Create directory if needed
        try? FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)

        // Load existing file
        loadStyleFile()
    }

    func completeOnboarding() {
        hasCompletedOnboarding = true
        UserDefaults.standard.set(true, forKey: "style-onboarding-completed")
    }

    // MARK: - Public Interface

    /// Build system prompt — includes only the Style Summary (not all examples)
    func buildSystemPrompt() -> String {
        let summary = extractStyleSummary()
        guard !summary.isEmpty else {
            return Self.defaultSystemPrompt
        }

        return """
            You are ghostwriting as a specific person. Their writing style profile follows:

            \(summary)

            Your job is to take their rough, unpolished text and rewrite it as they would naturally write it. \
            Embody their voice completely — use their vocabulary, mirror their sentence rhythms, match how \
            they open and close messages, replicate their punctuation habits and emphasis patterns. \
            The output should be indistinguishable from something they actually wrote. \
            Preserve the original meaning, intent, and all information. Don't add anything they didn't say. \
            Don't over-polish — if they write casually, keep it casual. Match their energy level.
            """
    }

    /// Extract just the Style Summary section from style.md
    private func extractStyleSummary() -> String {
        guard let summaryStart = styleFileContents.range(of: "## Style Summary\n") else { return "" }
        let afterSummary = styleFileContents[summaryStart.upperBound...]
        // Summary ends at the next "##" section or end of file
        if let nextSection = afterSummary.range(of: "\n##") {
            let summary = String(afterSummary[..<nextSection.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            // Don't return the placeholder text
            return summary == "(Will be generated after 5 examples)" ? "" : summary
        }
        let summary = String(afterSummary).trimmingCharacters(in: .whitespacesAndNewlines)
        return summary == "(Will be generated after 5 examples)" ? "" : summary
    }

    /// Record an accepted example (called on Copy or Paste-to-last-app)
    func recordExample(acceptedMessage: String) {
        exampleCount += 1
        let exampleBlock = """

            ### Example \(exampleCount)
            \(acceptedMessage.trimmingCharacters(in: .whitespacesAndNewlines))
            """

        if styleFileContents.isEmpty {
            // First example — create the file structure
            styleFileContents = """
                # Writing Style Profile

                ## Style Summary
                (Will be generated after 5 examples)

                ## Accepted Examples
                \(exampleBlock)
                """
        } else {
            // Append to existing file
            styleFileContents += "\n" + exampleBlock
        }

        saveStyleFile()
    }

    /// Regenerate the Style Summary section using Sonnet
    func regenerateStyleSummary(apiKey: String) async {
        // Include both onboarding samples and accepted examples for full picture
        let onboardingSamples = extractOnboardingSamplesText()
        let examples = extractExamplesText()
        let allText = (onboardingSamples + "\n\n" + examples).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !allText.isEmpty else { return }

        do {
            let analysis = try await AnthropicAPI.draft(
                rawText: allText,
                apiKey: apiKey,
                systemPrompt: Self.styleAnalysisPrompt(forExampleCount: exampleCount),
                maxTokens: 4096,
                useModel: AnthropicAPI.sonnetModel
            )

            // Replace the Style Summary section (ends at Onboarding Samples or Accepted Examples)
            if let summaryRange = styleFileContents.range(of: "## Style Summary\n") {
                let nextSection = styleFileContents.range(of: "\n## Onboarding Samples")
                    ?? styleFileContents.range(of: "\n## Accepted Examples")
                if let endRange = nextSection {
                    let replacement = "## Style Summary\n" + analysis + "\n"
                    styleFileContents.replaceSubrange(summaryRange.lowerBound..<endRange.lowerBound, with: replacement)
                    saveStyleFile()
                }
            }
        } catch {
            print("⚠️ Style summary regeneration failed: \(error)")
        }
    }

    // MARK: - Bulk Import (Onboarding)

    /// Prompt for analyzing raw, messy writing samples from onboarding
    private static func bulkAnalysisPrompt(userName: String?) -> String {
        let nameClause = userName.flatMap { $0.isEmpty ? nil : $0 }
            .map { "The user's name is \($0). Focus ONLY on messages written by them." }
            ?? "Focus on identifying a single author's writing patterns across the samples."

        return """
            You are analyzing real writing samples to build a comprehensive writing style profile.

            These samples were copied directly from the user's messages — Slack, iMessage, email, \
            and other platforms. They may include:
            - Timestamps, sender names, channel names (ignore these)
            - Emoji reactions, thread indicators, quoted replies (ignore metadata)
            - Messages from OTHER people mixed in (focus only on the user's writing)

            \(nameClause)

            Analyze their writing across these dimensions:

            1. **Tone & Voice** — casual vs formal, warm vs direct, confident vs hedging. \
            How do they balance authority with approachability?
            2. **Sentence Patterns** — length, complexity, fragments vs complete sentences. \
            How do they vary rhythm for effect?
            3. **Openings & Closings** — how they start and end messages across different contexts.
            4. **Punctuation Fingerprint** — dashes, ellipses, exclamation points, emoji usage, \
            formatting choices.
            5. **Signature Phrases** — recurring words, filler phrases, verbal tics. Quote examples.
            6. **Argument Structure** — how they build points, handle agreement/disagreement.
            7. **Paragraph Flow** — short bursts vs long blocks, transition patterns.
            8. **Emotional Range** — how they express enthusiasm, concern, criticism, urgency.
            9. **Vocabulary Signatures** — distinctive word choices, jargon, slang preferences.
            10. **Contextual Adaptation** — how their style shifts across platforms and audiences.

            Write a detailed profile (400-600 words) that captures what makes this person's \
            writing THEM — not generic observations, but specific patterns a ghostwriter \
            would need to convincingly write as this person. Use second person ("You..."). \
            Quote actual phrases from the samples as evidence. \
            IMPORTANT: Do NOT include a title or top-level heading. Start directly with the first section.
            """
    }

    /// Import bulk writing samples from onboarding and generate initial style profile
    func importBulkSamples(rawText: String, apiKey: String) async throws -> String {
        let userName = UserDefaults.standard.string(forKey: "user-display-name")

        // Send to Sonnet for deep analysis
        let analysis = try await AnthropicAPI.draft(
            rawText: rawText,
            apiKey: apiKey,
            systemPrompt: Self.bulkAnalysisPrompt(userName: userName),
            maxTokens: 4096,
            useModel: AnthropicAPI.sonnetModel
        )

        // Build style.md with onboarding samples + generated summary
        styleFileContents = """
            # Writing Style Profile

            ## Style Summary
            \(analysis)

            ## Onboarding Samples
            \(rawText.trimmingCharacters(in: .whitespacesAndNewlines))

            ## Accepted Examples
            """

        saveStyleFile()
        return analysis
    }

    // MARK: - File I/O

    private func loadStyleFile() {
        if FileManager.default.fileExists(atPath: styleFileURL.path) {
            styleFileContents = (try? String(contentsOf: styleFileURL, encoding: .utf8)) ?? ""
            // Count examples by counting "### Example" occurrences
            exampleCount = styleFileContents.components(separatedBy: "### Example").count - 1
        }
    }

    private func saveStyleFile() {
        try? styleFileContents.write(to: styleFileURL, atomically: true, encoding: .utf8)
    }

    private func extractOnboardingSamplesText() -> String {
        guard let start = styleFileContents.range(of: "## Onboarding Samples\n") else { return "" }
        let afterStart = styleFileContents[start.upperBound...]
        if let nextSection = afterStart.range(of: "\n## ") {
            return String(afterStart[..<nextSection.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(afterStart).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractExamplesText() -> String {
        guard let range = styleFileContents.range(of: "## Accepted Examples") else { return "" }
        return String(styleFileContents[range.lowerBound...])
    }
}
