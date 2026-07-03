import Foundation
import MCP
import TranscriptedCaptureKit

// MARK: - Helpers

private extension DateFormatter {
    /// YYYY-MM-DD formatter in the local timezone, matching how transcript dates are stored.
    static let localYYYYMMDD: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        // Intentionally uses the system (local) timezone — transcript dates are stored in local time.
        return f
    }()
}

private func textResult(_ text: String, isError: Bool = false) -> CallTool.Result {
    .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: isError)
}

func registerToolHandlers(server: Server, index: TranscriptIndex, directories: TranscriptedDataDirectories) async {
    await server.withMethodHandler(ListTools.self) { _ in
        .init(tools: [
            Tool(
                name: "list_meetings",
                description: "List meetings with participants, duration, and word count. Filter by date or get the N most recent. This is the starting point — use the returned filename with read_meeting to get full content.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "count": .object([
                            "type": .string("integer"),
                            "description": .string("Number of meetings to return (default: 10, max: 50)")
                        ]),
                        "date": .object([
                            "type": .string("string"),
                            "description": .string("Filter to a specific date (YYYY-MM-DD)")
                        ]),
                        "date_from": .object([
                            "type": .string("string"),
                            "description": .string("Start date filter (YYYY-MM-DD)")
                        ]),
                        "date_to": .object([
                            "type": .string("string"),
                            "description": .string("End date filter (YYYY-MM-DD)")
                        ]),
                    ]),
                ]),
                annotations: .init(readOnlyHint: true)
            ),
            Tool(
                name: "read_meeting",
                description: "Read the full transcript of a specific meeting. Returns the complete dialogue with speaker names and timestamps. Use list_meetings first to get the filename.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "filename": .object([
                            "type": .string("string"),
                            "description": .string("Meeting filename from list_meetings (e.g. 'Call_2026-03-26_16-04-11')")
                        ]),
                        "section": .object([
                            "type": .string("string"),
                            "description": .string("Which section to return: 'full' (default — complete transcript), 'transcript' (dialogue only), or 'speakers' (analytics only)")
                        ]),
                    ]),
                    "required": .array([.string("filename")]),
                ]),
                annotations: .init(readOnlyHint: true)
            ),
            Tool(
                name: "list_dictations",
                description: "List saved dictation days with entry counts, source apps, and recent titles. Useful when you want quick access to private notes, voice memos, or dictated follow-ups.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "count": .object([
                            "type": .string("integer"),
                            "description": .string("Number of dictation days to return (default: 10, max: 50)")
                        ]),
                        "date": .object([
                            "type": .string("string"),
                            "description": .string("Filter to a specific date (YYYY-MM-DD)")
                        ]),
                        "date_from": .object([
                            "type": .string("string"),
                            "description": .string("Start date filter (YYYY-MM-DD)")
                        ]),
                        "date_to": .object([
                            "type": .string("string"),
                            "description": .string("End date filter (YYYY-MM-DD)")
                        ]),
                    ]),
                ]),
                annotations: .init(readOnlyHint: true)
            ),
            Tool(
                name: "search",
                description: "Full-text search across all meeting transcripts. Returns matching utterances with speaker, timestamp, and meeting context. Optionally filter by speaker name (supports variants: Mike finds Michael) or date range.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object([
                            "type": .string("string"),
                            "description": .string("Search query (e.g. 'product roadmap discussion')")
                        ]),
                        "speaker": .object([
                            "type": .string("string"),
                            "description": .string("Filter to utterances by this speaker")
                        ]),
                        "date_from": .object([
                            "type": .string("string"),
                            "description": .string("Start date filter (YYYY-MM-DD)")
                        ]),
                        "date_to": .object([
                            "type": .string("string"),
                            "description": .string("End date filter (YYYY-MM-DD)")
                        ]),
                    ]),
                    "required": .array([.string("query")]),
                ]),
                annotations: .init(readOnlyHint: true)
            ),
            Tool(
                name: "read_dictation",
                description: "Read a saved dictation day or one specific dictation entry by ID. Use list_dictations or recent_context first to find the filename or entry_id you need.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "filename": .object([
                            "type": .string("string"),
                            "description": .string("Dictation day filename (e.g. 'Dictations_2026-04-07')")
                        ]),
                        "entry_id": .object([
                            "type": .string("string"),
                            "description": .string("Optional entry ID from recent_context or search_context to return one dictation entry")
                        ]),
                    ]),
                    "required": .array([.string("filename")]),
                ]),
                annotations: .init(readOnlyHint: true)
            ),
            Tool(
                name: "search_context",
                description: "Search across saved meetings, dictations, or both. Great for finding everything you captured about a topic, regardless of whether it came from a meeting or a quick dictated note.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object([
                            "type": .string("string"),
                            "description": .string("Search query")
                        ]),
                        "kind": .object([
                            "type": .string("string"),
                            "description": .string("Which context to search: 'all' (default), 'meeting', or 'dictation'")
                        ]),
                        "speaker": .object([
                            "type": .string("string"),
                            "description": .string("Optional speaker filter for meeting results")
                        ]),
                        "count": .object([
                            "type": .string("integer"),
                            "description": .string("Maximum number of context items to return (default: 10, max: 50)")
                        ]),
                        "date_from": .object([
                            "type": .string("string"),
                            "description": .string("Start date filter (YYYY-MM-DD)")
                        ]),
                        "date_to": .object([
                            "type": .string("string"),
                            "description": .string("End date filter (YYYY-MM-DD)")
                        ]),
                    ]),
                    "required": .array([.string("query")]),
                ]),
                annotations: .init(readOnlyHint: true)
            ),
            Tool(
                name: "recent_context",
                description: "List the most recent saved meetings and dictations together in one feed. Great for quickly orienting an agent before it starts summarizing or planning.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "kind": .object([
                            "type": .string("string"),
                            "description": .string("Which context to list: 'all' (default), 'meeting', or 'dictation'")
                        ]),
                        "count": .object([
                            "type": .string("integer"),
                            "description": .string("Maximum number of items to return (default: 10, max: 50)")
                        ]),
                        "date_from": .object([
                            "type": .string("string"),
                            "description": .string("Start date filter (YYYY-MM-DD)")
                        ]),
                        "date_to": .object([
                            "type": .string("string"),
                            "description": .string("End date filter (YYYY-MM-DD)")
                        ]),
                    ]),
                ]),
                annotations: .init(readOnlyHint: true)
            ),
            Tool(
                name: "who_is",
                description: "Get everything known about a person: meeting count, last seen, total speaking time, who they typically appear with, and representative quotes. Great for prepping before a meeting.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "speaker": .object([
                            "type": .string("string"),
                            "description": .string("Person's name (supports variants: Mike finds Michael)")
                        ]),
                    ]),
                    "required": .array([.string("speaker")]),
                ]),
                annotations: .init(readOnlyHint: true)
            ),
            Tool(
                name: "recap",
                description: "Get a structured digest of all meetings in a date range. Returns each meeting with title, speakers, duration, and a preview of the first ~200 words. Perfect for 'What did I miss Monday through Wednesday?' or 'Summarize today's meetings'.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "date_from": .object([
                            "type": .string("string"),
                            "description": .string("Start date (YYYY-MM-DD). Defaults to today.")
                        ]),
                        "date_to": .object([
                            "type": .string("string"),
                            "description": .string("End date (YYYY-MM-DD). Defaults to same as date_from.")
                        ]),
                    ]),
                ]),
                annotations: .init(readOnlyHint: true)
            ),
            Tool(
                name: "list_action_items",
                description: "Roll up action items across every meeting. Filter by owner (supports name variants: Nate finds Nate Smith), by status (open by default, or 'done'/'all'), by a free-text query, or by date range. Use this for 'every open action item assigned to me' or 'what did we commit to last week'. Depends on the meeting summary index.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "owner": .object([
                            "type": .string("string"),
                            "description": .string("Filter to action items assigned to this person (e.g. 'Nate')")
                        ]),
                        "status": .object([
                            "type": .string("string"),
                            "description": .string("Which items to return: 'open' (default), 'done', or 'all'")
                        ]),
                        "query": .object([
                            "type": .string("string"),
                            "description": .string("Optional full-text filter on the action item text")
                        ]),
                        "date_from": .object([
                            "type": .string("string"),
                            "description": .string("Start date filter (YYYY-MM-DD)")
                        ]),
                        "date_to": .object([
                            "type": .string("string"),
                            "description": .string("End date filter (YYYY-MM-DD)")
                        ]),
                        "count": .object([
                            "type": .string("integer"),
                            "description": .string("Maximum items to return (default: 50, max: 200)")
                        ]),
                    ]),
                ]),
                annotations: .init(readOnlyHint: true)
            ),
            Tool(
                name: "list_decisions",
                description: "Roll up decisions across every meeting. Optionally filter by a free-text query or date range. Use this for 'what did we decide about pricing' or 'all decisions this quarter'. Depends on the meeting summary index.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object([
                            "type": .string("string"),
                            "description": .string("Optional full-text filter on the decision text")
                        ]),
                        "date_from": .object([
                            "type": .string("string"),
                            "description": .string("Start date filter (YYYY-MM-DD)")
                        ]),
                        "date_to": .object([
                            "type": .string("string"),
                            "description": .string("End date filter (YYYY-MM-DD)")
                        ]),
                        "count": .object([
                            "type": .string("integer"),
                            "description": .string("Maximum decisions to return (default: 50, max: 200)")
                        ]),
                    ]),
                ]),
                annotations: .init(readOnlyHint: true)
            ),
            Tool(
                name: "digest",
                description: "Cross-meeting summary for a time window: every meeting in range that has structured summary facts, with its decisions, action items, and open questions, plus rolled-up counts. Use for 'what happened across all my meetings this week'. Depends on the meeting summary index.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "date_from": .object([
                            "type": .string("string"),
                            "description": .string("Start date (YYYY-MM-DD). Defaults to today.")
                        ]),
                        "date_to": .object([
                            "type": .string("string"),
                            "description": .string("End date (YYYY-MM-DD). Defaults to same as date_from.")
                        ]),
                    ]),
                ]),
                annotations: .init(readOnlyHint: true)
            ),
            Tool(
                name: "decisions",
                description: "Find decisions across meeting summaries. Returns local structured receipts with meetingId, timestamp when available, and quote. No semantic embeddings or LLM synthesis.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "topic": .object([
                            "type": .string("string"),
                            "description": .string("Optional topic filter, e.g. pricing")
                        ]),
                        "range": .object([
                            "type": .string("string"),
                            "description": .string("Optional date range: YYYY-MM-DD, YYYY-MM-DD..YYYY-MM-DD, today, or all")
                        ]),
                        "count": .object([
                            "type": .string("integer"),
                            "description": .string("Maximum receipts to return (default: 20, max: 100)")
                        ]),
                    ]),
                ]),
                annotations: .init(readOnlyHint: true)
            ),
            Tool(
                name: "commitments",
                description: "Find action-item commitments across meeting summaries. Filter by person and date range. Returns local structured receipts with meetingId, timestamp when available, and quote.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "person": .object([
                            "type": .string("string"),
                            "description": .string("Optional person/owner filter, e.g. Sarah")
                        ]),
                        "range": .object([
                            "type": .string("string"),
                            "description": .string("Optional date range: YYYY-MM-DD, YYYY-MM-DD..YYYY-MM-DD, today, or all")
                        ]),
                        "count": .object([
                            "type": .string("integer"),
                            "description": .string("Maximum receipts to return (default: 20, max: 100)")
                        ]),
                    ]),
                ]),
                annotations: .init(readOnlyHint: true)
            ),
            Tool(
                name: "open_questions",
                description: "Find open questions across meeting summaries for a project/topic. Returns local structured receipts with meetingId, timestamp when available, and quote.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "project": .object([
                            "type": .string("string"),
                            "description": .string("Optional project/topic filter")
                        ]),
                        "range": .object([
                            "type": .string("string"),
                            "description": .string("Optional date range: YYYY-MM-DD, YYYY-MM-DD..YYYY-MM-DD, today, or all")
                        ]),
                        "count": .object([
                            "type": .string("integer"),
                            "description": .string("Maximum receipts to return (default: 20, max: 100)")
                        ]),
                    ]),
                ]),
                annotations: .init(readOnlyHint: true)
            ),
            Tool(
                name: "search_meetings",
                description: "Keyword search over local meeting transcript utterances. Returns structured receipts with meetingId, timestamp, and quote. This is not semantic search.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object([
                            "type": .string("string"),
                            "description": .string("Keyword query")
                        ]),
                        "range": .object([
                            "type": .string("string"),
                            "description": .string("Optional date range: YYYY-MM-DD, YYYY-MM-DD..YYYY-MM-DD, today, or all")
                        ]),
                        "count": .object([
                            "type": .string("integer"),
                            "description": .string("Maximum receipts to return (default: 20, max: 100)")
                        ]),
                    ]),
                    "required": .array([.string("query")]),
                ]),
                annotations: .init(readOnlyHint: true)
            ),
        ])
    }

    await server.withMethodHandler(CallTool.self) { params in
        do {
            switch params.name {
            case "list_meetings":
                return try handleListMeetings(params: params, index: index, meetingDirs: directories.meetingDirs)
            case "list_dictations":
                return try handleListDictations(params: params, index: index)
            case "read_meeting":
                return try handleReadMeeting(params: params, meetingDirs: directories.meetingDirs)
            case "read_dictation":
                return try handleReadDictation(params: params, dictationDirs: directories.dictationDirs)
            case "search":
                return try handleSearch(params: params, index: index, meetingDirs: directories.meetingDirs)
            case "search_context":
                return try handleSearchContext(params: params, index: index, meetingDirs: directories.meetingDirs)
            case "recent_context":
                return try handleRecentContext(params: params, index: index, meetingDirs: directories.meetingDirs)
            case "who_is":
                return try handleWhoIs(params: params, index: index)
            case "recap":
                return try handleRecap(params: params, index: index, meetingDirs: directories.meetingDirs)
            case "list_action_items":
                return try handleListActionItems(params: params, index: index, meetingDirs: directories.meetingDirs)
            case "list_decisions":
                return try handleListDecisions(params: params, index: index, meetingDirs: directories.meetingDirs)
            case "digest":
                return try handleDigest(params: params, index: index, meetingDirs: directories.meetingDirs)
            case "decisions":
                return try handleDecisions(params: params, index: index, meetingDirs: directories.meetingDirs)
            case "commitments":
                return try handleCommitments(params: params, index: index, meetingDirs: directories.meetingDirs)
            case "open_questions":
                return try handleOpenQuestions(params: params, index: index, meetingDirs: directories.meetingDirs)
            case "search_meetings":
                return try handleSearchMeetings(params: params, index: index, meetingDirs: directories.meetingDirs)
            default:
                return textResult("Unknown tool: \(params.name)", isError: true)
            }
        } catch {
            return textResult("Error: \(error.localizedDescription)", isError: true)
        }
    }
}

