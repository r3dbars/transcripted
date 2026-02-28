import Foundation

// MARK: - Data Models

/// Final action item after extraction
struct ActionItem: Codable, Equatable {
    let task: String        // Clear, actionable task description
    let owner: String       // Actual name from call, or "You"/"Them"
    let priority: String    // "High" | "Medium" | "Low"
    let dueDate: String?    // Natural language date or nil
    let context: String     // 100-200 word conversational explanation
}

/// Wrapper for action items in the review UI
/// Adds Identifiable conformance and selection state for SwiftUI
struct SelectableActionItem: Identifiable, Equatable {
    let id: UUID
    let item: ActionItem
    var isSelected: Bool

    /// Initialize with an action item, defaulting to selected (opt-out model)
    init(item: ActionItem, isSelected: Bool = true) {
        self.id = UUID()
        self.item = item
        self.isSelected = isSelected
    }
}

/// State container for pending action item reviews
/// Holds all extracted items while user reviews which to add
struct PendingActionItemsReview: Equatable {
    var items: [SelectableActionItem]
    let meetingTitle: String?
    let meetingSummary: String?
    let extractedAt: Date

    /// Number of items currently selected
    var selectedCount: Int {
        items.filter(\.isSelected).count
    }

    /// Total number of items
    var totalCount: Int {
        items.count
    }

    /// Get only the selected action items
    var selectedItems: [ActionItem] {
        items.filter(\.isSelected).map(\.item)
    }

    /// Initialize from an extraction result (all items selected by default)
    init(from result: ExtractionResult) {
        self.items = result.actionItems.map { SelectableActionItem(item: $0) }
        self.meetingTitle = result.meetingTitle
        self.meetingSummary = result.meetingSummary
        self.extractedAt = Date()
    }

    /// Initialize with pre-built items (PHASE 3: supports merging deferred items)
    init(items: [SelectableActionItem], meetingTitle: String?, meetingSummary: String?) {
        self.items = items
        self.meetingTitle = meetingTitle
        self.meetingSummary = meetingSummary
        self.extractedAt = Date()
    }
}

/// Final extraction result returned to callers
struct ExtractionResult: Codable {
    let actionItems: [ActionItem]
    let meetingTitle: String?
    let attendees: [String]?
    let meetingSummary: String?  // 3-5 sentence summary of the meeting
}

// MARK: - Two-Pass Pipeline Models

/// Pass 1: Speaker identification result (maps speaker IDs to real names)
struct SpeakerIdentificationResult: Codable {
    let speakers: [IdentifiedSpeaker]     // All speakers found on the call
    let userSpeakerId: String?            // Which speaker ID is the user (from mic), if identifiable
}

/// Individual speaker identified in the call
struct IdentifiedSpeaker: Codable {
    let name: String
    let speakerId: String?   // "0", "1", "2" - maps to Sortformer speaker IDs
    let confidence: String   // "high" or "medium"
    let evidence: String     // The quote/moment that revealed the name
}

// MARK: - Gemini API Response Models

private struct GeminiResponse: Codable {
    let candidates: [Candidate]?
}

private struct Candidate: Codable {
    let content: Content?
}

private struct Content: Codable {
    let parts: [Part]?
}

private struct Part: Codable {
    let text: String?
}

// MARK: - Action Item Extractor (Two-Pass Pipeline)

enum ActionItemExtractor {
    // Pass 1: Speaker identification - needs good reasoning for context clues
    private static let pass1Endpoint = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-pro:generateContent"
    // Pass 2: Action item extraction - needs strong comprehension
    private static let pass2Endpoint = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-pro:generateContent"

    // MARK: - Pass 1: Speaker Identification Prompt

