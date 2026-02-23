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

    /// Reference to PromptStore — set by ContentView after init.
    var promptStore: PromptStore?

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

    /// Build system prompt — style profile + reference samples + structured instructions
    func buildSystemPrompt() -> String {
        let summary = extractStyleSummary()
        guard !summary.isEmpty else {
            return promptStore?.config.draftingSystem ?? DefaultPrompts.draftingSystem
        }

        // Pull 2-3 diverse reference samples from training pairs
        let samples = extractReferenceSamples(count: 3)
        var samplesBlock = ""
        if !samples.isEmpty {
            let sampleEntries = samples.map { s in
                "<sample platform=\"\(s.platform)\">\n\(s.text)\n</sample>"
            }.joined(separator: "\n")
            samplesBlock = "\n<reference_messages>\n\(sampleEntries)\n</reference_messages>\n"
        }

        return """
            You are ghostwriting as a specific person. Your output must be indistinguishable from \
            something they actually wrote. Study the style profile and reference messages below, \
            then write EXACTLY as they would.

            <style_profile>
            \(summary)
            </style_profile>
            \(samplesBlock)
            <the_test>
            If someone who knows this person well read your output, could they tell it wasn't written \
            by them? If YES, you failed. Your job is to BE them, not to edit them.
            </the_test>

            <instructions>
            - Output ONLY the message text. No labels, no explanations, no meta-commentary.
            - Match their exact register for the target platform — they write differently on Slack vs. email vs. iMessage.
            - Preserve the original meaning, intent, and all information from their input. Don't add anything they didn't say.
            - Don't over-polish — if they write casually, keep it casual. If they use fragments, use fragments.
            - When in doubt between two phrasings, choose the one that sounds more like THEM — even if it's \
            less polished. Lean toward their natural voice, not what sounds "better."
            - Incorporate their signature phrases naturally (1-2 per message, don't force all of them).
            - Respect every rule in their NEVER list — these are the strongest signals of their voice.
            - Match their typical message length for this platform. Don't write more than they would.
            - Do NOT write like a helpful AI assistant. No "I hope this helps", no "Let me know if you need anything", \
            no corporate pleasantries. Write like a real person texting or messaging their friends/colleagues.
            </instructions>
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
        let wordsA = Set(a.lowercased().split(whereSeparator: \.isWhitespace))
        let wordsB = Set(b.lowercased().split(whereSeparator: \.isWhitespace))
        guard !wordsA.isEmpty || !wordsB.isEmpty else { return 0 }
        let common = wordsA.intersection(wordsB).count
        let total = max(wordsA.count, wordsB.count)
        return 1.0 - (Double(common) / Double(total))
    }

    // MARK: - Refinement Scheduling

    /// Determine whether refinement should run now based on example count and edit distance trends
    func shouldRefineNow() -> Bool {
        guard exampleCount > 0 else { return false }

        if exampleCount <= 20 {
            // Early phase: refine every 3 examples (learning fast)
            return exampleCount % 3 == 0
        }

        // Mature phase: check if profile has stabilized
        let recentAvg = averageRecentEditDistance(last: 10)

        if recentAvg < 0.25 {
            // Profile is working well — refine every 10
            return exampleCount % 10 == 0
        } else {
            // Still learning — refine every 5
            return exampleCount % 5 == 0
        }
    }

    /// Average edit distance of the N most recent examples (0 = AI nails it, 1 = completely rewritten)
    private func averageRecentEditDistance(last n: Int) -> Double {
        let distances = extractRecentEditDistances(last: n)
        guard !distances.isEmpty else { return 1.0 }
        return distances.reduce(0, +) / Double(distances.count)
    }

    /// Parse EDIT_DISTANCE values from the last N examples
    private func extractRecentEditDistances(last n: Int) -> [Double] {
        let blocks = styleFileContents.components(separatedBy: "### Example")
        // First element is everything before examples — skip it
        let exampleBlocks = Array(blocks.dropFirst().suffix(n))
        return exampleBlocks.compactMap { block in
            guard let range = block.range(of: "EDIT_DISTANCE: ") else { return nil }
            let afterTag = block[range.upperBound...]
            let line = afterTag.prefix(while: { $0 != "\n" })
            return Double(line)
        }
    }

    // MARK: - Incremental Style Refinement

    /// Regenerate the Style Summary using Sonnet — incremental refinement based on recent training pairs
    func regenerateStyleSummary(auth: AuthCredential) async {
        let currentProfile = extractStyleSummary()
        let examples = extractRecentExamplesText(last: 20)
        guard !examples.isEmpty else { return }

        let refinementPrompt = Self.buildRefinementPrompt(currentProfile: currentProfile)

        do {
            let analysis = try await AnthropicAPI.draft(
                rawText: examples,
                auth: auth,
                model: AnthropicAPI.sonnetModel,
                systemPrompt: refinementPrompt,
                maxTokens: 4096
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
                You are building a writing style profile from training data. This profile will be used \
                by a ghostwriter AI to write messages indistinguishable from this person.

                Each example shows two versions of the same message:
                - AI_DRAFT: what an AI assistant generated
                - USER_SENT: what the user actually sent (after editing the AI's draft)
                - EDIT_DISTANCE: how much they changed it (0 = kept as-is, 1 = completely rewritten)

                Some examples may also include:
                - USER_INSTRUCTIONS: what the user TOLD the AI to do (their spoken voice instructions)
                - FORMALITY: the detected communication register (casual/professional/formal)
                Not all examples have these fields — older examples may only have PLATFORM, EDIT_DISTANCE, \
                AI_DRAFT, and USER_SENT. Use the additional fields when available.

                ⚠️ INSTRUCTION vs. STYLE SEPARATION (when USER_INSTRUCTIONS is present):
                1. Read USER_INSTRUCTIONS to understand what the user asked for
                2. Compare AI_DRAFT to USER_INSTRUCTIONS — did the AI follow the instructions?
                3. Compare USER_SENT to AI_DRAFT — what did the user change?
                4. If the user's changes ALIGN with instructions the AI missed → this is an INSTRUCTION \
                error, NOT a style signal. Do not derive style patterns from these changes.
                5. If the user's changes go BEYOND what their instructions specified → these reveal TRUE \
                style preferences. The gap between "what they asked for" and "what they actually wrote" \
                is the purest style signal.

                Use FORMALITY to build context-aware patterns. NEVER rules should be context-specific \
                when formality data is available: "NEVER X in professional Slack" not just "NEVER X."

                ⚠️ CRITICAL SOURCE RULES — read these before analyzing ANY example:
                1. USER_SENT is the SOLE source of truth for this person's writing style. \
                EVERY positive pattern (signature phrases, tone, metrics) must come from USER_SENT text ONLY.
                2. AI_DRAFT shows what the AI wrote — NOT what the user writes. Do NOT attribute \
                AI_DRAFT phrases, patterns, or metrics to the user.
                3. If a phrase/pattern appears in AI_DRAFT but is REMOVED or CHANGED in USER_SENT, \
                that is a NEVER signal — the user actively rejected it. Add it to the NEVER list.
                4. If the user kept an AI_DRAFT phrase unchanged, that is WEAK evidence at best — \
                it means they tolerated it, not that it's their natural voice. Do not list it as a \
                signature phrase unless it also appears in other USER_SENT messages independently.
                5. ALL quantitative metrics (message length, sentence count, emoji frequency, \
                connector usage) must be measured from USER_SENT messages ONLY.

                High edit distance examples (0.3+) are the STRONGEST signals — they show where the AI \
                got it most wrong. Low edit distance (< 0.1) means the AI was close.

                Build a profile with ALL of these sections (use these exact headings):

                **Tone & Voice** — their default register, warmth, directness

                **Sentence Patterns** — average length (estimate in words FROM USER_SENT), fragments vs. \
                complete sentences, how they chain ideas

                **Platform-Specific Patterns** — how their style shifts by platform (check PLATFORM tags). \
                Dedicate a sub-section to each platform with evidence.

                **Openings & Closings** — how they start and end messages (by platform if different)

                **Punctuation & Formatting** — their punctuation fingerprint, emoji usage, capitalization

                **Signature Phrases** — list 5-15 characteristic phrases/expressions as bullets with quotes. \
                For each, include the phrase, a usage note, and 1-2 direct quotes from USER_SENT proving it. \
                ONLY count phrases that appear in USER_SENT. If a phrase only appears in AI_DRAFT, it is \
                the AI's habit, NOT the user's.

                **Quantitative Fingerprint** — estimate FROM USER_SENT ONLY: avg sentence length, typical \
                message length by platform, contraction usage, active voice ratio. \
                Count words in USER_SENT messages to get real averages — do NOT use AI_DRAFT lengths.

                **ALWAYS** — 5-10 rules a ghostwriter must follow (specific, actionable). \
                For each rule, include a direct quote from USER_SENT proving the pattern.

                **NEVER** — 5-10 things this person would never write, using contrast pairs: \
                "Never X — instead Y." Build this list from TWO sources: \
                (a) Things the AI wrote in AI_DRAFT that the user removed or replaced in USER_SENT — \
                quote the AI's version AND the user's replacement. These are the strongest NEVER signals. \
                (b) Generic AI patterns this person would avoid (corporate pleasantries, hedging, etc.)

                EVIDENCE RULE: For EVERY pattern you claim, include 1-2 direct quotes from USER_SENT \
                as proof. For NEVER rules, quote what the AI wrote AND what the user changed it to. \
                If you can't quote evidence from USER_SENT, do NOT include the pattern.

                Write in second person ("You..."). \
                IMPORTANT: Do NOT include a title or top-level heading. Start directly with **Tone & Voice**.
                """
        }

        return """
            You are refining a writing style profile based on new evidence. This profile is used by \
            a ghostwriter AI to write messages indistinguishable from this person.

            CURRENT PROFILE:
            \(currentProfile)

            ⚠️ CRITICAL SOURCE RULES — read these before analyzing ANY training pair:
            1. USER_SENT is the SOLE source of truth for this person's writing style. \
            EVERY positive pattern (signature phrases, tone, metrics) must come from USER_SENT text ONLY.
            2. AI_DRAFT shows what the AI wrote — NOT what the user writes. Do NOT attribute \
            AI_DRAFT phrases, patterns, or metrics to the user.
            3. If a phrase/pattern appears in AI_DRAFT but is REMOVED or CHANGED in USER_SENT, \
            that is a NEVER signal — the user actively rejected it. Add it to the NEVER list.
            4. If the user kept an AI_DRAFT phrase unchanged, that is WEAK evidence at best — \
            it means they tolerated it, not that it's their natural voice. Do not list it as a \
            signature phrase unless it also appears in other USER_SENT messages independently.
            5. ALL quantitative metrics (message length, sentence count, emoji frequency, \
            connector usage) must be measured from USER_SENT messages ONLY.
            6. AUDIT THE CURRENT PROFILE for contamination: if the current profile lists phrases \
            or metrics that don't appear in any USER_SENT message, REMOVE them. The previous \
            profile may have incorrectly attributed AI patterns to the user.

            The training data below shows pairs: what an AI drafted (AI_DRAFT) vs. what the user actually \
            sent (USER_SENT). The EDIT_DISTANCE shows how much they changed it (0 = kept, 1 = rewrote). \
            High edit distance examples (0.3+) are the STRONGEST signals — pay extra attention to these.

            Some examples may also include:
            - USER_INSTRUCTIONS: what the user TOLD the AI to do (their spoken voice instructions)
            - FORMALITY: the detected communication register (casual/professional/formal)
            Not all examples have these — older ones only have PLATFORM/EDIT_DISTANCE/AI_DRAFT/USER_SENT.

            ⚠️ INSTRUCTION vs. STYLE SEPARATION (when USER_INSTRUCTIONS is present):
            1. Read USER_INSTRUCTIONS to understand what the user asked for
            2. Compare AI_DRAFT to USER_INSTRUCTIONS — did the AI follow the instructions?
            3. Compare USER_SENT to AI_DRAFT — what did the user change?
            4. If the user's changes ALIGN with instructions the AI missed → INSTRUCTION error, NOT style
            5. If the user's changes go BEYOND what instructions specified → TRUE style preferences

            If USER_INSTRUCTIONS shows users repeatedly give an instruction the AI ignores \
            (e.g., "keep it brief" but AI writes long), add to ALWAYS: "Default to brevity \
            unless user explicitly asks for detail."

            Use FORMALITY to make NEVER rules context-aware: "NEVER X in professional Slack" \
            not just "NEVER X."

            Analyze the patterns in what the user changes:
            - Consistent length changes (compare AI_DRAFT word count vs. USER_SENT word count)
            - Tone shifts (AI too formal/casual for specific platforms)
            - Word substitutions (AI uses words this person avoids → add to NEVER list with contrast pair)
            - Structural changes (AI uses bullets, user prefers paragraphs — or vice versa)
            - Opening/closing pattern corrections
            - Platform-specific patterns (check PLATFORM tags — they may write very differently on Slack vs. email)
            - Punctuation corrections (AI adds/removes exclamation marks, dashes, emoji)
            - Things the AI adds that the user consistently removes → these are NEVER rules
            - Phrases the AI uses that the user replaces with different phrasing → the user's version \
            is the signature phrase, the AI's version is a NEVER

            Rewrite the COMPLETE style profile with ALL of these sections:
            **Tone & Voice**, **Sentence Patterns**, **Platform-Specific Patterns**, \
            **Openings & Closings**, **Punctuation & Formatting**, **Signature Phrases**, \
            **Quantitative Fingerprint**, **ALWAYS**, **NEVER**

            Rules for the rewrite:
            - PRESERVE patterns from the current profile ONLY if they have evidence in USER_SENT messages
            - REMOVE patterns from the current profile that were based on AI_DRAFT text (contamination)
            - FIX dimensions where the training pairs show clear, repeated patterns
            - ADD new NEVER rules as contrast pairs ("Never X — instead Y") for things the AI \
            consistently does wrong. Quote the AI's version AND the user's replacement.
            - Signature Phrases must ONLY contain phrases from USER_SENT. If a phrase only ever \
            appears in AI_DRAFT columns, it is the AI's habit and must NOT be listed.
            - UPDATE Quantitative Fingerprint by counting words in USER_SENT messages ONLY. \
            Do NOT average in AI_DRAFT lengths — they reflect the AI's verbosity, not the user's.
            - ADD platform-specific sub-sections for any new platforms seen

            EVIDENCE RULE: For EVERY pattern you claim, include 1-2 direct quotes from USER_SENT \
            as proof. For NEVER rules, quote what the AI wrote AND what the user changed it to. \
            If you can't quote evidence from USER_SENT, REMOVE the pattern — do not keep it.

            Write in second person ("You..."). Target 500-800 words. \
            IMPORTANT: Do NOT include a title or top-level heading. Start directly with **Tone & Voice**.
            """
    }

    // MARK: - Bulk Import (Onboarding)

    /// Prompt for analyzing raw, messy writing samples from onboarding
    private static func bulkAnalysisPrompt(userName: String?) -> String {
        let nameClause = userName.flatMap { $0.isEmpty ? nil : $0 }
            .map { "The user's name is \($0). Focus ONLY on messages written by them." }
            ?? "Focus on identifying a single author's writing patterns across the samples."

        return """
            You are analyzing real writing samples to build a comprehensive writing style profile \
            that a ghostwriter AI will use to write messages indistinguishable from this person.

            These samples were copied directly from the user's messages — Slack, iMessage, email, \
            and other platforms. They may include:
            - Timestamps, sender names, channel names (ignore these)
            - Emoji reactions, thread indicators, quoted replies (ignore metadata)
            - Messages from OTHER people mixed in (focus only on the user's writing)

            \(nameClause)

            Build a profile with ALL of the following sections (use these exact headings):

            **Tone & Voice**
            Their default register, warmth, directness. How do they balance authority with \
            approachability? How does tone shift by platform or audience?

            **Sentence Patterns**
            Average sentence length (estimate in words). Use of fragments vs. complete sentences. \
            How they chain ideas (dashes, commas, periods, conjunctions). Rhythm variation.

            **Platform-Specific Patterns**
            How their style shifts across platforms. Dedicate a sub-section to each platform you \
            see evidence for (Slack, iMessage, email, etc.). Cover: formality level, message length, \
            greeting/closing patterns, formatting choices.

            **Openings & Closings**
            How they start messages (by platform if different). How they end messages. \
            Greeting formulas, sign-off patterns, forward-looking hooks.

            **Punctuation & Formatting**
            Their punctuation fingerprint: dashes, ellipses, exclamation points (single vs. double), \
            emoji usage, capitalization habits, markdown/formatting preferences.

            **Signature Phrases**
            List 5-15 of their most characteristic phrases, expressions, and verbal tics. \
            Format as a bullet list with the phrase in quotes, a usage note, and 1-2 direct quotes \
            from the samples proving the pattern. Example format:
            - "but honestly" (pivot to their real point) — "but honestly what got me even more is..."
            - "let me know" (forward-looking closer) — "let me know after you check it out", \
            "Let me know your thoughts on that"

            **Quantitative Fingerprint**
            Estimate these metrics from the samples:
            - Average sentence length (words)
            - Typical message length by platform (sentences)
            - Approximate active voice ratio
            - Contraction usage (always/sometimes/never)
            - Questions per message (average)

            **ALWAYS**
            List 5-10 patterns that appear in virtually everything they write. \
            These are rules a ghostwriter must follow. Be specific and actionable. \
            For each rule, include a direct quote proving the pattern.

            **NEVER**
            List 5-10 things this person would NEVER write, using contrast pairs: \
            "Never X — instead Y." This format shows the ghostwriter what to do INSTEAD. \
            Include generic AI patterns they'd avoid. Examples of the format:
            - Never uses corporate sign-offs like "Best regards" — instead ends with action \
            items or casual "Let me know!"
            - Never hedges with "I think maybe" or "It might be worth considering" — instead \
            states opinions directly
            This section is CRITICAL — it prevents the AI from reverting to its default voice.

            EVIDENCE RULE: For EVERY pattern you identify in every section, include 1-2 direct \
            quotes from the samples that prove it. Not "you write casually" but "you open messages \
            with 'yo' or 'hey man' and chain thoughts with dashes: 'that's wild - I'll check it out'." \
            If you can't find a direct quote, note the pattern but flag it as needing more evidence.

            Target 500-800 words. Depth over breadth — if you have strong evidence for some dimensions \
            and weak evidence for others, go deep on what you can prove and note what needs more data.

            IMPORTANT: Do NOT include a title or top-level heading. Start directly with **Tone & Voice**.
            """
    }

    /// Import bulk writing samples from onboarding and generate initial style profile.
    /// Raw samples are used for analysis only — NOT persisted in style.md.
    func importBulkSamples(rawText: String, auth: AuthCredential) async throws -> String {
        let userName = UserDefaults.standard.string(forKey: "user-display-name")

        // Send to Sonnet for deep analysis
        let analysis = try await AnthropicAPI.draft(
            rawText: rawText,
            auth: auth,
            model: AnthropicAPI.sonnetModel,
            systemPrompt: Self.bulkAnalysisPrompt(userName: userName),
            maxTokens: 4096
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
        do {
            try styleFileContents.write(to: styleFileURL, atomically: true, encoding: .utf8)
        } catch {
            print("⚠️ STYLE | failed to save style.md: \(error.localizedDescription)")
        }
    }

    private func extractExamplesText() -> String {
        guard let range = styleFileContents.range(of: "## Examples") else { return "" }
        return String(styleFileContents[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Extract only the last N examples for recency-weighted refinement
    private func extractRecentExamplesText(last n: Int) -> String {
        let blocks = styleFileContents.components(separatedBy: "### Example")
        // First element is everything before examples — skip it
        let recentBlocks = blocks.dropFirst().suffix(n)
        guard !recentBlocks.isEmpty else { return "" }
        return recentBlocks.map { "### Example" + $0 }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