// MARK: - list_meetings

func handleListMeetings(params: CallTool.Parameters, index: TranscriptIndex, meetingDirs: [URL]) throws -> CallTool.Result {
    let count = params.arguments?["count"]?.intValue ?? 10
    let date = params.arguments?["date"]?.stringValue
    let dateFrom = params.arguments?["date_from"]?.stringValue ?? date
    let dateTo = params.arguments?["date_to"]?.stringValue ?? date

    var results = try index.listMeetings(count: count, dateFrom: dateFrom, dateTo: dateTo)

    // Populate titles from markdown YAML frontmatter
    for i in results.indices {
        guard case .valid(let mdURL) = PathSecurity.resolveReadableFile(
            named: results[i].filename,
            appendingExtension: "md",
            in: meetingDirs
        ) else { continue }
        if let content = try? String(contentsOf: mdURL, encoding: .utf8) {
            results[i].title = extractTitle(from: content) ?? results[i].filename
        }
    }

    if results.isEmpty {
        return textResult("No meetings found.")
    }

    trackAgentCaptureQueryObserved(
        queryKind: "list",
        artifactKind: "meeting",
        captureDate: latestMeetingDate(in: results),
        sourceCount: results.count
    )

    let json = try JSONEncoder.pretty.encode(results)
    return textResult(String(data: json, encoding: .utf8) ?? "[]")
}