    /// Create prompt for identifying multiple speakers
    /// - Parameters:
    ///   - userName: The configured user name
    ///   - speakerIds: List of speaker IDs detected by Sortformer (e.g., ["0", "1", "2"])
    private static func speakerIdentificationPrompt(userName: String, speakerIds: [String] = []) -> String {
        let speakerCount = speakerIds.isEmpty ? "unknown number of" : "\(speakerIds.count)"
        let speakerList = speakerIds.isEmpty ? "" : "Detected speakers: \(speakerIds.map { "Speaker \($0)" }.joined(separator: ", "))"

        return """
        Identify who is on this call. There are \(speakerCount) distinct speakers detected.
        \(speakerList)

        ## YOUR TASK
        Map each detected speaker to their real name if possible.

        ## HOW TO IDENTIFY SPEAKERS:
        1. **Greetings**: "Hi Jack", "Hey Sarah", "Good morning, Mike"
        2. **Self-introductions**: "It's Mike", "This is Sarah speaking", "Hey, it's Jack"
        3. **Direct address + response**: "What do you think, Jack?", "Sarah, can you..."
           CRITICAL: When a speaker addresses someone by name, check who speaks NEXT.
           The next speaker to respond is very likely that person. Example:
             [00:30] [System/Speaker 0] Hey Andrew, what do you think about this?
             [00:35] [System/Speaker 1] Yeah, I think we should go with option B.
           → Speaker 1 is likely Andrew.
        4. **Thank-you / sign-off attribution**: "Thanks Mike", "Good point Sarah"
           Check who was speaking BEFORE. The previous speaker is likely that person. Example:
             [01:20] [System/Speaker 2] ...so I think we should ship it next week.
             [01:25] [System/Speaker 0] Great point Travis, I agree.
           → Speaker 2 is likely Travis.
        5. **Referencing themselves**: "I'll send that - this is Jack by the way"
        6. **Context clues**: If someone says "\(userName), your presentation was great" - the speaker is NOT \(userName)
        7. **Process of elimination**: If you identify some speakers and hear other names mentioned
           in conversation, the remaining unidentified speaker is likely one of those names.
           Example: If Speaker 0 is "Jack" and someone says "Mike" to the other speaker,
           the remaining Speaker 1 is likely Mike.
        8. **Known shows/podcasts**: If this appears to be a podcast or show (recurring hosts,
           segment transitions, audience-facing tone), use your knowledge of known shows and hosts.

        ## IMPORTANT RULES:
        - Only identify speakers who are ACTIVELY ON the call (speaking)
        - Names mentioned about ABSENT people ("I talked to Sarah yesterday") are NOT speakers
        - Use TIMESTAMPS to verify speaker correlations — a name followed by a response within a few seconds is strong evidence
        - If you can identify \(userName) (the recorder), note which Speaker ID they are
        - It's OK to only identify SOME speakers - don't guess if you're not confident
        - Most calls have 1-2 other people, but group calls may have more

        ## OUTPUT FORMAT
        ```json
        {
          "speakers": [
            {
              "name": "Jack",
              "speakerId": "0",
              "confidence": "high",
              "evidence": "[00:18] Greeting - 'Hey Jack, how's it going?'"
            },
            {
              "name": "Sarah",
              "speakerId": "1",
              "confidence": "medium",
              "evidence": "[01:45] Direct address - 'Sarah, what do you think?'"
            }
          ],
          "userSpeakerId": "0"
        }
        ```

        - **speakerId**: The detected speaker number (0, 1, 2, etc.) - match to [System/Speaker 0] in transcript
        - **confidence**: "high" = explicitly named, "medium" = inferred from context
        - **evidence**: Include timestamp from transcript to verify speaker mapping
        - **userSpeakerId**: Which speaker ID is \(userName), if identifiable (null if uncertain)

        If you cannot identify any speakers confidently, return:
        ```json
        { "speakers": [], "userSpeakerId": null }
        ```

        TRANSCRIPT:
        """
    }

    // MARK: - Pass 2: Action Item Extraction Prompt

