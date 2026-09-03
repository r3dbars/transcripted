import Foundation
import MCP
import TranscriptedCaptureKit

// MARK: - Shared Helpers
//
// Small utilities used across the tool-family files in this directory
// (ToolHandlers+Meetings.swift, +Dictations.swift, +Search.swift,
// +Rollups.swift, +Receipts.swift). Kept internal (not `private`) because
// `private` is file-scoped in Swift and these are shared across files.

extension DateFormatter {
    /// YYYY-MM-DD formatter in the local timezone, matching how transcript dates are stored.
    static let localYYYYMMDD: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        // Intentionally uses the system (local) timezone — transcript dates are stored in local time.
        return f
    }()
}

func textResult(_ text: String, isError: Bool = false) -> CallTool.Result {
    .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: isError)
}

func invalidAgentCaptureQueryInputResult(_ text: String) -> CallTool.Result {
    markAgentCaptureQueryTerminal(.invalidInput)
    return textResult(text, isError: true)
}

func emptyOrMissingAgentCaptureQueryResult(
    _ text: String,
    isError: Bool = false
) -> CallTool.Result {
    markAgentCaptureQueryTerminal(.emptyNotFound, sourceCount: 0, resultCount: 0)
    return textResult(text, isError: isError)
}

/// Character budget for read_meeting / read_dictation raw markdown responses.
/// Anything larger switches to a paginated window even when the caller did not
/// pass offset/limit, so one 90-minute transcript cannot blow out an agent's
/// context window. ~30k characters is roughly 7-8k tokens — big enough that
/// typical meetings and dictation days pass through byte-identical, small
/// enough that a runaway dump stays readable.
let maxUnpaginatedReadCharacters = 30_000

/// Rough per-item JSON encoding overhead (keys, timestamps, speaker names)
/// used when auto-sizing a pagination window against the character budget.
let paginationItemOverheadCharacters = 80

/// Index one past the last item that fits the character budget starting at
/// `start`. Always advances by at least one item when any remain, so an
/// oversized single item still makes progress.
func autoWindowEnd<T>(items: [T], start: Int, cost: (T) -> Int) -> Int {
    var end = start
    var used = 0
    while end < items.count {
        used += cost(items[end])
        if used > maxUnpaginatedReadCharacters, end > start { break }
        end += 1
    }
    return end
}

/// Which artifact population a tool reads; drives which indexed counts and
/// hint an empty response carries.
enum EmptyResultScope {
    case meetings
    case dictations
    case mixed
    case summaries
}

/// Self-describing zero-result response: where the server looked, what is
/// indexed, and what to try next — so agents can tell an unindexed library
/// apart from a query that matched nothing.
func emptyResult(scope: EmptyResultScope, searchedDirectories: [URL], index: TranscriptIndex) throws -> CallTool.Result {
    let counts = try index.counts()
    let directories = uniquePaths(searchedDirectories)

    let payload: EmptyQueryResult
    switch scope {
    case .meetings:
        payload = EmptyQueryResult(
            searchedDirectories: directories,
            indexedMeetings: counts.meetings,
            indexedDictationDays: nil,
            indexedDictationEntries: nil,
            indexedSummaryItems: nil,
            hint: counts.meetings == 0
                ? "No meetings are indexed — check that the directories above contain capture Markdown, or call the status tool."
                : "No meetings matched these filters — try widening the date range or changing the query."
        )
    case .dictations:
        payload = EmptyQueryResult(
            searchedDirectories: directories,
            indexedMeetings: nil,
            indexedDictationDays: counts.dictationDays,
            indexedDictationEntries: counts.dictationEntries,
            indexedSummaryItems: nil,
            hint: counts.dictationDays == 0
                ? "No dictations are indexed — check that the directories above contain capture Markdown, or call the status tool."
                : "No dictations matched these filters — try widening the date range or changing the query."
        )
    case .mixed:
        payload = EmptyQueryResult(
            searchedDirectories: directories,
            indexedMeetings: counts.meetings,
            indexedDictationDays: counts.dictationDays,
            indexedDictationEntries: nil,
            indexedSummaryItems: nil,
            hint: counts.meetings == 0 && counts.dictationDays == 0
                ? "Nothing is indexed — check that the directories above contain capture Markdown, or call the status tool."
                : "No items matched these filters — try widening the date range or changing the query."
        )
    case .summaries:
        payload = EmptyQueryResult(
            searchedDirectories: directories,
            indexedMeetings: counts.meetings,
            indexedDictationDays: nil,
            indexedDictationEntries: nil,
            indexedSummaryItems: counts.summaryItems,
            hint: counts.summaryItems == 0
                ? "No structured summaries are indexed. Rollups only cover meetings with saved summary fields."
                : "No summary items matched these filters — try widening the date range or removing filters."
        )
    }

    let json = try JSONEncoder.pretty.encode(payload)
    markAgentCaptureQueryTerminal(.emptyNotFound, sourceCount: 0, resultCount: 0)
    return textResult(String(data: json, encoding: .utf8) ?? "{}")
}