func handleListDictations(params: CallTool.Parameters, index: TranscriptIndex) throws -> CallTool.Result {
    let count = params.arguments?["count"]?.intValue ?? 10
    let date = params.arguments?["date"]?.stringValue
    let dateFrom = params.arguments?["date_from"]?.stringValue ?? date
    let dateTo = params.arguments?["date_to"]?.stringValue ?? date

    let results = try index.listDictationDays(count: count, dateFrom: dateFrom, dateTo: dateTo)

    if results.isEmpty {
        return textResult("No dictations found.")
    }

    trackAgentCaptureQueryObserved(
        queryKind: "list",
        artifactKind: "dictation",
        captureDate: latestDictationDayDate(in: results),
        sourceCount: results.count
    )

    let json = try JSONEncoder.pretty.encode(results)
    return textResult(String(data: json, encoding: .utf8) ?? "[]")
}

/// Extract title from markdown YAML frontmatter
private func extractTitle(from content: String) -> String? {
    CaptureMarkdown.extractTitle(from: content)
}

/// Returns non-empty transcript dialogue lines from the `## Full Transcript` section, filtering boilerplate.
private func extractDialogueLines(from content: String) -> [String] {
    let markers = ["## Full Transcript\n", "## Transcript\n"]
    guard let range = markers.compactMap({ content.range(of: $0) }).first else { return [] }
    return String(content[range.upperBound...])
        .components(separatedBy: "\n")
        .filter { !$0.isEmpty && !$0.hasPrefix("*Generated by") && $0 != "---" }
}

