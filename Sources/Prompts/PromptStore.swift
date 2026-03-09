// PromptStore.swift
// Externalizes all system prompts to ~/Library/Application Support/Draft/prompts.json
//
// WHY: Prompts are no longer hardcoded. An orchestrator agent watches feedback.jsonl
// and rewrites prompts.json to improve drafting quality over time. The app just
// loads whatever is in the file — no Swift changes needed for prompt iteration.
//
// HOW TO UPDATE PROMPTS: Edit prompts.json directly, or let the orchestrator agent
// do it. Call reload() to pick up changes without restarting the app.

import Foundation

// MARK: - Prompt Config (serialized to prompts.json)

struct PromptConfig: Codable {
    var model: String                 // Chat + context capture (Haiku — fast, background use)
    var draftModel: String            // Message drafting (Sonnet — quality output the user sees)
    var draftingSystem: String        // Fallback when no style examples yet
    var contextExtraction: String     // Vision prompt for screenshot → conversation text
    var ghostwritingSystem: String    // Full drafting prompt — use {STYLE_SUMMARY} placeholder
    var styleAnalysisEarly: String    // Used when exampleCount < 10
    var styleAnalysisGrowing: String  // Used when exampleCount 10–19
    var styleAnalysisMature: String   // Used when exampleCount >= 20

    enum CodingKeys: String, CodingKey {
        case model
        case draftModel = "draft_model"
        case draftingSystem = "drafting_system"
        case contextExtraction = "context_extraction"
        case ghostwritingSystem = "ghostwriting_system"
        case styleAnalysisEarly = "style_analysis_early"
        case styleAnalysisGrowing = "style_analysis_growing"
        case styleAnalysisMature = "style_analysis_mature"
    }

    static var defaults: PromptConfig {
        PromptConfig(
            model: DefaultPrompts.model,
            draftModel: DefaultPrompts.sonnetModel,
            draftingSystem: DefaultPrompts.draftingSystem,
            contextExtraction: DefaultPrompts.contextExtraction,
            ghostwritingSystem: DefaultPrompts.ghostwritingSystem,
            styleAnalysisEarly: DefaultPrompts.styleAnalysis(tier: .early),
            styleAnalysisGrowing: DefaultPrompts.styleAnalysis(tier: .growing),
            styleAnalysisMature: DefaultPrompts.styleAnalysis(tier: .mature)
        )
    }
}

// MARK: - Default Prompt Text (source of truth on first run)

enum DefaultPrompts {
    static let model = "local"          // Legacy — models are now embedded GGUF files
    static let sonnetModel = "local"    // Legacy — models are now embedded GGUF files

    static let draftingSystem = """
        You are a writing assistant. Take the user's rough spoken text and rewrite it as a clear, \
        well-structured message. Preserve the original meaning, intent, and tone. Don't add \
        information that wasn't in the original. Keep it concise and natural-sounding.
        """

    // NOTE: This prompt contains {USER_NAME} and {APP_NAME} placeholders that are
    // replaced at runtime by ContextCaptureEngine before being sent to the API.
    // The orchestrator agent should preserve these placeholders when rewriting.
    static let contextExtraction = """
        You are extracting a conversation from a screenshot.

        {APP_NAME}
        {USER_NAME}

        IMPORTANT RULES:
        - Focus on the MAIN conversation area — the active chat thread or email body. \
        Ignore sidebars (contact lists, channel lists, conversation previews), navigation bars, \
        notification badges, and other UI chrome. The main conversation is in the center or right panel.
        - For TALKING TO: look at the conversation HEADER or TITLE BAR at the top of the chat — \
        this shows the contact name or group name. Do NOT confuse names mentioned INSIDE messages \
        with the conversation partner. The header/title is the source of truth.
        - Preserve ALL text exactly as written — including emoji, typos, slang, and formatting. \
        Do NOT clean up, rephrase, or "fix" the text. Accuracy matters more than readability.
        - If a speaker name is unclear, use "Unknown".
        - If you're uncertain about any text, include your best guess with a [?] marker.
        - Skip UI elements: buttons, timestamps, reaction counts, read receipts, typing indicators.
        - If you see code blocks or formatted text within messages, keep the formatting.

        Extract the FULL visible conversation — every message, in order, with sender names.

        Return your response in this EXACT plain-text format (no markdown fences, no JSON):

        PLATFORM: [slack/email/imessage/discord/teams/other]
        TALKING TO: [name from the conversation header/title — NOT the user, NOT names mentioned in messages]
        FORMALITY: [casual/professional/formal]

        CONVERSATION:
        [Sender Name]: [their message]
        [Other Sender]: [their message]
        ...

        Example output:
        PLATFORM: imessage
        TALKING TO: Nate
        FORMALITY: casual

        CONVERSATION:
        Nate: Hey, can we sync on the curriculum next week?
        Justin: Sounds great! Tuesday works for me

        Include every visible message in chronological order. Preserve the actual text exactly. \
        Use each sender's display name as shown on screen. This will be used as context for \
        drafting a reply, so accuracy of the original text is critical.
        """