    private static func actionItemExtractionPrompt(userName: String, speakers: [IdentifiedSpeaker]) -> String {
        let speakerNames = speakers.map { $0.name }
        let speakersDescription = speakerNames.isEmpty ? "Unknown" : speakerNames.joined(separator: ", ")

        return """
        Extract action items for \(userName) from this meeting transcript.

        ## SPEAKERS
        - [Mic] = \(userName) (you're building a todo list for this person)
        - [SysAudio] / [SysAudio (Name)] = \(speakersDescription)

        ## THE CORE TEST
        For every potential action item, ask: **"Did someone explicitly say they WILL do something?"**
        - YES → Extract it
        - NO → Skip it

        ---

        ## WHAT TO EXTRACT

        ### 1. \(userName)'s COMMITMENTS
        Things \(userName) said they WILL do:

        ✅ EXTRACT:
        - "I'll send you the proposal tomorrow" → Task: Send proposal
        - "I'm taking off December 23rd through January 1st" → Task: PTO Dec 23 - Jan 1
        - "I'm going to speak at RKO about Pitch Jam" → Task: Prepare RKO Pitch Jam presentation
        - "I need to talk to Sarah about the budget" → Task: Discuss budget with Sarah

        ❌ DO NOT EXTRACT:
        - "I think we should consider..." (opinion, not commitment)
        - "It would be nice to..." (wish, not commitment)
        - "You should try adding..." (advice TO someone else)
        - "That's really interesting" (reaction, not commitment)

        ### 2. FOLLOW-UPS (Others promised something TO \(userName))
        ONLY extract if someone explicitly promised to do something FOR \(userName):

        ✅ EXTRACT:
        - Jack says "I'll send you the docs by Friday" → Task: Follow up with Jack re: docs (due Friday)
        - Sarah says "I'll get back to you on pricing" → Task: Follow up with Sarah re: pricing

        ❌ DO NOT EXTRACT:
        - Jack talks about his own project → NOT your concern
        - Jack shows you a demo of his work → NOT a follow-up
        - Jack mentions he's working on something → NOT a promise TO you

        **THE FOLLOW-UP TEST**: Did they promise to give/send/do something FOR \(userName)? If not, skip it.

        ---

        ## CONCRETE EXAMPLES

        **Example 1 - EXTRACT:**
        > [Mic] "I'm taking December 20th off, so I need to let the AEs know"
        → Task: "Notify AEs about December 20th PTO"
        → Owner: me

        **Example 2 - EXTRACT:**
        > [Mic] "I confirmed we'll have a speaking slot at RKO for Pitch Jam"
        → Task: "Prepare Pitch Jam presentation for RKO"
        → Owner: me

        **Example 3 - DO NOT EXTRACT:**
        > [SysAudio (Jack)] "I've been building this Terraform tool, let me show you..."
        → Jack's project, not \(userName)'s responsibility. SKIP.

        **Example 4 - DO NOT EXTRACT:**
        > [Mic] "You should add error handling to that" (to Jack about his project)
        → Feedback TO Jack, not \(userName)'s task. SKIP.

        **Example 5 - EXTRACT (Follow-up):**
        > [SysAudio (Jack)] "I'll send you the architecture diagram tomorrow"
        → Task: "Follow up with Jack re: architecture diagram"
        → Owner: Jack
        → Due: tomorrow

        **Example 6 - DO NOT EXTRACT:**
        > [SysAudio (Jack)] "I'm planning to add caching next week"
        → Jack's plan for his project. No promise TO \(userName). SKIP.

        ---

        ## MEETING SUMMARY
        Write a 3-5 sentence summary of the meeting. Focus on:
        - Main topics discussed
        - Key decisions made
        - Overall purpose of the meeting
        Keep it concise and professional. Do NOT list action items here - just summarize the discussion.

        ---

        ## OUTPUT FORMAT
        ```json
        {
          "actionItems": [
            {
              "task": "Clear, actionable description",
              "owner": "me" or "speaker name for follow-ups",
              "priority": "High" | "Medium" | "Low",
              "dueDate": "natural language or null",
              "context": "100-200 words of background"
            }
          ],
          "meetingTitle": "Brief title or null",
          "attendees": ["\(userName)", "other names"] or null,
          "meetingSummary": "3-5 sentence summary of the meeting"
        }
        ```

        ### OWNER RULES
        - **Your commitments** (from [Mic]): `owner: "me"`
        - **Follow-ups** (others promised something TO you): `owner: "Jack"` (the person who promised)

        ## PRIORITY
        - **High**: Has deadline within 2 days, or blocking someone
        - **Medium**: Important, mentioned timeline of 1-2 weeks
        - **Low**: No deadline mentioned, nice-to-have

        ## DUE DATES
        Use natural language: "today", "tomorrow", "Friday", "next week", "January 15", "end of year"
        If no date mentioned → null

        ## FINAL CHECK
        Before including ANY item, verify:
        1. Someone explicitly said "I will" / "I'll" / "I need to" / "I'm going to"
        2. It's either \(userName)'s commitment OR someone promised something TO \(userName)
        3. It has a concrete, completable action

        Empty results are fine for casual conversations. Quality over quantity.

        TRANSCRIPT:
        """
    }