// MARK: - read_meeting

private func handleReadMeeting(params: CallTool.Parameters, meetingDirs: [URL]) throws -> CallTool.Result {
    guard let filename = params.arguments?["filename"]?.stringValue, !filename.isEmpty else {
        return textResult("Missing required parameter: filename", isError: true)
    }

    let section = params.arguments?["section"]?.stringValue ?? "full"

    let mdURL: URL
    switch PathSecurity.resolveReadableFile(named: filename, appendingExtension: "md", in: meetingDirs) {
    case .valid(let url):
        mdURL = url
    case .missing:
        return textResult("Meeting not found: \(filename). Use list_meetings to see available meetings.", isError: true)
    case .invalid:
        return textResult("Invalid filename: \(filename)", isError: true)
    }

    guard let content = try? String(contentsOf: mdURL, encoding: .utf8) else {
        return textResult("Meeting not found: \(filename). Use list_meetings to see available meetings.", isError: true)
    }

    trackAgentCaptureQueryObserved(
        queryKind: "read",
        artifactKind: "meeting",
        captureDate: captureDateFromMeetingMarkdown(content),
        sourceCount: 1
    )

    switch section {
    case "transcript":
        let dialogue = extractDialogueLines(from: content).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return textResult(dialogue.isEmpty ? content : dialogue)

    case "speakers":
        // Return YAML frontmatter + speaker analytics section
        var result = ""
        if content.count >= 8, content.hasPrefix("---"),
           let endRange = content.range(of: "\n---\n", range: content.index(content.startIndex, offsetBy: 3)..<content.endIndex) {
            result += String(content[content.startIndex...endRange.upperBound])
        }
        if let analyticsRange = content.range(of: "## Channel & Speaker Analytics") {
            if let transcriptRange = content.range(of: "## Full Transcript") {
                result += "\n" + String(content[analyticsRange.lowerBound..<transcriptRange.lowerBound])
            } else {
                result += "\n" + String(content[analyticsRange.lowerBound...])
            }
        }
        return textResult(result.isEmpty ? content : result)

    default: // "full"
        return textResult(content)
    }
}

private func handleReadDictation(params: CallTool.Parameters, dictationDirs: [URL]) throws -> CallTool.Result {
    guard let filename = params.arguments?["filename"]?.stringValue, !filename.isEmpty else {
        return textResult("Missing required parameter: filename", isError: true)
    }

    let entryId = params.arguments?["entry_id"]?.stringValue
    let markdownURL: URL
    switch PathSecurity.resolveReadableFile(named: filename, appendingExtension: "md", in: dictationDirs) {
    case .valid(let url):
        markdownURL = url
    case .missing:
        return textResult("Dictation not found: \(filename). Use list_dictations to see available days.", isError: true)
    case .invalid:
        return textResult("Invalid filename: \(filename)", isError: true)
    }

    guard let day = TranscriptLoader.loadDictationDay(markdownURL) else {
        return textResult("Dictation not found: \(filename). Use list_dictations to see available days.", isError: true)
    }

    if let entryId {
        guard let entry = day.entries.first(where: { $0.id == entryId }) else {
            return textResult("Entry not found: \(entryId). Use recent_context or search_context to inspect entry IDs.", isError: true)
        }

        trackAgentCaptureQueryObserved(
            queryKind: "read",
            artifactKind: "dictation",
            captureDate: parseCaptureDate(entry.createdAt),
            sourceCount: 1
        )

        let result = """
        # \(entry.title)

        Captured: \(entry.createdAt)
        Source app: \(entry.sourceAppName)
        Delivery: \(entry.delivery)
        Words: \(entry.wordCount)

        \(entry.text)
        """
        return textResult(result)
    }

    trackAgentCaptureQueryObserved(
        queryKind: "read",
        artifactKind: "dictation",
        captureDate: parseCaptureDate(day.entries.last?.createdAt ?? day.date),
        sourceCount: day.entries.count
    )

    guard let content = try? String(contentsOf: markdownURL, encoding: .utf8) else {
        let json = try JSONEncoder.pretty.encode(day)
        return textResult(String(data: json, encoding: .utf8) ?? "{}")
    }

    return textResult(content)
}

// MARK: - search