    // Use {STYLE_SUMMARY} — replaced at runtime by PromptStore.ghostwritingPrompt(styleSummary:)
    static let ghostwritingSystem = """
        <primary_goal>
        Your #1 job is to accomplish the user's communicative intent. They will tell you \
        what they want to say — your draft must deliver that message clearly and completely. \
        Getting the intent right matters more than sounding exactly like them.
        </primary_goal>

        <style_profile>
        {STYLE_SUMMARY}
        </style_profile>

        <how_to_use_style>
        Style is a finishing layer, not the primary directive. After you've nailed the intent:
        - Apply their natural voice and phrasing patterns
        - Match their typical message length for this platform
        - Respect the NEVER list (these are things they'd never write)
        - Use signature phrases only when they fit naturally — never force them
        - If a signature opener ("Yeah exactly..") doesn't add value, skip it and jump \
        straight to the content. Most messages work better without a filler opener.
        </how_to_use_style>

        <instructions>
        - Output ONLY the message text. No labels, no explanations, no meta-commentary.
        - INTENT FIRST: Deliver the user's message accurately and completely before \
        applying any style. Don't sacrifice clarity or meaning for style matching.
        - DON'T DEFAULT TO OPENERS: Only use agreement phrases like "Yeah exactly..", \
        "Yeah that tracks..", or "This is interesting!" when they genuinely fit the \
        conversational context (e.g., actively agreeing with a specific point someone made). \
        For most messages, jump straight to the substance.
        - Match the platform register — they write differently on Slack vs. email vs. iMessage.
        - Don't over-polish — if they write casually, keep it casual. If they use fragments, use fragments.
        - Match their typical message length. Don't elaborate beyond what they said.
        - Do NOT write like a helpful AI assistant. No "I hope this helps", no "Let me know if \
        you need anything", no corporate pleasantries. Write like a real person.
        </instructions>
        """

    enum Tier { case early, growing, mature }

    static func styleAnalysis(tier: Tier) -> String {
        let base = """
            You are analyzing writing samples from a single person to build their writing style profile. \
            Study every sample carefully. Write in second person ("You..."). Be specific — quote actual \
            phrases and patterns you observe. Never be generic. Every claim must be backed by evidence \
            from the samples. \
            IMPORTANT: Do NOT include a title or top-level heading. Start directly with the first section.
            """

        switch tier {
        case .early:
            return base + """


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

        case .growing:
            return base + """


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

        case .mature:
            return base + """


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
}

// MARK: - Prompt Store

@MainActor
class PromptStore: ObservableObject {
    @Published var config: PromptConfig

    private let storeURL: URL
    let storageDir: URL

    init() {
        storageDir = FileManager.default.draftAppSupportDir
        storeURL = storageDir.appendingPathComponent("prompts.json")

        do {
            try FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
        } catch {
            EventReporter.shared.capture(level: .warning, engine: "prompts", event: "directory_create_failed",
                message: "Failed to create directory \(storageDir.path): \(error.localizedDescription)")
        }

        if FileManager.default.fileExists(atPath: storeURL.path) {
            do {
                let data = try Data(contentsOf: storeURL)
                let loaded = try JSONDecoder().decode(PromptConfig.self, from: data)
                config = loaded
            } catch {
                EventReporter.shared.capture(level: .warning, engine: "prompts", event: "prompts_load_failed",
                    message: "Failed to load prompts.json: \(error.localizedDescription)")
                config = .defaults
                Self.write(config: .defaults, to: storeURL)
            }
        } else {
            config = .defaults
            Self.write(config: .defaults, to: storeURL)
        }
    }

    /// Reload prompts from disk — call after the orchestrator agent rewrites prompts.json.
    func reload() {
        do {
            let data = try Data(contentsOf: storeURL)
            let loaded = try JSONDecoder().decode(PromptConfig.self, from: data)
            config = loaded
        } catch {
            EventReporter.shared.capture(level: .warning, engine: "prompts", event: "prompts_reload_failed",
                message: error.localizedDescription, context: ["path": storeURL.path])
        }
    }

    /// Returns the ghostwriting system prompt with the user's style summary injected.
    func ghostwritingPrompt(styleSummary: String) -> String {
        config.ghostwritingSystem.replacingOccurrences(of: "{STYLE_SUMMARY}", with: styleSummary)
    }

    /// Returns the style analysis prompt appropriate for how many examples exist.
    func styleAnalysisPrompt(forExampleCount count: Int) -> String {
        if count < 10 { return config.styleAnalysisEarly }
        if count < 20 { return config.styleAnalysisGrowing }
        return config.styleAnalysisMature
    }

    /// Returns the context extraction prompt with userName and appName injected.
    func contextExtractionPrompt(userName: String?, appName: String?) -> String {
        var prompt = config.contextExtraction

        let nameClause: String
        if let name = userName, !name.isEmpty {
            nameClause = "The user's name is \(name). They are one of the participants in this conversation."
        } else {
            nameClause = "Identify the user based on which side of the conversation they appear on."
        }

        let appClause: String
        if let app = appName, !app.isEmpty {
            appClause = "This screenshot is from the app \"\(app)\"."
        } else {
            appClause = "Identify which messaging app this is from the UI."
        }

        prompt = prompt.replacingOccurrences(of: "{USER_NAME}", with: nameClause)
        prompt = prompt.replacingOccurrences(of: "{APP_NAME}", with: appClause)
        return prompt
    }

    private static func write(config: PromptConfig, to url: URL) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)
            try data.write(to: url)
        } catch {
            EventReporter.shared.capture(level: .warning, engine: "prompts", event: "prompts_write_failed",
                message: "Failed to write prompts.json: \(error.localizedDescription)")
        }
    }
}