func uniquePaths(_ directories: [URL]) -> [String] {
    var seen: Set<String> = []
    var paths: [String] = []
    for url in directories {
        guard seen.insert(url.standardizedFileURL.path).inserted else { continue }
        paths.append(url.path)
    }
    return paths
}

/// Resolve a readable file across multiple candidate base directories,
/// returning the first directory that has it (or `.invalid`/`.missing` per
/// PathSecurity's single-directory rules). Shared across the Meetings,
/// Dictations, and Rollups handler files, all of which look up a filename in
/// a list of meeting/dictation directories — so this extension lives here
/// rather than `private` in any one of them.
extension PathSecurity {
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

private struct AgentCaptureQueryDescriptor {
    let toolKind: String
    let captureKind: String

    init?(params: CallTool.Parameters) {
        switch params.name {
        case "list_meetings":
            self.init(toolKind: "list", captureKind: "meeting")
        case "list_dictations":
            self.init(toolKind: "list", captureKind: "dictation")
        case "read_meeting":
            self.init(toolKind: "read", captureKind: "meeting")
        case "read_dictation":
            self.init(toolKind: "read", captureKind: "dictation")
        case "search":
            self.init(toolKind: "search", captureKind: "meeting")
        case "search_context":
            self.init(toolKind: "search", captureKind: Self.requestedCaptureKind(params))
        case "recent_context":
            self.init(toolKind: "recent", captureKind: Self.requestedCaptureKind(params))
        case "who_is":
            self.init(toolKind: "speaker_lookup", captureKind: "meeting")
        case "recap":
            self.init(toolKind: "recap", captureKind: "meeting")
        case "list_action_items":
            self.init(toolKind: "action_items", captureKind: "meeting")
        case "list_decisions", "decisions":
            self.init(toolKind: "decisions", captureKind: "meeting")
        case "digest":
            self.init(toolKind: "digest", captureKind: "meeting")
        case "commitments":
            self.init(toolKind: "commitments", captureKind: "meeting")
        case "open_questions":
            self.init(toolKind: "open_questions", captureKind: "meeting")
        case "search_meetings":
            self.init(toolKind: "search", captureKind: "meeting")
        default:
            return nil
        }
    }

    private init(toolKind: String, captureKind: String) {
        self.toolKind = toolKind
        self.captureKind = captureKind
    }

    private static func requestedCaptureKind(_ params: CallTool.Parameters) -> String {
        switch params.arguments?["kind"]?.stringValue?.lowercased() {
        case "meeting":
            return "meeting"
        case "dictation":
            return "dictation"
        default:
            return "mixed"
        }
    }
}

func withAgentCaptureQueryTelemetry(
    params: CallTool.Parameters,
    clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    buildIdentity: AgentCaptureQueryBuildIdentity? = nil,
    operation: () throws -> CallTool.Result
) rethrows -> CallTool.Result {
    guard let descriptor = AgentCaptureQueryDescriptor(params: params) else {
        return try operation()
    }

    let resolvedBuildIdentity = buildIdentity ?? .resolve()
    let invocation = AgentCaptureQueryInvocation(
        toolKind: descriptor.toolKind,
        captureKind: descriptor.captureKind
    )
    let startedAt = clock()

    func emitTerminalObservation() {
        let elapsed = max(0, clock() - startedAt)
        let latencyMilliseconds = Int((elapsed * 1_000).rounded())
        AgentCaptureQueryTelemetryRuntime.recorder.track(
            AgentCaptureQueryObservation(
                toolKind: invocation.toolKind,
                captureKind: invocation.captureKind,
                result: invocation.result,
                sourceCount: invocation.sourceCount,
                resultCount: invocation.resultCount,
                latencyMilliseconds: latencyMilliseconds,
                buildIdentity: resolvedBuildIdentity
            )
        )
    }

    return try AgentCaptureQueryTelemetryRuntime.$invocation.withValue(invocation) {
        do {
            let result = try operation()
            if result.isError == true, invocation.result == .success {
                invocation.recordTerminal(.internalError)
            }
            emitTerminalObservation()
            return result
        } catch {
            invocation.recordTerminal(.internalError)
            emitTerminalObservation()
            throw error
        }
    }
}

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
                name: "search_context",
                description: "Search across saved meetings, dictations, or both. Defaults to hybrid (full-text + on-device semantic), so paraphrases match, not just exact wording. Great for finding everything you captured about a topic, regardless of whether it came from a meeting or a quick dictated note.",
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
                description: "Render an interactive card list of the most recent meetings — each with audio playback and a raw-transcript view — as an MCP Apps (SEP-1865) UI widget that draws inline in rendering-capable clients. Clients that don't paint inline UI get a plain-text meeting list as a fallback. All audio and transcripts are local; nothing leaves this Mac.",
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
        ])
    }

    await server.withMethodHandler(CallTool.self) { params in
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
                case "search":
                    return try handleSearch(params: params, index: index, meetingDirs: directories.meetingDirs)
                case "search_context":
                    return try handleSearchContext(params: params, index: index, meetingDirs: directories.meetingDirs, dictationDirs: directories.dictationDirs)
                case "recent_context":
                    return try handleRecentContext(params: params, index: index, meetingDirs: directories.meetingDirs, dictationDirs: directories.dictationDirs)
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