private func handleSearch(params: CallTool.Parameters, index: TranscriptIndex, meetingDirs: [URL]) throws -> CallTool.Result {
    guard let query = params.arguments?["query"]?.stringValue, !query.isEmpty else {
        return textResult("Missing required parameter: query", isError: true)
    }

    let speaker = params.arguments?["speaker"]?.stringValue
    let dateFrom = params.arguments?["date_from"]?.stringValue
    let dateTo = params.arguments?["date_to"]?.stringValue

    var results = try index.searchUtterances(query: query, speaker: speaker, dateFrom: dateFrom, dateTo: dateTo)
    hydrateMeetingSearchTitles(in: &results, meetingDirs: meetingDirs)

    if results.results.isEmpty {
        var msg = "No results found for \"\(query)\""
        if let s = speaker { msg += " by \(s)" }
        return textResult(msg)
    }

    trackAgentCaptureQueryObserved(
        queryKind: "search",
        artifactKind: "meeting",
        captureDate: latestMeetingSearchDate(in: results),
        sourceCount: results.results.count
    )

    let json = try JSONEncoder.pretty.encode(results)
    return textResult(String(data: json, encoding: .utf8) ?? "[]")
}

private func handleSearchContext(params: CallTool.Parameters, index: TranscriptIndex, meetingDirs: [URL]) throws -> CallTool.Result {
    guard let query = params.arguments?["query"]?.stringValue, !query.isEmpty else {
        return textResult("Missing required parameter: query", isError: true)
    }

    let kind = parseContextKind(params.arguments?["kind"]?.stringValue)
    let speaker = params.arguments?["speaker"]?.stringValue
    let count = max(1, min(params.arguments?["count"]?.intValue ?? 10, 50))
    let dateFrom = params.arguments?["date_from"]?.stringValue
    let dateTo = params.arguments?["date_to"]?.stringValue

    var results = try index.searchContext(
        query: query,
        speaker: speaker,
        kind: kind,
        dateFrom: dateFrom,
        dateTo: dateTo,
        maxItems: count
    )

    hydrateMeetingTitles(in: &results.results, kind: \.kind, filename: \.filename, title: \.title, meetingDirs: meetingDirs)

    if results.results.isEmpty {
        return textResult("No context found for \"\(query)\".")
    }

    trackAgentCaptureQueryObserved(
        queryKind: "search",
        artifactKind: artifactKind(for: results.results.map(\.kind)),
        captureDate: latestContextSearchDate(in: results.results),
        sourceCount: results.results.count
    )

    let json = try JSONEncoder.pretty.encode(results)
    return textResult(String(data: json, encoding: .utf8) ?? "{}")
}

func handleRecentContext(params: CallTool.Parameters, index: TranscriptIndex, meetingDirs: [URL]) throws -> CallTool.Result {
    let kind = parseContextKind(params.arguments?["kind"]?.stringValue)
    let count = max(1, min(params.arguments?["count"]?.intValue ?? 10, 50))
    let dateFrom = params.arguments?["date_from"]?.stringValue
    let dateTo = params.arguments?["date_to"]?.stringValue

    var result = try index.listRecentContext(kind: kind, count: count, dateFrom: dateFrom, dateTo: dateTo)
    hydrateMeetingTitles(in: &result.items, kind: \.kind, filename: \.filename, title: \.title, meetingDirs: meetingDirs)

    if result.items.isEmpty {
        return textResult("No recent context found.")
    }

    trackAgentCaptureQueryObserved(
        queryKind: "recent",
        artifactKind: artifactKind(for: result.items.map(\.kind)),
        captureDate: latestRecentContextDate(in: result.items),
        sourceCount: result.items.count
    )

    let json = try JSONEncoder.pretty.encode(result)
    return textResult(String(data: json, encoding: .utf8) ?? "{}")
}

// MARK: - who_is

private func handleWhoIs(params: CallTool.Parameters, index: TranscriptIndex) throws -> CallTool.Result {
    guard let speaker = params.arguments?["speaker"]?.stringValue, !speaker.isEmpty else {
        return textResult("Missing required parameter: speaker", isError: true)
    }

    let profile = try index.getPersonProfile(speaker: speaker)

    if profile.meetingCount == 0 {
        return textResult("No meetings found for \"\(speaker)\". Try a different name or use list_meetings to see known speakers.")
    }

    trackAgentCaptureQueryObserved(
        queryKind: "speaker_lookup",
        artifactKind: "meeting",
        captureDate: parseCaptureDate(profile.lastSeen),
        sourceCount: profile.meetingCount
    )

    let json = try JSONEncoder.pretty.encode(profile)
    return textResult(String(data: json, encoding: .utf8) ?? "{}")
}

// MARK: - recap

