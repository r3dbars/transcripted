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
        // Summary ends at "## Examples" or end of file
        if let nextSection = afterSummary.range(of: "\n##") {
            let summary = String(afterSummary[..<nextSection.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            return summary == "(Will be generated after 5 examples)" ? "" : summary
        }
        let summary = String(afterSummary).trimmingCharacters(in: .whitespacesAndNewlines)
        return summary == "(Will be generated after 5 examples)" ? "" : summary
    }

    // MARK: - Training Pair Recording

    /// Record a training pair — what the AI drafted vs. what the user actually sent
    func recordExample(aiDraft: String, userFinal: String, platform: String) {
        exampleCount += 1
        let distance = wordEditDistance(aiDraft, userFinal)
        let distanceStr = String(format: "%.2f", distance)

        let exampleBlock = """

            ### Example \(exampleCount)
            PLATFORM: \(platform)
            EDIT_DISTANCE: \(distanceStr)
            AI_DRAFT:
            \(aiDraft.trimmingCharacters(in: .whitespacesAndNewlines))

            USER_SENT:
            \(userFinal.trimmingCharacters(in: .whitespacesAndNewlines))
            """

        if styleFileContents.isEmpty {
            // First example — create the file structure
            styleFileContents = """
                # Writing Style Profile

                ## Style Summary
                (Will be generated after 5 examples)

                ## Examples
                \(exampleBlock)
                """
        } else {
            styleFileContents += "\n" + exampleBlock
        }

        saveStyleFile()
    }

    /// Simple word-overlap edit distance (0 = identical, 1 = completely different)
    private func wordEditDistance(_ a: String, _ b: String) -> Double {
        let wordsA = Set(a.lowercased().split(whereSeparator: \.isWhitespace))
        let wordsB = Set(b.lowercased().split(whereSeparator: \.isWhitespace))
        guard !wordsA.isEmpty || !wordsB.isEmpty else { return 0 }
        let common = wordsA.intersection(wordsB).count
        let total = max(wordsA.count, wordsB.count)
        return 1.0 - (Double(common) / Double(total))
    }

    // MARK: - Incremental Style Refinement

    /// Regenerate the Style Summary using Sonnet — incremental refinement based on training pairs
    func regenerateStyleSummary(apiKey: String) async {
        let currentProfile = extractStyleSummary()
        let examples = extractExamplesText()
        guard !examples.isEmpty else { return }

        let refinementPrompt = Self.buildRefinementPrompt(currentProfile: currentProfile)

        do {
            let analysis = try await AnthropicAPI.draft(
                rawText: examples,
                apiKey: apiKey,
                systemPrompt: refinementPrompt,
                maxTokens: 4096,
                useModel: AnthropicAPI.sonnetModel
            )

            // Replace the Style Summary section
            if let summaryRange = styleFileContents.range(of: "## Style Summary\n") {
                let nextSection = styleFileContents.range(of: "\n## Examples")
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

    /// Build the incremental refinement prompt — tells Sonnet to fix what's wrong, not rebuild from scratch
    private static func buildRefinementPrompt(currentProfile: String) -> String {
        if currentProfile.isEmpty {
            // No existing profile — build from training pairs alone
            return """
                You are building a writing style profile from training data.

                Each example shows two versions of the same message:
                - AI_DRAFT: what an AI assistant generated
                - USER_SENT: what the user actually sent (after editing the AI's draft)

                The USER_SENT version is the ground truth — it's how this person actually writes. \
                The differences between AI_DRAFT and USER_SENT reveal their preferences.

                Analyze the USER_SENT versions across all examples. Build a comprehensive style profile covering:

                **Tone & Voice** — their default register, warmth, directness
                **Sentence Patterns** — length, rhythm, fragments vs. complete sentences
                **Openings & Closings** — how they start and end messages
                **Punctuation & Formatting** — their punctuation fingerprint, emoji usage, markdown habits
                **Signature Phrases** — recurring words, expressions, verbal tics
                **Platform Adaptation** — how their style shifts across platforms (check PLATFORM tags)

                Also note patterns in what they consistently CHANGE from the AI drafts — these are the \
                strongest signals of their preferences.

                Write in second person ("You..."). Be specific — quote actual phrases as evidence. \
                IMPORTANT: Do NOT include a title or top-level heading. Start directly with the first section.
                """
        }

        return """
            You are refining a writing style profile based on new evidence.

            CURRENT PROFILE:
            \(currentProfile)

            The training data below shows pairs: what an AI drafted (AI_DRAFT) vs. what the user actually \
            sent (USER_SENT). The DIFFERENCES between these reveal where the current profile is inaccurate.

            Analyze the patterns in what the user changes:
            - Consistent length changes (AI writes too long/short)
            - Tone shifts (AI too formal/casual for specific platforms)
            - Word substitutions (AI uses words this person avoids)
            - Structural changes (AI uses bullets, user prefers paragraphs — or vice versa)
            - Opening/closing pattern corrections
            - Platform-specific patterns (check PLATFORM tags — they may write very differently on Slack vs. email)
            - Punctuation corrections (AI adds/removes exclamation marks, dashes, emoji the user wouldn't use)

            Rewrite the COMPLETE style profile:
            - PRESERVE everything in the current profile that's still accurate
            - FIX dimensions where the training pairs show clear, repeated patterns
            - ADD platform-specific style notes if writing differs across platforms
            - Be specific — quote actual phrases from USER_SENT as evidence

            Write in second person ("You..."). \
            IMPORTANT: Do NOT include a title or top-level heading. Start directly with the first section.
            """
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

    /// Import bulk writing samples from onboarding and generate initial style profile.
    /// Raw samples are used for analysis only — NOT persisted in style.md.
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

        // Build style.md with ONLY the generated summary — raw samples are discarded
        styleFileContents = """
            # Writing Style Profile

            ## Style Summary
            \(analysis)

            ## Examples
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

    private func extractExamplesText() -> String {
        guard let range = styleFileContents.range(of: "## Examples") else { return "" }
        return String(styleFileContents[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
