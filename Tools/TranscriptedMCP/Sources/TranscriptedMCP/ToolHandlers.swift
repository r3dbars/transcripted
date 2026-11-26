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
                name: "read_dictation",
                description: "Read a saved dictation day, one specific entry by ID, or a bounded window of entries. Use list_dictations, recent_context, or search first to find the filename or entry_id you need. Prefer entry_id for a single entry. Without entry_id, pass offset/limit to page through entries; day files over ~30k characters are automatically truncated to a window with total_entries, next_offset, and a continuation hint.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "filename": .object([
                            "type": .string("string"),
                            "description": .string("Dictation day filename (e.g. 'Dictations_2026-04-07')")
                        ]),
                        "entry_id": .object([
                            "type": .string("string"),
                            "description": .string("Optional entry ID from recent_context or search to return one dictation entry")
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
                description: "Read a saved writing day, one specific entry by ID, or a bounded window of entries. Use list_writing, recent_context, or search first to find the filename or entry_id. Prefer entry_id for a single entry. Without entry_id, pass offset/limit to page through entries; day files over ~30k characters are automatically truncated to a window with total_entries, next_offset, and a continuation hint.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "filename": .object([
                            "type": .string("string"),
                            "description": .string("Writing day filename (e.g. 'Writing_2026-09-25')")
                        ]),
                        "entry_id": .object([
                            "type": .string("string"),
                            "description": .string("Optional entry ID from recent_context or search to return one writing entry")
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
                name: "search",
                description: "Search across saved meetings, dictations, and writing (or filter to a single capture type with kind). Defaults to hybrid search (full-text + on-device semantic) so paraphrases match, not just exact wording; writing is matched by full text. Results are ranked by relevance across kinds, not by date; use recent_context for newest first. Optionally filter by speaker name (meetings only; supports variants like Mike -> Michael), kind, count, or date range.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object([
                            "type": .string("string"),
                            "description": .string("Search query (e.g. 'product roadmap discussion')")
                        ]),
                        "kind": .object([
                            "type": .string("string"),
                            "description": .string("Capture type to search: 'all' (default), 'meeting', 'dictation', or 'writing'")
                        ]),
                        "mode": .object([
                            "type": .string("string"),
                            "description": .string("Search strategy: 'hybrid' (default — FTS + semantic), 'lexical' (exact/stemmed only), or 'semantic' (paraphrase only). Falls back to lexical when the on-device embedding model is unavailable.")
                        ]),
                        "speaker": .object([
                            "type": .string("string"),
                            "description": .string("Optional speaker filter for meeting results (supports variants: Mike finds Michael)")
                        ]),
                        "count": .object([
                            "type": .string("integer"),
                            "description": .string("Maximum number of matching items to return (default: 10, max: 50)")
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
                name: "status",
                description: "Server status and configuration: version, resolved capture directories, which resolution rule selected them, index location, and indexed counts. Call this when other tools return empty results to see whether anything is indexed at all.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([:]),
                ]),
                annotations: .init(readOnlyHint: true)
            ),
        ])
    }
    await server.withMethodHandler(CallTool.self) { params in
        do {
            return try withAgentCaptureQueryTelemetry(params: params) {
                switch params.name {
                case "list_meetings":
                    return try handleListMeetings(params: params, index: index, meetingDirs: directories.meetingDirs)
                case "read_meeting":
                    return try handleReadMeeting(params: params, meetingDirs: directories.meetingDirs)
                case "list_dictations":
                    return try handleListDictations(params: params, index: index, dictationDirs: directories.dictationDirs)
                case "read_dictation":
                    return try handleReadDictation(params: params, dictationDirs: directories.dictationDirs)
                case "list_writing":
                    return try handleListWriting(params: params, index: index, writingDirs: directories.writingDirs)
                case "read_writing":
                    return try handleReadWriting(params: params, writingDirs: directories.writingDirs)
                case "search", "search_context":
                    return try handleSearch(
                        params: params,
                        index: index,
                        meetingDirs: directories.meetingDirs,
                        dictationDirs: directories.dictationDirs,
                        writingDirs: directories.writingDirs
                    )
                case "recent_context":
                    return try handleRecentContext(
                        params: params,
                        index: index,
                        meetingDirs: directories.meetingDirs,
                        dictationDirs: directories.dictationDirs,
                        writingDirs: directories.writingDirs
                    )
                case "who_is":
                    return try handleWhoIs(params: params, index: index)
                case "status":
                    return try handleStatus(index: index, directories: directories)
                default:
                    return textResult("Unknown tool: \(params.name)", isError: true)
                }
            }
        } catch {
            return textResult("Error: \(error.localizedDescription)", isError: true)
        }
    }
}

// MARK: - status

func handleStatus(index: TranscriptIndex, directories: TranscriptedDataDirectories) throws -> CallTool.Result {
    let counts = try index.counts()
    let result = StatusResult(
        serverVersion: TranscriptedMCP.serverVersion,
        meetingDirectories: directories.meetingDirs.map(\.path),
        dictationDirectories: directories.dictationDirs.map(\.path),
        writingDirectories: directories.writingDirs.map(\.path),
        resolutionSource: directories.resolutionSource.rawValue,
        legacyFallbackAppended: directories.legacyFallbackAppended,
        indexDirectory: directories.indexDir.path,
        indexedMeetings: counts.meetings,
        indexedDictationDays: counts.dictationDays,
        indexedDictationEntries: counts.dictationEntries,
        indexedWritingDays: counts.writingDays,
        indexedWritingEntries: counts.writingEntries
    )

    let json = try JSONEncoder.pretty.encode(result)
    return textResult(String(data: json, encoding: .utf8) ?? "{}")
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