    // MARK: - Main Extract Function (Two-Pass Pipeline)

    /// Extract action items from transcript using two-pass Gemini AI pipeline
    /// - Parameters:
    ///   - transcript: The transcript text to analyze
    ///   - apiKey: Gemini API key
    ///   - preIdentifiedSpeakers: Optional pre-identified speakers (skips Pass 1 if provided)
    /// - Returns: ExtractionResult with action items and meeting metadata
    static func extract(
        from transcript: String,
        apiKey: String,
        preIdentifiedSpeakers: SpeakerIdentificationResult? = nil
    ) async throws -> ExtractionResult {
        // Get user's configured name
        let userName = UserDefaults.standard.string(forKey: "userName")
        let effectiveUserName = (userName?.isEmpty ?? true) ? "You" : userName!

        // Pass 1: Identify speakers (skip if pre-identified)
        let speakerResult: SpeakerIdentificationResult
        if let preIdentified = preIdentifiedSpeakers {
            speakerResult = preIdentified
            let speakerNames = speakerResult.speakers.map { $0.name }
            AppLogger.actionItems.info("Pass 1: Using pre-identified speakers", ["count": "\(speakerResult.speakers.count)", "names": speakerNames.joined(separator: ", ")])
        } else {
            AppLogger.actionItems.info("Pass 1: Identifying speakers")
            speakerResult = try await identifySpeakers(from: transcript, userName: effectiveUserName, apiKey: apiKey)
            let speakerNames = speakerResult.speakers.map { $0.name }
            AppLogger.actionItems.info("Pass 1 complete", ["speakersFound": "\(speakerResult.speakers.count)", "names": speakerNames.joined(separator: ", ")])
        }

        // Apply speaker attributions locally (fast, no API call)
        let attributedTranscript = applyAttributions(to: transcript, speakers: speakerResult.speakers)

        // Pass 2: Extract action items from attributed transcript
        AppLogger.actionItems.info("Pass 2: Extracting action items")
        let result = try await extractActionItems(from: attributedTranscript, userName: effectiveUserName, speakers: speakerResult.speakers, apiKey: apiKey)
        AppLogger.actionItems.info("Pass 2 complete", ["actionItems": "\(result.actionItems.count)"])

        return result
    }

    // MARK: - Pass 1: Identify Speakers

    /// Identify speakers from transcript (internal use)
    private static func identifySpeakers(from transcript: String, userName: String, apiKey: String) async throws -> SpeakerIdentificationResult {
        return try await identifySpeakers(from: transcript, speakerIds: [], userName: userName, apiKey: apiKey)
    }

    /// Identify speakers from transcript with known speaker IDs from Sortformer
    /// - Parameters:
    ///   - transcript: The transcript text with speaker labels
    ///   - speakerIds: List of speaker IDs detected by Sortformer (e.g., ["0", "1", "2"])
    ///   - userName: The configured user name
    ///   - apiKey: Gemini API key
    ///   - speakerContext: Optional preamble with DB knowledge (e.g., "Speaker 0: Likely 'Nate' (92% match)")
    /// - Returns: SpeakerIdentificationResult with mappings
    static func identifySpeakers(
        from transcript: String,
        speakerIds: [String],
        userName: String,
        apiKey: String,
        speakerContext: String = ""
    ) async throws -> SpeakerIdentificationResult {
        let prompt = speakerIdentificationPrompt(userName: userName, speakerIds: speakerIds)
        let contextBlock = speakerContext.isEmpty ? "" : "\n\n\(speakerContext)\n"
        let responseText = try await callGeminiAPI(prompt: prompt + contextBlock + "\n\n" + transcript, apiKey: apiKey, endpoint: pass1Endpoint)

        guard let jsonData = responseText.data(using: .utf8) else {
            throw ExtractionError.invalidJSON
        }

        do {
            return try JSONDecoder().decode(SpeakerIdentificationResult.self, from: jsonData)
        } catch {
            // If parsing fails, return empty speakers
            AppLogger.actionItems.warning("Pass 1 parsing failed, using empty speaker list", ["error": "\(error)"])
            return SpeakerIdentificationResult(speakers: [], userSpeakerId: nil)
        }
    }