private func handleRecap(params: CallTool.Parameters, index: TranscriptIndex, meetingDirs: [URL]) throws -> CallTool.Result {
    // Use local calendar so "today" matches transcript dates (which are stored in local time)
    let today = DateFormatter.localYYYYMMDD.string(from: Date())
    let dateFrom = params.arguments?["date_from"]?.stringValue ?? String(today)
    let dateTo = params.arguments?["date_to"]?.stringValue ?? dateFrom

    let meetings = try index.listMeetings(count: 50, dateFrom: dateFrom, dateTo: dateTo)

    if meetings.isEmpty {
        return textResult("No meetings found from \(dateFrom) to \(dateTo).")
    }

    var recapParts: [RecapEntry] = []

    for meeting in meetings {
        // Read first ~200 words of transcript as preview
        guard case .valid(let mdURL) = PathSecurity.resolveReadableFile(
            named: meeting.filename,
            appendingExtension: "md",
            in: meetingDirs
        ) else { continue }
        var preview = ""
        var title = meeting.filename
        if let content = try? String(contentsOf: mdURL, encoding: .utf8) {
            title = extractTitle(from: content) ?? meeting.filename
            preview = extractDialogueLines(from: content).prefix(15).joined(separator: "\n")
        }

        recapParts.append(RecapEntry(
            filename: meeting.filename,
            title: title,
            date: meeting.date,
            datetime: meeting.datetime,
            durationFormatted: formatDuration(meeting.durationSeconds),
            speakers: meeting.speakers.map { $0.name },
            wordCount: meeting.wordCount,
            preview: preview
        ))
    }

    let result = RecapResult(
        dateRange: dateFrom == dateTo ? dateFrom : "\(dateFrom) to \(dateTo)",
        meetingCount: recapParts.count,
        meetings: recapParts
    )

    trackAgentCaptureQueryObserved(
        queryKind: "recap",
        artifactKind: "meeting",
        captureDate: latestRecapDate(in: recapParts),
        sourceCount: recapParts.count
    )

    let json = try JSONEncoder.pretty.encode(result)
    return textResult(String(data: json, encoding: .utf8) ?? "[]")
}

// MARK: - list_action_items / list_decisions / digest (cross-meeting rollups)

private func handleListActionItems(params: CallTool.Parameters, index: TranscriptIndex, meetingDirs: [URL]) throws -> CallTool.Result {
    let owner = params.arguments?["owner"]?.stringValue
    let query = params.arguments?["query"]?.stringValue
    let status = ActionItemStatusFilter(raw: params.arguments?["status"]?.stringValue)
    let dateFrom = params.arguments?["date_from"]?.stringValue
    let dateTo = params.arguments?["date_to"]?.stringValue
    let count = params.arguments?["count"]?.intValue ?? 50

    var result = try index.listActionItems(
        owner: owner, query: query, status: status,
        dateFrom: dateFrom, dateTo: dateTo, maxItems: count
    )

    for i in result.items.indices {
        result.items[i].meetingTitle = meetingTitle(for: result.items[i].filename, meetingDirs: meetingDirs)
    }

    if result.items.isEmpty {
        var msg = "No \(status == .all ? "" : status.rawValue + " ")action items found"
        if let owner, !owner.isEmpty { msg += " for \(owner)" }
        msg += ". Action items come from the meeting summary index; if summaries have not been indexed yet, this will be empty."
        return textResult(msg)
    }

    let json = try JSONEncoder.pretty.encode(result)
    return textResult(String(data: json, encoding: .utf8) ?? "{}")
}

private func handleListDecisions(params: CallTool.Parameters, index: TranscriptIndex, meetingDirs: [URL]) throws -> CallTool.Result {
    let query = params.arguments?["query"]?.stringValue
    let dateFrom = params.arguments?["date_from"]?.stringValue
    let dateTo = params.arguments?["date_to"]?.stringValue
    let count = params.arguments?["count"]?.intValue ?? 50

    var result = try index.listDecisions(query: query, dateFrom: dateFrom, dateTo: dateTo, maxItems: count)

    for i in result.decisions.indices {
        result.decisions[i].meetingTitle = meetingTitle(for: result.decisions[i].filename, meetingDirs: meetingDirs)
    }

    if result.decisions.isEmpty {
        return textResult("No decisions found. Decisions come from the meeting summary index; if summaries have not been indexed yet, this will be empty.")
    }

    let json = try JSONEncoder.pretty.encode(result)
    return textResult(String(data: json, encoding: .utf8) ?? "{}")
}

private func handleDigest(params: CallTool.Parameters, index: TranscriptIndex, meetingDirs: [URL]) throws -> CallTool.Result {
    // Default to today when no window is given, matching recap's behavior.
    let today = DateFormatter.localYYYYMMDD.string(from: Date())
    let dateFrom = params.arguments?["date_from"]?.stringValue ?? today
    let dateTo = params.arguments?["date_to"]?.stringValue ?? dateFrom

    var result = try index.digest(dateFrom: dateFrom, dateTo: dateTo)

    for i in result.meetings.indices {
        result.meetings[i].title = meetingTitle(for: result.meetings[i].filename, meetingDirs: meetingDirs)
    }

    if result.meetings.isEmpty {
        return textResult("No summarized meetings found for \(result.dateRange). Digest reads the meeting summary index; if summaries have not been indexed yet, this will be empty.")
    }

    let json = try JSONEncoder.pretty.encode(result)
    return textResult(String(data: json, encoding: .utf8) ?? "{}")
}

// MARK: - decisions / commitments / open_questions / search_meetings

func handleDecisions(params: CallTool.Parameters, index: TranscriptIndex, meetingDirs: [URL]) throws -> CallTool.Result {
    let topic = params.arguments?["topic"]?.stringValue
    let range = parseToolRange(params.arguments?["range"]?.stringValue)
    let count = cappedCrossMeetingCount(params.arguments?["count"]?.intValue)
    let indexed = try index.listDecisions(
        query: topic,
        dateFrom: range.dateFrom,
        dateTo: range.dateTo,
        maxItems: count + 1
    )
    var receipts = indexed.decisions.prefix(count).map { item in
        CrossMeetingReceipt(
            meetingId: item.filename,
            meetingTitle: meetingTitle(for: item.filename, meetingDirs: meetingDirs),
            timestamp: nil,
            quote: item.text,
            date: item.date,
            datetime: item.datetime,
            kind: "decision",
            person: nil
        )
    }
    hydrateReceiptTitles(&receipts, meetingDirs: meetingDirs)
    let result = CrossMeetingToolResult(
        query: topic,
        range: range.label,
        count: receipts.count,
        truncated: indexed.truncated || indexed.decisions.count > count,
        results: receipts
    )
    return try encodedToolResult(result)
}

