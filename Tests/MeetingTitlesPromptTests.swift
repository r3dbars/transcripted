import Foundation

func testMeetingTitlesPrompt() async {
    runSuite("Cleaning drops filler words and stutters and capitalizes the start") {
        assertEqual(
            MeetingTitlesTranscript.clean("um, so so we we need, uh, the the budget numbers by Friday ."),
            "So we need, the budget numbers by Friday."
        )
        assertEqual(MeetingTitlesTranscript.clean("The The launch slipped, slipped a week."), "The launch slipped a week.")
        assertEqual(MeetingTitlesTranscript.clean("mm-hmm"), "")
    }

    runSuite("The mic speaker is You, unnamed voices are Unknown speaker, and same-speaker lines merge") {
        let markdown = MeetingTitlesFixtures.meetingMarkdown(turns: [
            ("00:01", "Mic/You", "First point about the roadmap."),
            ("00:05", "Mic", "Second point, um, about hiring."),
            ("00:09", "System/Speaker 2", "I have a question."),
            ("00:12", "System/[[Dana]]", "Answering it now."),
            ("00:15", "System/Remote", "Thanks."),
        ])
        let turns = MeetingTitlesTranscript.turns(fromMeetingMarkdown: markdown)
        assertEqual(turns.map(\.speaker), ["You", "Unknown speaker", "Dana", "Unknown speaker"])
        assertEqual(turns.first?.text, "First point about the roadmap. Second point, about hiring.")
        assertEqual(turns.first?.startSeconds, 1)
        assertEqual(
            MeetingTitlesTranscript.render(turns),
            "You: First point about the roadmap. Second point, about hiring.\nUnknown speaker: I have a question.\nDana: Answering it now.\nUnknown speaker: Thanks."
        )
    }

    runSuite("Only the recorder becomes You; a named person on the mic keeps their name") {
        for label in ["Mic/You", "Mic", "Mic/[[You]]"] {
            assertEqual(MeetingTitlesTranscript.speakerName(forLabel: label), "You", label)
        }
        for label in ["Mic/Speaker 2", "Mic/Unknown speaker"] {
            assertEqual(MeetingTitlesTranscript.speakerName(forLabel: label), "Unknown speaker", "another unnamed mic voice: \(label)")
        }
        assertEqual(MeetingTitlesTranscript.speakerName(forLabel: "Mic/Priya"), "Priya")
        assertEqual(MeetingTitlesTranscript.speakerName(forLabel: "System/Speaker 1"), "Unknown speaker")
    }

    runSuite("Raw unstyled transcripts read the same way") {
        let raw = """
        ---
        capture_type: meeting
        ---

        ## Full Transcript

        [00:00] [Mic/You] Thanks for making time today.

        [01:02:03] [System/Priya] Happy to help with the draft.

        ---
        """
        let turns = MeetingTitlesTranscript.turns(fromMeetingMarkdown: raw)
        assertEqual(turns.map(\.speaker), ["You", "Priya"])
        assertEqual(turns.last?.startSeconds, 3_723)
        assertEqual(turns.last?.text, "Happy to help with the draft.")
    }

    runSuite("A transcript under about 40 words is too short to label") {
        let short = MeetingTitlesFixtures.meetingMarkdown(turns: [("00:01", "Mic/You", "Quick test of the mic.")])
        assertNil(MeetingTitlesLabeler.labelableTurns(fromMeetingMarkdown: short))
        assertNotNil(MeetingTitlesLabeler.labelableTurns(fromMeetingMarkdown: MeetingTitlesFixtures.meetingMarkdown()))
    }

    runSuite("The request is the tested one: greedy, thinking off, strict three-field JSON") {
        let bytes = MeetingTitlesPrompt.chatRequestBody(transcript: "You: hello")
        let body = (try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]) ?? [:]
        assertEqual(body["temperature"] as? Int, 0)
        assertEqual(body["top_k"] as? Int, 40)
        assertEqual(body["top_p"] as? Double, 0.9)
        assertEqual(body["repeat_penalty"] as? Double, 1.0)
        assertEqual(body["max_tokens"] as? Int, 400)
        assertEqual((body["chat_template_kwargs"] as? [String: Bool])?["enable_thinking"], false)
        let format = body["response_format"] as? [String: Any]
        let schema = (format?["json_schema"] as? [String: Any])?["schema"] as? [String: Any]
        assertEqual(schema?["required"] as? [String], ["title", "line", "summary"])
        assertEqual(schema?["additionalProperties"] as? Bool, false)
        let messages = body["messages"] as? [[String: String]]
        assertEqual(messages?.map { $0["role"] ?? "" }, ["system", "user"])
        assertTrue(messages?.first?["content"]?.contains("shown in the transcript as \"You\"") == true)
        assertEqual(messages?.last?["content"], "<transcript>\nYou: hello\n</transcript>\n\nReply with the JSON now.")
    }

    runSuite("The request body is the same bytes every time, schema properties in title, line, summary order") {
        let transcript = "You: Quote \"this\" and a \\ path\nPriya: Okay."
        let first = MeetingTitlesPrompt.chatRequestBody(transcript: transcript)
        for _ in 0..<20 {
            assertEqual(MeetingTitlesPrompt.chatRequestBody(transcript: transcript), first)
        }
        let text = String(decoding: first, as: UTF8.self)
        assertTrue(text.contains(#""properties":{"title":{"type":"string"},"line":{"type":"string"},"summary":{"type":"string"}}"#), text)
        let order = ["\"messages\"", "\"max_tokens\"", "\"response_format\"", "\"temperature\"", "\"top_k\"", "\"top_p\"",
                     "\"repeat_penalty\"", "\"chat_template_kwargs\"", "\"cache_prompt\""]
        let positions = order.compactMap { text.range(of: $0)?.lowerBound }
        assertEqual(positions.count, order.count, "every top-level key is present")
        assertEqual(positions, positions.sorted(), "top-level keys keep the tested order")
        let decoded = (try? JSONSerialization.jsonObject(with: first) as? [String: Any]) ?? [:]
        let user = (decoded["messages"] as? [[String: String]])?.last?["content"]
        assertEqual(user, MeetingTitlesPrompt.user(transcript: transcript), "the transcript survives escaping")
    }

    await runSuite("A meeting that fits the budget goes in whole") {
        let turns = MeetingTitlesTranscript.turns(fromMeetingMarkdown: MeetingTitlesFixtures.meetingMarkdown())
        let result = try? await MeetingTitlesFit.fit(turns, systemTokens: 300, countTokens: wordCount)
        assertEqual(result?.transcript, MeetingTitlesTranscript.render(turns))
        assertEqual(result?.droppedTurns, 0)
    }

    await runSuite("A meeting over budget drops middle turns evenly and keeps the first and last minutes") {
        // 120 turns, one every 30 seconds (an hour), 50 words each.
        var turns: [MeetingTitlesTurn] = []
        for index in 0..<120 {
            let words = Array(repeating: "w\(index)", count: 50).joined(separator: " ")
            turns.append(MeetingTitlesTurn(speaker: index % 2 == 0 ? "You" : "Priya", text: words, startSeconds: index * 30))
        }
        let budget = 2_000
        guard let result = try? await MeetingTitlesFit.fit(turns, systemTokens: 100, budget: budget, countTokens: wordCount) else {
            assertTrue(false, "fit threw")
            return
        }
        let available = budget - 100 - MeetingTitlesFit.templateOverheadTokens
        assertTrue(result.tokenCount <= available, "fits the budget, got \(result.tokenCount)")
        assertTrue(result.droppedTurns > 0, "turns were dropped")
        let lines = result.transcript.components(separatedBy: "\n")
        // The first three minutes (turns 0-5) and the last three (114-119) stay whole.
        for index in [0, 1, 5, 114, 119] {
            assertTrue(lines.contains { $0.hasSuffix(" w\(index)") && $0.contains(": w\(index) ") }, "turn \(index) kept")
        }
        // Kept middle turns are spread out, not one clipped block.
        let middle = (6..<114).filter { index in lines.contains { $0.contains(": w\(index) ") } }
        assertTrue(middle.count >= 2, "some middle turns kept")
        if let first = middle.first, let last = middle.last {
            assertTrue(last - first > 50, "kept middle turns span the meeting, got \(first)...\(last)")
        }
    }
}

private func wordCount(_ text: String) async throws -> Int {
    text.split(whereSeparator: \.isWhitespace).count
}
