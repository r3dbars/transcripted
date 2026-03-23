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

    /// Build system prompt — condensed style profile + compact rules (optimized for small local models)
    func buildSystemPrompt() -> String {
        let condensed = extractCondensedProfile()
        guard !condensed.isEmpty else {
            return promptStore?.config.draftingSystem ?? DefaultPrompts.draftingSystem
        }

        return """
            You ghostwrite messages for the user. Deliver their intent first, then apply their style.

            \(condensed)

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
        let examples = extractRecentExamplesText(last: 20)
        guard !examples.isEmpty else { return }

        let refinementPrompt = Self.buildRefinementPrompt(currentProfile: currentProfile)

        do {
            let analysis = try await draftEngine.complete(
                prompt: examples,
                systemPrompt: refinementPrompt,
                maxTokens: DraftConstants.localRefinementMaxTokens,
                temperature: 0.7
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

    /// Build the incremental refinement prompt — tells the model to fix what's wrong, not rebuild from scratch
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

                OPENER ANALYSIS: Pay special attention to cases where the user removes AI-generated \
                openers like "Yeah exactly..", "Yeah that tracks..", "This is interesting!", or similar \
                agreement phrases from the beginning of AI_DRAFT. If the user frequently removes these \
                openers, the profile should note that openers are CONDITIONAL — only appropriate when \
                genuinely agreeing with a specific point someone made — rather than DEFAULT. The ALWAYS \
                section should reflect actual opener frequency from USER_SENT, not aspirational use.

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

            OPENER ANALYSIS: Pay special attention to cases where the user removes AI-generated \
            openers like "Yeah exactly..", "Yeah that tracks..", "This is interesting!", or similar \
            agreement phrases from the beginning of AI_DRAFT. If the user frequently removes these \
            openers, the profile should note that openers are CONDITIONAL — only appropriate when \
            genuinely agreeing with a specific point someone made — rather than DEFAULT. The ALWAYS \
            section should reflect actual opener frequency from USER_SENT, not aspirational use.

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
    func importBulkSamples(rawText: String, draftEngine: MLXEngine) async throws -> String {
        let userName = UserDefaults.standard.string(forKey: "user-display-name")

        // Send to local LLM for analysis
        let analysis = try await draftEngine.complete(
            prompt: rawText,
            systemPrompt: Self.bulkAnalysisPrompt(userName: userName),
            maxTokens: DraftConstants.localBulkAnalysisMaxTokens,
            temperature: 0.7
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