    // MARK: - Convert Speaker Identification to Mappings

    /// Convert Gemini speaker identification result to TranscriptSaver format
    /// - Parameters:
    ///   - result: Speaker identification result from Gemini
    ///   - channel: Channel prefix for mapping keys ("system" or "mic")
    /// - Returns: Dictionary with keys like "system_0", "system_1"
    static func toSpeakerMappings(
        _ result: SpeakerIdentificationResult,
        channel: String = "system"
    ) -> [String: SpeakerMapping] {
        var mappings: [String: SpeakerMapping] = [:]
        for speaker in result.speakers {
            guard let id = speaker.speakerId else { continue }
            let key = "\(channel)_\(id)"
            mappings[key] = SpeakerMapping(
                speakerId: id,
                identifiedName: speaker.name,
                confidence: speaker.confidence
            )
        }
        return mappings
    }

    // MARK: - Apply Speaker Attributions Locally

    /// Rewrites [SysAudio] tags to include speaker names
    /// For single-speaker calls, attributes all [SysAudio] to that person
    /// For multi-speaker calls, leaves [SysAudio] unattributed (Pass 2 will use context)
    private static func applyAttributions(to transcript: String, speakers: [IdentifiedSpeaker]) -> String {
        // Only apply attributions if we have exactly one speaker identified
        // Multi-speaker attribution is too complex without per-line analysis
        guard speakers.count == 1, let speaker = speakers.first else {
            return transcript
        }

        let suffix = speaker.confidence == "high" ? "" : "?"
        let newTag = "[SysAudio (\(speaker.name)\(suffix))]"

        // Replace all [SysAudio] with [SysAudio (Name)] or [SysAudio (Name?)]
        return transcript.replacingOccurrences(of: "[SysAudio]", with: newTag)
    }

    // MARK: - Pass 2: Extract Action Items

    private static func extractActionItems(from attributedTranscript: String, userName: String, speakers: [IdentifiedSpeaker], apiKey: String) async throws -> ExtractionResult {
        let prompt = actionItemExtractionPrompt(userName: userName, speakers: speakers)
        let responseText = try await callGeminiAPI(prompt: prompt + "\n\n" + attributedTranscript, apiKey: apiKey, endpoint: pass2Endpoint)

        guard let jsonData = responseText.data(using: .utf8) else {
            throw ExtractionError.invalidJSON
        }

        do {
            return try JSONDecoder().decode(ExtractionResult.self, from: jsonData)
        } catch {
            // If parsing fails, return empty result
            AppLogger.actionItems.warning("Pass 2 parsing failed", ["error": "\(error)"])
            return ExtractionResult(actionItems: [], meetingTitle: nil, attendees: nil, meetingSummary: nil)
        }
    }

    // MARK: - Gemini API Helper

    private static func callGeminiAPI(prompt: String, apiKey: String, endpoint: String) async throws -> String {
        guard let url = URL(string: "\(endpoint)?key=\(apiKey)") else {
            throw ExtractionError.invalidURL
        }

        // Build request body
        let requestBody: [String: Any] = [
            "contents": [
                ["parts": [["text": prompt]]]
            ],
            "generationConfig": [
                "responseMimeType": "application/json"
            ]
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: requestBody)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        request.timeoutInterval = 120  // 2 minutes for large transcripts

        // Make API call
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ExtractionError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ExtractionError.apiError(statusCode: httpResponse.statusCode, message: errorText)
        }

        // Parse Gemini response
        let geminiResponse = try JSONDecoder().decode(GeminiResponse.self, from: data)

        guard let text = geminiResponse.candidates?.first?.content?.parts?.first?.text else {
            throw ExtractionError.noContent
        }

        return text
    }
}

// MARK: - Errors

enum ExtractionError: LocalizedError {
    case invalidURL
    case invalidResponse
    case apiError(statusCode: Int, message: String)
    case noContent
    case invalidJSON

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid API URL"
        case .invalidResponse:
            return "Invalid response from server"
        case .apiError(let code, let message):
            return "API error (\(code)): \(message)"
        case .noContent:
            return "No content in response"
        case .invalidJSON:
            return "Invalid JSON in response"
        }
    }
}
