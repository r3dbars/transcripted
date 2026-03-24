// StyleEngine.swift
// Manages style.md — the single file that teaches the model how the user writes

import Foundation
import SwiftUI

@MainActor
class StyleEngine: ObservableObject {
    @Published var exampleCount = 0
    @Published var styleFileContents = ""
    @Published var hasCompletedOnboarding: Bool

    private let storageDir: URL
    private let styleFileURL: URL

    /// Reference to PromptStore — set by ContentView after init.
    var promptStore: PromptStore?

    init() {
        hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "style-onboarding-completed")

        storageDir = FileManager.default.draftAppSupportDir
        styleFileURL = storageDir.appendingPathComponent("style.md")

        // Create directory if needed
        do {
            try FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
        } catch {
            EventReporter.shared.capture(level: .warning, engine: "style", event: "directory_create_failed",
                message: "Failed to create directory \(storageDir.path): \(error.localizedDescription)")
        }

        // Load existing file
        loadStyleFile()
    }

    func completeOnboarding() {
        hasCompletedOnboarding = true
        UserDefaults.standard.set(true, forKey: "style-onboarding-completed")
    }

    // MARK: - Public Interface

    /// Build system prompt — condensed style profile + reference samples + compact rules (optimized for small local models)
    func buildSystemPrompt() -> String {
        let condensed = extractCondensedProfile()
        guard !condensed.isEmpty else {
            return promptStore?.config.draftingSystem ?? DefaultPrompts.draftingSystem
        }

        // Include 3 diverse USER_SENT samples — concrete examples ground the 4B model
        // much better than abstract style descriptions alone
        let samples = extractReferenceSamples(count: 3)
        var referencePart = ""
        if !samples.isEmpty {
            let formatted = samples.map { "[\($0.platform)] \($0.text)" }.joined(separator: "\n\n")
            referencePart = "\n\nExamples of how the user actually writes:\n\(formatted)"
        }

        return """
            You ghostwrite messages for the user. Deliver their intent first, then apply their style.

            \(condensed)\(referencePart)

            Rules:
            - Output ONLY the message text. No labels, explanations, or alternatives.
            - Say what the user asked you to say. Intent beats style when they conflict.
            - Match message length to the conversation energy. Don't over-elaborate.
            - No AI fluff: no "I hope this helps", no unnecessary greetings or sign-offs.
            """
    }

    /// Extract just the Style Summary section from style.md (full verbose version, used by refinement)
    func extractStyleSummary() -> String {
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

    /// Strip markdown bullet prefix (* or -) from a line.
    private static func stripBulletPrefix(_ s: String) -> String {
        var c = s
        if c.hasPrefix("*   ") { c = String(c.dropFirst(4)) }
        else if c.hasPrefix("* ") { c = String(c.dropFirst(2)) }
        else if c.hasPrefix("- ") { c = String(c.dropFirst(2)) }
        return c
    }

    /// Extract a condensed style profile for the drafting model (optimized for small local models).
    /// Pulls just: one-line tone summary, ALWAYS bullets, NEVER bullets, signature phrases.
    /// Strips verbose prose, proof citations, and AI Draft comparison examples.
    private func extractCondensedProfile() -> String {
        let full = extractStyleSummary()
        guard !full.isEmpty else { return "" }

        // New compact format (TONE/ALWAYS/NEVER/PHRASES) — already condensed, return as-is
        let trimmed = full.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("TONE:") {
            return trimmed
        }

        // Legacy verbose format — extract key sections
        var parts: [String] = []

        // Extract a one-line tone summary from **Tone & Voice** section
        if let toneStart = full.range(of: "**Tone & Voice**") {
            let afterTone = full[toneStart.upperBound...]
            let firstLine = afterTone.components(separatedBy: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
            if let periodIdx = firstLine.firstIndex(of: ".") {
                parts.append("STYLE: \(String(firstLine[...periodIdx]).trimmingCharacters(in: .whitespaces))")
            } else if !firstLine.isEmpty {
                parts.append("STYLE: \(firstLine.trimmingCharacters(in: .whitespaces))")
            }
        }

        // Extract ALWAYS bullets — strip "(Proof: ...)" citations
        if let alwaysStart = full.range(of: "**ALWAYS**") {
            let afterAlways = full[alwaysStart.upperBound...]
            let alwaysEnd = afterAlways.range(of: "**NEVER**") ?? afterAlways.endIndex ..< afterAlways.endIndex
            let alwaysSection = String(afterAlways[..<alwaysEnd.lowerBound])
            let bullets = alwaysSection
                .components(separatedBy: "\n")
                .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("*") || $0.trimmingCharacters(in: .whitespaces).hasPrefix("-") }
                .map { line -> String in
                    var cleaned = Self.stripBulletPrefix(line.trimmingCharacters(in: .whitespaces))
                    if let proofRange = cleaned.range(of: " (Proof:", options: .caseInsensitive) {
                        cleaned = String(cleaned[..<proofRange.lowerBound])
                    }
                    if cleaned.hasSuffix(".") { cleaned = String(cleaned.dropLast()) }
                    return "- \(cleaned)"
                }
            if !bullets.isEmpty {
                parts.append("\nALWAYS:\n\(bullets.joined(separator: "\n"))")
            }
        }

        // Extract NEVER bullets — only the first line of each, strip sub-bullets with AI Draft examples
        if let neverStart = full.range(of: "**NEVER**") {
            let afterNever = full[neverStart.upperBound...]
            let neverEnd = afterNever.range(of: "\n**", range: afterNever.startIndex..<afterNever.endIndex)
            let neverSection = neverEnd != nil ? String(afterNever[..<neverEnd!.lowerBound]) : String(afterNever)
            let bullets = neverSection
                .components(separatedBy: "\n")
                .filter { line in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    let isTopLevel = (trimmed.hasPrefix("*") || trimmed.hasPrefix("-")) && !line.hasPrefix("    ")
                    let isExample = trimmed.contains("*AI Draft") || trimmed.contains("*Your Style") || trimmed.contains("*Correction")
                    return isTopLevel && !isExample
                }
                .map { line -> String in
                    var cleaned = Self.stripBulletPrefix(line.trimmingCharacters(in: .whitespaces))
                    if cleaned.hasSuffix(".") { cleaned = String(cleaned.dropLast()) }
                    return "- \(cleaned)"
                }
            if !bullets.isEmpty {
                parts.append("\nNEVER:\n\(bullets.joined(separator: "\n"))")
            }
        }

        // Extract signature phrases — just the quoted phrases
        if let phrasesStart = full.range(of: "**Signature Phrases**") {
            let afterPhrases = full[phrasesStart.upperBound...]
            let phrasesEnd = afterPhrases.range(of: "\n**") ?? afterPhrases.endIndex ..< afterPhrases.endIndex
            let phrasesSection = String(afterPhrases[..<phrasesEnd.lowerBound])
            let phrases = phrasesSection
                .components(separatedBy: "\n")
                .compactMap { line -> String? in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard trimmed.hasPrefix("*") || trimmed.hasPrefix("-") else { return nil }
                    // Extract just the quoted phrase
                    if let firstQuote = trimmed.firstIndex(of: "\""),
                       let secondQuote = trimmed[trimmed.index(after: firstQuote)...].firstIndex(of: "\"") {
                        return String(trimmed[trimmed.index(after: firstQuote)..<secondQuote])
                    }
                    return nil
                }
            if !phrases.isEmpty {
                parts.append("\nPHRASES: \(phrases.joined(separator: ", "))")
            }
        }

        return parts.joined(separator: "\n")
    }

    // MARK: - Reference Sample Extraction

    private struct ReferenceSample {
        let platform: String
        let text: String
    }

    /// Extract diverse USER_SENT samples from training pairs for the system prompt.
    /// Prefers recent examples from different platforms for maximum style coverage.
    private func extractReferenceSamples(count: Int) -> [ReferenceSample] {
        let blocks = styleFileContents.components(separatedBy: "### Example")
        let exampleBlocks = Array(blocks.dropFirst())

        var samples: [ReferenceSample] = []
        var seenPlatforms: Set<String> = []

        // Walk backwards (most recent first) and prefer diverse platforms
        for block in exampleBlocks.reversed() {
            guard let platformRange = block.range(of: "PLATFORM: ") else { continue }
            let afterPlatform = block[platformRange.upperBound...]
            let platform = String(afterPlatform.prefix(while: { $0 != "\n" }))
                .trimmingCharacters(in: .whitespaces)

            guard let userSentRange = block.range(of: "USER_SENT:\n") else { continue }
            let afterUserSent = block[userSentRange.upperBound...]
            let text = String(afterUserSent).trimmingCharacters(in: .whitespacesAndNewlines)

            guard !text.isEmpty else { continue }

            // Prioritize unseen platforms for diversity
            if !seenPlatforms.contains(platform) {
                samples.append(ReferenceSample(platform: platform, text: text))
                seenPlatforms.insert(platform)
            } else if samples.count < count {
                samples.append(ReferenceSample(platform: platform, text: text))
            }

            if samples.count >= count { break }
        }

        return samples
    }

    // MARK: - Training Pair Recording

    /// Record a training pair — what the AI drafted vs. what the user actually sent
    func recordExample(aiDraft: String, userFinal: String, platform: String,
                       userInstructions: String? = nil, formality: String? = nil) {
        exampleCount += 1
        let distance = wordEditDistance(aiDraft, userFinal)
        let distanceStr = String(format: "%.2f", distance)

        // Build example block with optional metadata fields
        var exampleBlock = "\n### Example \(exampleCount)\nPLATFORM: \(platform)"
        if let formality = formality, !formality.isEmpty {
            exampleBlock += "\nFORMALITY: \(formality)"
        }
        if let instructions = userInstructions,
           !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            exampleBlock += "\nUSER_INSTRUCTIONS:\n\(instructions.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        exampleBlock += """
        \nEDIT_DISTANCE: \(distanceStr)
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
        StyleUtils.wordEditDistance(a, b)
    }

    // MARK: - Refinement Scheduling

    /// Determine whether refinement should run now based on example count and edit distance trends
    func shouldRefineNow() -> Bool {
        StyleUtils.shouldRefineNow(exampleCount: exampleCount, styleFileContents: styleFileContents)
    }

    /// Style match score: how well Draft matches the user's style (0-100).
    /// Higher = AI drafts need fewer edits. Based on average edit distance of recent examples.
    var styleMatchScore: Int {
        guard exampleCount > 0 else { return 0 }
        let avg = StyleUtils.averageRecentEditDistance(
            last: DraftConstants.refinementDistanceWindow,
            styleFileContents: styleFileContents
        )
        return max(0, min(100, Int((1.0 - avg) * 100)))
    }

    /// Human-readable training phase description
    var trainingPhaseDescription: String {
        switch exampleCount {
        case 0:
            return "No examples yet"
        case 1...4:
            return "Getting started (\(exampleCount))"
        case 5...19:
            return "Learning (\(exampleCount))"
        case 20...49:
            return "Refining (\(exampleCount))"
        default:
            return "Mature (\(exampleCount))"
        }
    }

    // MARK: - Incremental Style Refinement

    /// Regenerate the Style Summary using local LLM — incremental refinement based on recent training pairs
    func regenerateStyleSummary(draftEngine: MLXEngine) async {
        let currentProfile = extractStyleSummary()
        let examples = extractRecentExamplesText(last: DraftConstants.refinementExampleWindow)
        guard !examples.isEmpty else { return }

        let refinementPrompt = Self.buildRefinementPrompt(currentProfile: currentProfile)

        do {
            // Lower temperature (0.3) for analytical tasks — refinement needs deterministic,
            // grounded output. The 4B model hallucinates patterns at higher temperatures.
            let analysis = try await draftEngine.complete(
                prompt: examples,
                systemPrompt: refinementPrompt,
                maxTokens: DraftConstants.localRefinementMaxTokens,
                temperature: 0.3
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
            EventReporter.shared.capture(level: .error, engine: "style", event: "style_refinement_failed",
                message: error.localizedDescription)
        }
    }

    /// Build the incremental refinement prompt — compact 4-section format optimized for Qwen 3.5-4B.
    /// The original 9-section, ~2400-word prompt was designed for Sonnet. The 4B model gets confused
    /// by nested conditionals, 9 required sections, and long preambles — it confuses content with style
    /// and treats one-off phrases as "signature patterns." This compact version cuts to 4 sections
    /// (TONE, ALWAYS, NEVER, PHRASES) with ~400 words of instructions.
    private static func buildRefinementPrompt(currentProfile: String) -> String {
        if currentProfile.isEmpty {
            return """
                Build a writing style profile from the training pairs below.

                Each pair shows:
                - AI_DRAFT: what an AI wrote
                - USER_SENT: what the user actually sent after editing
                - EDIT_DISTANCE: how much they changed it (0 = kept as-is, 1 = completely rewritten)

                RULES:
                1. USER_SENT is the ONLY source of truth. Every pattern must come from USER_SENT text.
                2. Do NOT treat AI_DRAFT phrases as the user's style — those are the AI's habits.
                3. If a phrase appears in AI_DRAFT but was removed in USER_SENT, add it to NEVER.
                4. Only list a phrase in PHRASES if it appears in USER_SENT across multiple examples.
                5. High EDIT_DISTANCE (0.3+) examples are the strongest style signals.

                Output EXACTLY this format — no other sections or headings:

                TONE: [1-2 sentences describing their writing voice — direct/casual/formal, warmth, how they express ideas. Write in second person.]

                ALWAYS:
                - [rule 1 — quote a phrase from USER_SENT as evidence]
                - [rule 2 — quote evidence]
                - [5-8 specific, actionable rules total]

                NEVER:
                - Never [thing to avoid] — instead [what they do]. [Quote AI_DRAFT phrase they removed]
                - [5-8 rules total, each as "Never X — instead Y" with evidence]

                PHRASES: "[phrase1]", "[phrase2]", "[phrase3]" [3-8 phrases from USER_SENT that appear across multiple examples]

                Start directly with TONE:. Do not add any title, heading, or extra sections.
                """
        }

        return """
            Refine this writing style profile based on new training pairs.

            CURRENT PROFILE:
            \(currentProfile)

            Each training pair shows AI_DRAFT (what AI wrote) vs USER_SENT (what user actually sent).
            EDIT_DISTANCE shows how much the user changed it (0 = kept, 1 = rewrote).

            RULES:
            1. USER_SENT is the ONLY source of truth. Do NOT attribute AI_DRAFT phrases to the user.
            2. PRESERVE rules from the current profile that have evidence in USER_SENT.
            3. REMOVE any rules or phrases that came from AI_DRAFT text (contamination).
            4. ADD new patterns you see repeated across multiple USER_SENT messages.
            5. PHRASES must appear in USER_SENT across multiple examples — not just once.
            6. High EDIT_DISTANCE (0.3+) = strongest signals. Pay extra attention to these.

            Output EXACTLY this format — no other sections or headings:

            TONE: [1-2 sentences — update based on new evidence. Write in second person.]

            ALWAYS:
            - [rule — quote USER_SENT evidence]
            - [5-8 specific, actionable rules total]

            NEVER:
            - Never [thing to avoid] — instead [what they do]. [Quote evidence]
            - [5-8 rules total, each as "Never X — instead Y"]

            PHRASES: "[phrase1]", "[phrase2]", "[phrase3]" [3-8 recurring USER_SENT phrases]

            Start directly with TONE:. Do not add any title, heading, or extra sections.
            """
    }

    // MARK: - Bulk Import (Onboarding)

    /// Prompt for analyzing raw, messy writing samples from onboarding
    /// Prompt for analyzing raw writing samples from onboarding — compact 4-section format for 4B model
    private static func bulkAnalysisPrompt(userName: String?) -> String {
        let nameClause = userName.flatMap { $0.isEmpty ? nil : $0 }
            .map { "The user's name is \($0). Focus ONLY on messages written by them." }
            ?? "Focus on identifying a single author's writing patterns across the samples."

        return """
            Analyze these writing samples to build a style profile for a ghostwriter AI.

            The samples are from Slack, iMessage, email, etc. They may include timestamps, \
            sender names, and messages from other people — ignore those.

            \(nameClause)

            Output EXACTLY this format — no other sections or headings:

            TONE: [1-2 sentences about their voice — direct/casual/formal, warmth, how they express ideas. Write in second person.]

            ALWAYS:
            - [rule — quote a phrase from the samples as evidence]
            - [5-8 specific, actionable rules total]

            NEVER:
            - Never [thing to avoid] — instead [what they do]. [Quote evidence]
            - [5-8 rules total, each as "Never X — instead Y"]

            PHRASES: "[phrase1]", "[phrase2]", "[phrase3]" [3-8 characteristic phrases from the samples]

            For every rule, include a direct quote from the samples as proof. \
            If you can't find a quote, do not include the rule.

            Start directly with TONE:. Do not add any title, heading, or extra sections.
            """
    }

    /// Import bulk writing samples from onboarding and generate initial style profile.
    /// Raw samples are used for analysis only — NOT persisted in style.md.
    func importBulkSamples(rawText: String, draftEngine: MLXEngine) async throws -> String {
        let userName = UserDefaults.standard.string(forKey: "user-display-name")

        // Send to local LLM for analysis — lower temperature for deterministic analytical output
        let analysis = try await draftEngine.complete(
            prompt: rawText,
            systemPrompt: Self.bulkAnalysisPrompt(userName: userName),
            maxTokens: DraftConstants.localBulkAnalysisMaxTokens,
            temperature: 0.3
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

    /// Import a style profile from pasted agent output (onboarding clipboard flow).
    /// Wraps the profile in the standard style.md structure and exports for agent sync.
    func importProfile(_ profileText: String) {
        let trimmed = profileText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        styleFileContents = """
            # Writing Style Profile

            ## Style Summary
            \(trimmed)

            ## Examples
            """

        saveStyleFile()
    }

    /// Save a pre-generated style profile (from external paste-back).
    /// Wraps the profile in the standard style.md structure without running any analysis.
    func saveImportedProfile(_ profile: String) {
        styleFileContents = """
        # Writing Style Profile

        ## Style Summary
        \(profile)

        ## Examples
        """

        saveStyleFile()
    }

    // MARK: - File I/O

    private func loadStyleFile() {
        if FileManager.default.fileExists(atPath: styleFileURL.path) {
            do {
                styleFileContents = try String(contentsOf: styleFileURL, encoding: .utf8)
            } catch {
                styleFileContents = ""
                EventReporter.shared.capture(level: .warning, engine: "style", event: "style_file_read_failed",
                    message: error.localizedDescription)
            }
            // Count examples by counting "### Example" occurrences
            exampleCount = styleFileContents.components(separatedBy: "### Example").count - 1
        }
    }

    private func saveStyleFile() {
        do {
            try styleFileContents.write(to: styleFileURL, atomically: true, encoding: .utf8)
        } catch {
            EventReporter.shared.capture(level: .error, engine: "style", event: "style_file_write_failed",
                message: error.localizedDescription)
        }
        exportStyleProfile()
    }

    /// Export the style summary as a plain text file for agent consumption.
    /// Any AI agent can read ~/Library/Application Support/Draft/style-profile.md to know how the user writes.
    private func exportStyleProfile() {
        let summary = extractStyleSummary()
        guard !summary.isEmpty else { return }
        let exportURL = storageDir.appendingPathComponent("style-profile.md")
        do {
            try summary.write(to: exportURL, atomically: true, encoding: .utf8)
        } catch {
            EventReporter.shared.capture(level: .error, engine: "style", event: "style_profile_export_failed",
                message: error.localizedDescription)
        }
    }

    /// Extract only the last N examples for recency-weighted refinement
    private func extractRecentExamplesText(last n: Int) -> String {
        StyleUtils.extractRecentExamplesText(last: n, styleFileContents: styleFileContents)
    }
}