func handleCommitments(params: CallTool.Parameters, index: TranscriptIndex, meetingDirs: [URL]) throws -> CallTool.Result {
    let person = params.arguments?["person"]?.stringValue
    let range = parseToolRange(params.arguments?["range"]?.stringValue)
    let count = cappedCrossMeetingCount(params.arguments?["count"]?.intValue)
    let indexed = try index.listActionItems(
        owner: person,
        query: nil,
        status: .open,
        dateFrom: range.dateFrom,
        dateTo: range.dateTo,
        maxItems: count + 1
    )
    var receipts = indexed.items.prefix(count).map { item in
        CrossMeetingReceipt(
            meetingId: item.filename,
            meetingTitle: meetingTitle(for: item.filename, meetingDirs: meetingDirs),
            timestamp: nil,
            quote: item.owner.map { "\($0): \(item.text)" } ?? item.text,
            date: item.date,
            datetime: item.datetime,
            kind: "commitment",
            person: item.owner
        )
    }
    hydrateReceiptTitles(&receipts, meetingDirs: meetingDirs)
    let result = CrossMeetingToolResult(
        query: person,
        range: range.label,
        count: receipts.count,
        truncated: indexed.truncated || indexed.items.count > count,
        results: receipts
    )
    return try encodedToolResult(result)
}

func handleOpenQuestions(params: CallTool.Parameters, index: TranscriptIndex, meetingDirs: [URL]) throws -> CallTool.Result {
    let project = params.arguments?["project"]?.stringValue
    let range = parseToolRange(params.arguments?["range"]?.stringValue)
    let count = cappedCrossMeetingCount(params.arguments?["count"]?.intValue)
    let fetchLimit = project?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? 1000 : count + 1
    let indexed = try index.listSummaryItems(
        kind: TranscriptIndex.SummaryItemKind.openQuestion,
        dateFrom: range.dateFrom,
        dateTo: range.dateTo,
        limit: fetchLimit
    )
    let filtered = filterSummaryItems(indexed, matching: project)
    var receipts = filtered.prefix(count).map { item in
        CrossMeetingReceipt(
            meetingId: item.filename,
            meetingTitle: meetingTitle(for: item.filename, meetingDirs: meetingDirs),
            timestamp: nil,
            quote: item.text,
            date: item.meetingDate,
            datetime: item.meetingDateTime,
            kind: "open_question",
            person: nil
        )
    }
    hydrateReceiptTitles(&receipts, meetingDirs: meetingDirs)
    let result = CrossMeetingToolResult(
        query: project,
        range: range.label,
        count: receipts.count,
        truncated: filtered.count > count,
        results: receipts
    )
    return try encodedToolResult(result)
}

func handleSearchMeetings(params: CallTool.Parameters, index: TranscriptIndex, meetingDirs: [URL]) throws -> CallTool.Result {
    guard let query = params.arguments?["query"]?.stringValue, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return textResult("Missing required parameter: query", isError: true)
    }

    let range = parseToolRange(params.arguments?["range"]?.stringValue)
    let count = cappedCrossMeetingCount(params.arguments?["count"]?.intValue)
    var groups = try index.searchUtterances(
        query: query,
        speaker: nil,
        dateFrom: range.dateFrom,
        dateTo: range.dateTo,
        maxMeetings: count,
        snippetsPerMeeting: 3
    )
    hydrateMeetingSearchTitles(in: &groups, meetingDirs: meetingDirs)

    let receipts = groups.results.flatMap { group in
        group.snippets.map { snippet in
            CrossMeetingReceipt(
                meetingId: group.filename,
                meetingTitle: group.meetingTitle,
                timestamp: snippet.timestamp,
                quote: snippet.text,
                date: group.meetingDate,
                datetime: group.meetingDateTime,
                kind: "utterance",
                person: snippet.speaker
            )
        }
    }
    let result = CrossMeetingToolResult(
        query: query,
        range: range.label,
        count: min(receipts.count, count),
        truncated: groups.truncated || receipts.count > count,
        results: Array(receipts.prefix(count))
    )
    return try encodedToolResult(result)
}

// MARK: - Output Types

struct RecapEntry: Codable {
    let filename: String
    let title: String
    let date: String
    let datetime: String
    let durationFormatted: String
    let speakers: [String]
    let wordCount: Int
    let preview: String
}

struct RecapResult: Codable {
    let dateRange: String
    let meetingCount: Int
    let meetings: [RecapEntry]
}

// MARK: - Helpers

private extension PathSecurity {
    static func resolveReadableFile(
        named requestedName: String,
        appendingExtension pathExtension: String? = nil,
        in baseDirectories: [URL]
    ) -> PathResolutionStatus {
        for directory in baseDirectories {
            switch resolveReadableFile(named: requestedName, appendingExtension: pathExtension, in: directory) {
            case .valid(let url):
                return .valid(url)
            case .invalid:
                return .invalid
            case .missing:
                continue
            }
        }

        return .missing
    }
}

private func parseContextKind(_ raw: String?) -> ContextKind {
    guard let raw, let kind = ContextKind(rawValue: raw.lowercased()) else {
        return .all
    }
    return kind
}

