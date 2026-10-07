import Foundation
import MCP
import TranscriptedCaptureKit

// MARK: - Tool Registration & Dispatch
//
// The MCP tool surface (schemas + call dispatch). Individual tool
// implementations live in the ToolHandlers+*.swift files alongside this one;
// this file only wires the tool names/schemas to their handler functions.

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
                description: "Read a meeting transcript by filename (from list_meetings). Long meetings are token-heavy: pass offset/limit to page through utterances, or section 'speakers' for metadata and analytics without dialogue. Full or transcript responses over ~30k characters are automatically truncated to a bounded window with total_utterances, next_offset, and a continuation hint.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "filename": .object([
                            "type": .string("string"),
                            "description": .string("Meeting filename from list_meetings (e.g. 'Call_2026-03-26_16-04-11')")
                        ]),
                        "section": .object([
                            "type": .string("string"),
                            "description": .string("Which section to return: 'full' (default — complete transcript), 'transcript' (dialogue only), or 'speakers' (frontmatter + analytics, cheapest for long meetings)")
                        ]),
                        "offset": .object([
                            "type": .string("integer"),
                            "description": .string("0-based utterance index to start the transcript window at (default: 0). Applies to sections 'full' and 'transcript'.")
                        ]),
                        "limit": .object([
                            "type": .string("integer"),
                            "description": .string("Maximum utterances to return. Setting this (or exceeding the size guard) switches the response to a paginated JSON window with total_utterances, next_offset, and a hint.")
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
                description: "Search meeting transcripts. Defaults to hybrid search: exact full-text matches PLUS on-device semantic matches, so paraphrases hit (e.g. 'pricing pushback' finds 'they balked at the cost'). Returns matching utterances with speaker, timestamp, and meeting context. Optionally filter by speaker name (supports variants: Mike finds Michael) or date range.",
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
                        "mode": .object([
                            "type": .string("string"),
                            "description": .string("Search strategy: 'hybrid' (default — FTS + semantic), 'lexical' (exact/stemmed only), or 'semantic' (paraphrase only). Semantic and hybrid fall back to lexical when the on-device embedding model is unavailable.")
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
                description: "Read a saved dictation day, one specific entry by ID, or a bounded window of entries. Use list_dictations or recent_context first to find the filename or entry_id you need. Prefer entry_id for a single entry. Without entry_id, pass offset/limit to page through entries; day files over ~30k characters are automatically truncated to a window with total_entries, next_offset, and a continuation hint.",
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
                        "offset": .object([
                            "type": .string("integer"),
                            "description": .string("0-based entry index to start the window at (default: 0). Ignored when entry_id is set.")
                        ]),
                        "limit": .object([
                            "type": .string("integer"),
                            "description": .string("Maximum entries to return. Setting this (or exceeding the size guard) switches the response to a paginated JSON window with total_entries, next_offset, and a hint. Ignored when entry_id is set.")
                        ]),
                    ]),
                    "required": .array([.string("filename")]),
                ]),
                annotations: .init(readOnlyHint: true)
            ),
            Tool(
                name: "list_writing",
                description: "List saved writing days: what the user wrote with the Transcripted keyboard, one Writing_<date> file per day, with entry counts, source apps, and recent titles. Use read_writing with a returned filename for the text.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "count": .object([
                            "type": .string("integer"),
                            "description": .string("Number of writing days to return (default: 10, max: 50)")
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
                name: "read_writing",
                description: "Read a saved writing day, one specific entry by ID, or a bounded window of entries. Use list_writing, recent_context, or search_context first to find the filename or entry_id. Prefer entry_id for a single entry. Without entry_id, pass offset/limit to page through entries; day files over ~30k characters are automatically truncated to a window with total_entries, next_offset, and a continuation hint.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "filename": .object([
                            "type": .string("string"),
                            "description": .string("Writing day filename (e.g. 'Writing_2026-09-25')")
                        ]),
                        "entry_id": .object([
                            "type": .string("string"),
                            "description": .string("Optional entry ID from recent_context or search_context to return one writing entry")
                        ]),
                        "offset": .object([
                            "type": .string("integer"),
                            "description": .string("0-based entry index to start the window at (default: 0). Ignored when entry_id is set.")
                        ]),
                        "limit": .object([
                            "type": .string("integer"),
                            "description": .string("Maximum entries to return. Setting this (or exceeding the size guard) switches the response to a paginated JSON window with total_entries, next_offset, and a hint. Ignored when entry_id is set.")
                        ]),
                    ]),
                    "required": .array([.string("filename")]),
                ]),
                annotations: .init(readOnlyHint: true)
            ),
            Tool(
                name: "search_context",
                description: "Search across saved meetings, dictations, writing, or all of them. Defaults to hybrid (full-text + on-device semantic), so paraphrases match, not just exact wording; writing is matched by full text only. Great for finding everything you captured about a topic, whether it came from a meeting, a quick dictated note, or something you wrote.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object([
                            "type": .string("string"),
                            "description": .string("Search query")
                        ]),
                        "kind": .object([
                            "type": .string("string"),
                            "description": .string("Which context to search: 'all' (default), 'meeting', 'dictation', or 'writing'")
                        ]),
                        "mode": .object([
                            "type": .string("string"),
                            "description": .string("Search strategy: 'hybrid' (default — FTS + semantic), 'lexical', or 'semantic'. Falls back to lexical when the embedding model is unavailable.")
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
                description: "List the most recent saved meetings, dictations, and writing together in one feed. Great for quickly orienting an agent before it starts summarizing or planning.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "kind": .object([
                            "type": .string("string"),
                            "description": .string("Which context to list: 'all' (default), 'meeting', 'dictation', or 'writing'")
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
                description: "Roll up action items across every meeting. Filter by owner (supports name variants: Nate finds Nate Smith), by status ('open' by default, 'done', or 'all'), by a free-text query, or by date range. Use this for 'every open action item assigned to me' or 'what did we commit to last week'. Depends on the meeting summary index.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "owner": .object([
                            "type": .string("string"),
                            "description": .string("Filter to action items assigned to this person (e.g. 'Nate')")
                        ]),
                        "status": .object([
                            "type": .string("string"),
                            "description": .string("Which items to return: 'open' (default), 'done', or 'all'.")
                        ]),
                        "query": .object([
                            "type": .string("string"),
                            "description": .string("Optional full-text filter on the action item text, owner, status, or due metadata")
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
            Tool(
                name: "status",
                description: "Server status and configuration: version, resolved capture directories, which resolution rule selected them, index location, and indexed counts. Call this when other tools return empty results to see whether anything is indexed at all.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([:]),
                ]),
                annotations: .init(readOnlyHint: true)
            ),
            Tool(
                name: "show_recent_meetings",
                description: "Render recent meetings with raw transcript text and size-capped recorded audio as an MCP Apps widget. Transcript and audio bytes are returned to the connected host. Clients without inline UI receive a text list. Unavailable in companion mode, which exports text only.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "count": .object([
                            "type": .string("integer"),
                            "description": .string("Number of recent meetings to show (default: 5, max: 15)")
                        ]),
                    ]),
                ]),
                annotations: .init(readOnlyHint: true),
                _meta: TranscriptedUIResources.toolMeta
            ),
        ].filter { !CompanionTools.companionMode || $0.name != "show_recent_meetings" } + CompanionTools.tools)
    }
    await server.withMethodHandler(CallTool.self) { params in
        if let reply = await CompanionTools.intercept(params, index: index, directories: directories) { return reply }
        do {
            return try withAgentCaptureQueryTelemetry(params: params) {
                switch params.name {
                case "list_meetings":
                    return try handleListMeetings(params: params, index: index, meetingDirs: directories.meetingDirs)
                case "list_dictations":
                    return try handleListDictations(params: params, index: index, dictationDirs: directories.dictationDirs)
                case "read_meeting":
                    return try handleReadMeeting(params: params, meetingDirs: directories.meetingDirs)
                case "read_dictation":
                    return try handleReadDictation(params: params, dictationDirs: directories.dictationDirs)
                case "list_writing":
                    return try handleListWriting(params: params, index: index, writingDirs: directories.writingDirs)
                case "read_writing":
                    return try handleReadWriting(params: params, writingDirs: directories.writingDirs)
                case "search":
                    return try handleSearch(params: params, index: index, meetingDirs: directories.meetingDirs)
                case "search_context":
                    return try handleSearchContext(params: params, index: index, meetingDirs: directories.meetingDirs, dictationDirs: directories.dictationDirs, writingDirs: directories.writingDirs)
                case "recent_context":
                    return try handleRecentContext(params: params, index: index, meetingDirs: directories.meetingDirs, dictationDirs: directories.dictationDirs, writingDirs: directories.writingDirs)
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
                case "status":
                    return try handleStatus(index: index, directories: directories)
                case "show_recent_meetings":
                    let count = min(max(params.arguments?["count"]?.intValue ?? TranscriptedUIResources.defaultRecentCount, 1), 15)
                    return try TranscriptedUIResources.showRecentMeetingsResult(
                        count: count, index: index, directories: directories, serverVersion: TranscriptedMCP.serverVersion
                    )
                default:
                    return textResult("Unknown tool: \(params.name)", isError: true)
                }
            }
        } catch {
            return textResult("Error: \(error.localizedDescription)", isError: true)
        }
    }
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
        // `Int(someDouble)` traps on anything outside Int's range, and every
        // count/offset/limit argument reaches this before its clamp runs — so
        // a legal-JSON `{"count": 1e30}` would abort the server rather than
        // fail the request. Truncate toward zero (preserving the old
        // behavior for ordinary fractions) and let out-of-range read as nil,
        // which every call site already handles with `?? default`.
        if case .double(let n) = self { return Int(exactly: n.rounded(.towardZero)) }
        return nil
    }
}
