import Foundation

func testTimelineChat() async {
    runSuite("ChatToolExecutor - dispatches read-only timeline tools") {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(3_600)
        let range = TimelineChatRange(start: start, end: end)
        let query = TimelineChatQuerySpy(cards: [
            TimelineChatCard(
                id: "card-1",
                start: start,
                end: end,
                kind: "activity",
                title: "Built timeline chat",
                summary: "Implemented the first local seam.",
                category: "Work"
            )
        ])
        let executor = ChatToolExecutor(query: query)

        let result = try? executor.execute(TimelineChatToolRequest(name: .fetchTimeline, range: range))
        if case .timeline(let cards)? = result {
            assertEqual(cards.count, 1, "fetch_timeline should return cards from the query layer")
            assertEqual(cards.first?.title, "Built timeline chat")
        } else {
            failTimelineChatTest("fetch_timeline should return timeline cards")
        }
    }

    runSuite("ChatToolExecutor - rejects non-read-only SQL") {
        let rejected = [
            "DELETE FROM timeline_cards",
            "UPDATE timeline_cards SET title = 'x'",
            "PRAGMA table_info(timeline_cards)",
            "SELECT * FROM timeline_cards; DROP TABLE timeline_cards;",
            "SELECT * FROM timeline_cards -- hide a second statement",
            "WITH rows AS (SELECT * FROM timeline_cards) SELECT * FROM rows"
        ]

        for sql in rejected {
            do {
                try ChatToolExecutor.validateReadOnlySQL(sql)
                failTimelineChatTest("Expected SQL to be rejected: \(sql)")
            } catch {
                assertTrue(true, "Rejected unsafe SQL")
            }
        }

        do {
            try ChatToolExecutor.validateReadOnlySQL("SELECT title, summary FROM timeline_cards WHERE day = '2026-07-03';")
            assertTrue(true, "single SELECT statements should be allowed")
        } catch {
            failTimelineChatTest("single SELECT statements should be allowed: \(error)")
        }
    }

    runSuite("ChatPromptBuilder - assembles day context from cards and meetings") {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let card = TimelineChatCard(
            id: "meeting-card",
            start: start,
            end: start.addingTimeInterval(1_800),
            kind: "meeting",
            title: "Standup",
            summary: "Decided to keep chat local-first.",
            detailedSummary: "Follow up with a guarded SQL tool.",
            category: "Meetings",
            captureID: "standup-1"
        )
        let context = TimelineChatPromptContext(
            question: "What did we decide?",
            range: TimelineChatRange(start: start, end: start.addingTimeInterval(3_600)),
            cards: [card],
            meetingMarkdownByCaptureID: ["standup-1": "# Standup\n\nDecision: keep chat local-first."],
            privacyMode: .localOnly
        )

        let prompt = try? ChatPromptBuilder().buildPrompt(context: context)
        assertTrue(prompt?.contains("What did we decide?") == true, "prompt should include the user question")
        assertTrue(prompt?.contains("Decided to keep chat local-first.") == true, "prompt should include card summaries")
        assertTrue(prompt?.contains("Decision: keep chat local-first.") == true, "prompt should include meeting excerpts")
        assertTrue(prompt?.contains("Do not claim to have seen screenshots") == true, "prompt should keep source boundaries explicit")
    }

    runSuite("ChatPromptBuilder - blocks cloud prompts until notice is accepted") {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let context = TimelineChatPromptContext(
            question: "What did I do?",
            range: TimelineChatRange(start: start, end: start.addingTimeInterval(60)),
            cards: [],
            privacyMode: .cloudProvider(name: "Gemini", noticeAccepted: false)
        )

        do {
            _ = try ChatPromptBuilder().buildPrompt(context: context)
            failTimelineChatTest("cloud prompts should require a notice")
        } catch let error as TimelineChatPromptError {
            assertEqual(error, .cloudNoticeRequired("Gemini"))
        } catch {
            failTimelineChatTest("unexpected error: \(error)")
        }

        let accepted = TimelineChatPromptContext(
            question: "What did I do?",
            range: context.range,
            cards: [],
            privacyMode: .cloudProvider(name: "Gemini", noticeAccepted: true)
        )
        do {
            _ = try ChatPromptBuilder().buildPrompt(context: accepted)
            assertTrue(true, "accepted cloud notice should allow prompt assembly")
        } catch {
            failTimelineChatTest("accepted cloud notice should allow prompt assembly: \(error)")
        }
    }

    await runSuite("ChatService - returns provider answer with the built prompt") {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let provider = TimelineAnswerProviderSpy(answerText: "You worked on the local chat seam.")
        let service = ChatService(provider: provider)
        let context = TimelineChatPromptContext(
            question: "What happened?",
            range: TimelineChatRange(start: start, end: start.addingTimeInterval(60)),
            cards: [],
            privacyMode: .localOnly
        )

        do {
            let draft = try await service.answer(context: context)
            assertEqual(draft.answer, "You worked on the local chat seam.")
            assertTrue(draft.prompt.contains("What happened?"), "service should pass the built prompt to the provider")
        } catch {
            failTimelineChatTest("service should answer with the provider: \(error)")
        }
    }
}

private func failTimelineChatTest(_ message: String, file: String = #file, line: Int = #line) {
    assertTrue(false, message, file: file, line: line)
}

private final class TimelineChatQuerySpy: TimelineChatQuerying {
    var cards: [TimelineChatCard]

    init(cards: [TimelineChatCard] = []) {
        self.cards = cards
    }

    func fetchTimeline(range: TimelineChatRange) throws -> [TimelineChatCard] {
        cards
    }

    func fetchObservations(range: TimelineChatRange) throws -> [TimelineChatObservation] {
        []
    }

    func fetchMeeting(captureID: String) throws -> String {
        "# Meeting"
    }

    func runReadOnlySQL(_ sql: String) throws -> TimelineChatSQLResult {
        TimelineChatSQLResult(columns: ["title"], rows: [["Built timeline chat"]])
    }
}

private final class TimelineAnswerProviderSpy: TimelineChatAnswering {
    var answerText: String

    init(answerText: String) {
        self.answerText = answerText
    }

    func answer(prompt: String) async throws -> String {
        answerText
    }
}