/// Frontmatter title for a meeting markdown file, or nil when the file is
/// unreadable or its frontmatter has no title.
private func frontmatterMeetingTitle(for filename: String, meetingDirs: [URL]) -> String? {
    guard case .valid(let mdURL) = PathSecurity.resolveReadableFile(
        named: filename,
        appendingExtension: "md",
        in: meetingDirs
    ),
    let content = try? String(contentsOf: mdURL, encoding: .utf8) else {
        return nil
    }
    return extractTitle(from: content)
}

private func meetingTitle(for filename: String, meetingDirs: [URL]) -> String {
    frontmatterMeetingTitle(for: filename, meetingDirs: meetingDirs) ?? filename
}

/// Replace the index's filename-derived meeting titles with real frontmatter
/// titles. Groups whose markdown has no frontmatter title keep the
/// filename-derived title they already carry.
func hydrateMeetingSearchTitles(in results: inout GroupedSearchResult, meetingDirs: [URL]) {
    for index in results.results.indices {
        if let title = frontmatterMeetingTitle(for: results.results[index].filename, meetingDirs: meetingDirs) {
            results.results[index].meetingTitle = title
        }
    }
}

private func hydrateMeetingTitles<T>(
    in collection: inout [T],
    kind: KeyPath<T, ContextKind>,
    filename: KeyPath<T, String>,
    title: WritableKeyPath<T, String>,
    meetingDirs: [URL]
) {
    for index in collection.indices where collection[index][keyPath: kind] == .meeting {
        collection[index][keyPath: title] = meetingTitle(for: collection[index][keyPath: filename], meetingDirs: meetingDirs)
    }
}

private func hydrateReceiptTitles(_ receipts: inout [CrossMeetingReceipt], meetingDirs: [URL]) {
    for index in receipts.indices {
        receipts[index].meetingTitle = meetingTitle(for: receipts[index].meetingId, meetingDirs: meetingDirs)
    }
}

private struct ParsedToolRange {
    let dateFrom: String?
    let dateTo: String?
    let label: String?
}

private func parseToolRange(_ raw: String?) -> ParsedToolRange {
    guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
        return ParsedToolRange(dateFrom: nil, dateTo: nil, label: nil)
    }
    let lower = raw.lowercased()
    if lower == "all" || lower == "all time" {
        return ParsedToolRange(dateFrom: nil, dateTo: nil, label: raw)
    }
    if lower == "today" {
        let today = DateFormatter.localYYYYMMDD.string(from: Date())
        return ParsedToolRange(dateFrom: today, dateTo: today, label: today)
    }

    let separators = ["..", " to ", " - "]
    for separator in separators where raw.contains(separator) {
        let parts = raw.components(separatedBy: separator).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if parts.count == 2 {
            let from = parts[0].isEmpty ? nil : parts[0]
            let to = parts[1].isEmpty ? nil : parts[1]
            return ParsedToolRange(dateFrom: from, dateTo: to, label: raw)
        }
    }

    return ParsedToolRange(dateFrom: raw, dateTo: raw, label: raw)
}

private func cappedCrossMeetingCount(_ raw: Int?) -> Int {
    max(1, min(raw ?? 20, 100))
}

private func filterSummaryItems(_ items: [TranscriptIndex.IndexedSummaryItem], matching query: String?) -> [TranscriptIndex.IndexedSummaryItem] {
    guard let query = query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
        return items
    }
    let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    guard !terms.isEmpty else { return items }
    return items.filter { item in
        let haystack = item.text.lowercased()
        return terms.allSatisfy { haystack.contains($0) }
    }
}

private func encodedToolResult<T: Encodable>(_ result: T) throws -> CallTool.Result {
    let json = try JSONEncoder.pretty.encode(result)
    return textResult(String(data: json, encoding: .utf8) ?? "{}")
}

private func formatDuration(_ seconds: Int) -> String {
    let h = seconds / 3600
    let m = (seconds % 3600) / 60
    if h > 0 { return "\(h)h \(m)m" }
    return "\(m)m"
}

private func latestMeetingDate(in results: [MeetingSummary]) -> Date? {
    results.compactMap { parseCaptureDate($0.datetime) }.max()
}

private func latestDictationDayDate(in results: [DictationDaySummary]) -> Date? {
    results.compactMap { parseCaptureDate($0.datetime) }.max()
}

private func latestMeetingSearchDate(in results: GroupedSearchResult) -> Date? {
    results.results.compactMap { parseCaptureDate($0.meetingDateTime) }.max()
}

private func latestContextSearchDate(in results: [ContextSearchGroup]) -> Date? {
    results.compactMap { parseCaptureDate($0.datetime) }.max()
}

private func latestRecentContextDate(in results: [RecentContextItem]) -> Date? {
    results.compactMap { parseCaptureDate($0.datetime) }.max()
}

private func latestRecapDate(in results: [RecapEntry]) -> Date? {
    results.compactMap { parseCaptureDate($0.datetime) }.max()
}

private func artifactKind(for kinds: [ContextKind]) -> String {
    let set = Set(kinds)
    if set.contains(.meeting), set.contains(.dictation) {
        return "mixed"
    }
    if set.contains(.meeting) {
        return "meeting"
    }
    if set.contains(.dictation) {
        return "dictation"
    }
    return "mixed"
}

private func captureDateFromMeetingMarkdown(_ content: String) -> Date? {
    guard let parsed = CaptureMarkdownParser.parseMeeting(from: content) else { return nil }
    return parseCaptureDate(parsed.datetime)
}

extension JSONEncoder {
    static let pretty: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}

extension Value {
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var intValue: Int? {
        if case .int(let i) = self { return i }
        if case .double(let n) = self { return Int(n) }
        return nil
    }
}
