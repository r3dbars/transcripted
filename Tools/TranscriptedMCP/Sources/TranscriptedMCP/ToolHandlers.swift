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

/// Character budget for read_meeting / read_dictation raw markdown responses.
/// Anything larger switches to a paginated window even when the caller did not
/// pass offset/limit, so one 90-minute transcript cannot blow out an agent's
/// context window. ~30k characters is roughly 7-8k tokens — big enough that
/// typical meetings and dictation days pass through byte-identical, small
/// enough that a runaway dump stays readable.
let maxUnpaginatedReadCharacters = 30_000

/// Rough per-item JSON encoding overhead (keys, timestamps, speaker names)
/// used when auto-sizing a pagination window against the character budget.
private let paginationItemOverheadCharacters = 80

/// Index one past the last item that fits the character budget starting at
/// `start`. Always advances by at least one item when any remain, so an
/// oversized single item still makes progress.
private func autoWindowEnd<T>(items: [T], start: Int, cost: (T) -> Int) -> Int {
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
private enum EmptyResultScope {
    case meetings
    case dictations
    case mixed
    case summaries
}

/// Self-describing zero-result response: where the server looked, what is
/// indexed, and what to try next — so agents can tell an unindexed library
/// apart from a query that matched nothing.
private func emptyResult(scope: EmptyResultScope, searchedDirectories: [URL], index: TranscriptIndex) throws -> CallTool.Result {
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
                ? "No structured summaries are indexed. Rollups only cover meetings with a saved summary (Settings → Meetings → local summaries)."
                : "No summary items matched these filters — try widening the date range or removing filters."
        )
    }

    let json = try JSONEncoder.pretty.encode(payload)
    return textResult(String(data: json, encoding: .utf8) ?? "{}")
}

private func uniquePaths(_ directories: [URL]) -> [String] {
    var seen: Set<String> = []
    var paths: [String] = []
    for url in directories {
        guard seen.insert(url.standardizedFileURL.path).inserted else { continue }
        paths.append(url.path)
    }
    return paths
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
                name: "semantic_search",
                description: "Meaning-based search across meetings and dictations using an on-device sentence embedding — finds paraphrases lexical search misses ('pricing pushback' finds 'they balked at the cost'). Use when `search`/`search_context` come up empty or the query is conceptual rather than exact words. English-optimized. Results carry a cosine similarity score; treat low scores (< ~0.4) as weak matches.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object([
                            "type": .string("string"),
                            "description": .string("What you're looking for, phrased naturally (e.g. 'concerns about pricing')")
                        ]),
                        "kind": .object([
                            "type": .string("string"),
                            "description": .string("Which context to search: 'all' (default), 'meeting', or 'dictation'")
                        ]),
                        "count": .object([
                            "type": .string("integer"),
                            "description": .string("Max results (default 10, max 50)")
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
                description: "Roll up action items across every meeting. Filter by owner (supports name variants: Nate finds Nate Smith), by status ('open' by default, or 'all'), by a free-text query, or by date range. Use this for 'every open action item assigned to me' or 'what did we commit to last week'. Items carry status/due metadata from trailing markers on the bullet in the saved meeting Markdown — '(done)', '(status: done)', '(due: Friday)' — so marked-done items drop out of 'open' results; unmarked items are open. Depends on the meeting summary index.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "owner": .object([
                            "type": .string("string"),
                            "description": .string("Filter to action items assigned to this person (e.g. 'Nate')")
                        ]),
                        "status": .object([
                            "type": .string("string"),
                            "description": .string("Which items to return: 'open' (default) or 'all'. 'done' is not enabled yet; marked-done items already drop out of 'open' results.")
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
            case "semantic_search":
                return try handleSemanticSearch(params: params, index: index, meetingDirs: directories.meetingDirs)
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
            case "status":
                return try handleStatus(index: index, directories: directories)
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
        return try emptyResult(scope: .meetings, searchedDirectories: meetingDirs, index: index)
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

func handleListDictations(params: CallTool.Parameters, index: TranscriptIndex, dictationDirs: [URL]) throws -> CallTool.Result {
    let count = params.arguments?["count"]?.intValue ?? 10
    let date = params.arguments?["date"]?.stringValue
    let dateFrom = params.arguments?["date_from"]?.stringValue ?? date
    let dateTo = params.arguments?["date_to"]?.stringValue ?? date

    let results = try index.listDictationDays(count: count, dateFrom: dateFrom, dateTo: dateTo)

    if results.isEmpty {
        return try emptyResult(scope: .dictations, searchedDirectories: dictationDirs, index: index)
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

/// Structured summary preview for a meeting: prose summary bullets plus
/// compact Decisions / Action items / Open questions lines. Returns nil when
/// the transcript carries no summary at all, so callers can fall back to raw
/// dialogue. This exists because the opening dialogue lines of a real meeting
/// are greetings and audio checks — the least informative content in the file —
/// while the summary sitting in the same Markdown answers "what was this
/// meeting" directly.
func meetingSummaryPreview(from content: String) -> String? {
    var sections: [String] = []

    if let document = CaptureMarkdownParser.parseFrontmatter(from: content) {
        let prose = document.values["local_summary"] ?? document.values["auto_summary"]
        let bullets = (prose ?? "")
            .components(separatedBy: " | ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "None found." }
        if !bullets.isEmpty {
            sections.append(bullets.prefix(3).map { "- \($0)" }.joined(separator: "\n"))
        }
    }

    if let summary = CaptureSummaryParser.parse(from: content) {
        if !summary.decisions.isEmpty {
            sections.append("Decisions: " + summary.decisions.prefix(3).joined(separator: " | "))
        }
        if !summary.actionItems.isEmpty {
            let items = summary.actionItems.prefix(3).map { item -> String in
                item.owner.map { "\($0): \(item.text)" } ?? item.text
            }
            sections.append("Action items: " + items.joined(separator: " | "))
        }
        if !summary.openQuestions.isEmpty {
            sections.append("Open questions: " + summary.openQuestions.prefix(2).joined(separator: " | "))
        }
    }

    guard !sections.isEmpty else { return nil }
    return sections.joined(separator: "\n")
}

// MARK: - read_meeting

func handleReadMeeting(params: CallTool.Parameters, meetingDirs: [URL]) throws -> CallTool.Result {
    guard let filename = params.arguments?["filename"]?.stringValue, !filename.isEmpty else {
        return textResult("Missing required parameter: filename", isError: true)
    }

    let section = params.arguments?["section"]?.stringValue ?? "full"
    let offset = max(0, params.arguments?["offset"]?.intValue ?? 0)
    let limit = params.arguments?["limit"]?.intValue
    let paginationRequested = limit != nil || offset > 0

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

    let parsed = CaptureMarkdownParser.parseMeeting(from: content)

    trackAgentCaptureQueryObserved(
        queryKind: "read",
        artifactKind: "meeting",
        captureDate: parsed.flatMap { parseCaptureDate($0.datetime) },
        sourceCount: 1
    )

    switch section {
    case "transcript":
        let dialogue = extractDialogueLines(from: content).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = dialogue.isEmpty ? content : dialogue
        if !paginationRequested, raw.count <= maxUnpaginatedReadCharacters {
            return textResult(raw)
        }
        return try meetingTranscriptPageResult(
            parsed: parsed, content: content, filename: filename,
            offset: offset, limit: limit, includeFrontmatter: false, rawFallback: raw
        )

    case "speakers":
        // Return YAML frontmatter + speaker analytics section
        var result = ""
        if let frontmatter = frontmatterBlock(of: content) {
            result += frontmatter
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
        if !paginationRequested, content.count <= maxUnpaginatedReadCharacters {
            return textResult(content)
        }
        return try meetingTranscriptPageResult(
            parsed: parsed, content: content, filename: filename,
            offset: offset, limit: limit, includeFrontmatter: true, rawFallback: content
        )
    }
}

/// Bounded transcript read: frontmatter metadata plus one utterance window and
/// explicit pagination fields, so a long meeting never comes back as an
/// unbounded dump. Falls back to the raw markdown when the file does not parse
/// as a windowable transcript — we can only page what the parser understands.
private func meetingTranscriptPageResult(
    parsed: ParsedMeetingCapture?,
    content: String,
    filename: String,
    offset: Int,
    limit: Int?,
    includeFrontmatter: Bool,
    rawFallback: String
) throws -> CallTool.Result {
    guard let parsed, !parsed.utterances.isEmpty else {
        return textResult(rawFallback)
    }

    let total = parsed.utterances.count
    let start = min(offset, total)
    let end: Int
    if let limit {
        end = min(start + max(1, limit), total)
    } else {
        end = autoWindowEnd(items: parsed.utterances, start: start) {
            $0.text.count + paginationItemOverheadCharacters
        }
    }

    let speakerNames = Dictionary(uniqueKeysWithValues: parsed.speakers.map { ($0.id, $0.name) })
    let utterances = parsed.utterances[start..<end].map { utterance in
        MeetingTranscriptPageUtterance(
            start: utterance.start,
            end: utterance.end,
            speaker: speakerNames[utterance.speakerId] ?? utterance.speakerId,
            speakerId: utterance.speakerId,
            text: utterance.text
        )
    }

    let returned = utterances.count
    let truncated = start + returned < total
    let nextOffset = truncated ? start + returned : nil

    let hint: String
    if offset >= total {
        hint = "offset \(offset) is past the end — this transcript has \(total) utterances. Retry with a smaller offset."
    } else if let nextOffset {
        hint = "Showing utterances \(start)-\(end - 1) of \(total). Call read_meeting again with offset=\(nextOffset) to continue, or use section \"speakers\" for the overview without dialogue."
    } else {
        hint = "End of transcript — all remaining utterances included."
    }

    let page = MeetingTranscriptPage(
        filename: filename,
        frontmatter: includeFrontmatter ? frontmatterBlock(of: content) : nil,
        totalUtterances: total,
        offset: offset,
        returned: returned,
        truncated: truncated,
        nextOffset: nextOffset,
        hint: hint,
        utterances: utterances
    )

    let json = try JSONEncoder.pretty.encode(page)
    return textResult(String(data: json, encoding: .utf8) ?? "{}")
}

/// Raw YAML frontmatter block, matching the exact slice the speakers section
/// has always returned (both fences plus the character after the closing one).
private func frontmatterBlock(of content: String) -> String? {
    guard content.count >= 8, content.hasPrefix("---"),
          let endRange = content.range(of: "\n---\n", range: content.index(content.startIndex, offsetBy: 3)..<content.endIndex) else {
        return nil
    }
    return String(content[content.startIndex...endRange.upperBound])
}

func handleReadDictation(params: CallTool.Parameters, dictationDirs: [URL]) throws -> CallTool.Result {
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

    let offset = max(0, params.arguments?["offset"]?.intValue ?? 0)
    let limit = params.arguments?["limit"]?.intValue
    let paginationRequested = limit != nil || offset > 0

    guard let content = try? String(contentsOf: markdownURL, encoding: .utf8) else {
        let json = try JSONEncoder.pretty.encode(day)
        return textResult(String(data: json, encoding: .utf8) ?? "{}")
    }

    if !paginationRequested, content.count <= maxUnpaginatedReadCharacters {
        return textResult(content)
    }

    return try dictationDayPageResult(day: day, filename: filename, offset: offset, limit: limit)
}

/// Bounded dictation-day read: day metadata plus one entry window and explicit
/// pagination fields, mirroring the meeting transcript window.
private func dictationDayPageResult(day: AgentDictationDay, filename: String, offset: Int, limit: Int?) throws -> CallTool.Result {
    let total = day.entries.count
    let start = min(offset, total)
    let end: Int
    if let limit {
        end = min(start + max(1, limit), total)
    } else {
        end = autoWindowEnd(items: day.entries, start: start) {
            $0.text.count + $0.title.count + paginationItemOverheadCharacters * 3
        }
    }

    let entries = Array(day.entries[start..<end])
    let returned = entries.count
    let truncated = start + returned < total
    let nextOffset = truncated ? start + returned : nil

    let hint: String
    if total == 0 {
        hint = "This dictation day has no entries."
    } else if offset >= total {
        hint = "offset \(offset) is past the end — this day has \(total) entries. Retry with a smaller offset."
    } else if let nextOffset {
        hint = "Showing entries \(start)-\(end - 1) of \(total). Call read_dictation again with offset=\(nextOffset) to continue, or pass entry_id for one specific entry."
    } else {
        hint = "End of day — all remaining entries included."
    }

    let page = DictationDayPage(
        filename: filename,
        date: day.date,
        totalEntries: total,
        offset: offset,
        returned: returned,
        truncated: truncated,
        nextOffset: nextOffset,
        hint: hint,
        entries: entries
    )

    let json = try JSONEncoder.pretty.encode(page)
    return textResult(String(data: json, encoding: .utf8) ?? "{}")
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
        return try emptyResult(scope: .meetings, searchedDirectories: meetingDirs, index: index)
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

private func handleSemanticSearch(params: CallTool.Parameters, index: TranscriptIndex, meetingDirs: [URL]) throws -> CallTool.Result {
    guard let query = params.arguments?["query"]?.stringValue, !query.isEmpty else {
        return textResult("Missing required parameter: query", isError: true)
    }

    let kind = params.arguments?["kind"]?.stringValue
    let count = params.arguments?["count"]?.intValue ?? 10
    let dateFrom = params.arguments?["date_from"]?.stringValue
    let dateTo = params.arguments?["date_to"]?.stringValue

    guard var hits = try index.semanticSearch(
        query: query,
        kind: kind,
        dateFrom: dateFrom,
        dateTo: dateTo,
        maxResults: count
    ) else {
        return textResult(
            "Semantic search is unavailable on this system (the on-device sentence-embedding model could not be loaded). Use `search` or `search_context` instead."
        )
    }

    if hits.isEmpty {
        return textResult("No semantic matches found for \"\(query)\". Try `search_context` for exact-word matching.")
    }

    for i in hits.indices where hits[i].kind == "meeting" {
        guard case .valid(let mdURL) = PathSecurity.resolveReadableFile(
            named: hits[i].filename,
            appendingExtension: "md",
            in: meetingDirs
        ) else { continue }
        if let content = try? String(contentsOf: mdURL, encoding: .utf8) {
            hits[i].meetingTitle = extractTitle(from: content) ?? hits[i].filename
        }
    }

    trackAgentCaptureQueryObserved(
        queryKind: "search",
        artifactKind: semanticArtifactKind(for: hits),
        captureDate: hits.compactMap { parseCaptureDate($0.date) }.max(),
        sourceCount: hits.count
    )

    let json = try JSONEncoder.pretty.encode(SemanticSearchResult(query: query, count: hits.count, items: hits))
    return textResult(String(data: json, encoding: .utf8) ?? "[]")
}

private func semanticArtifactKind(for hits: [SemanticSearchHit]) -> String {
    let kinds = Set(hits.map(\.kind))
    if kinds.count == 1, let only = kinds.first, only == "meeting" || only == "dictation" {
        return only
    }
    return "mixed"
}

private func handleSearchContext(params: CallTool.Parameters, index: TranscriptIndex, meetingDirs: [URL], dictationDirs: [URL]) throws -> CallTool.Result {
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
        return try emptyResult(scope: .mixed, searchedDirectories: meetingDirs + dictationDirs, index: index)
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

func handleRecentContext(params: CallTool.Parameters, index: TranscriptIndex, meetingDirs: [URL], dictationDirs: [URL]) throws -> CallTool.Result {
    let kind = parseContextKind(params.arguments?["kind"]?.stringValue)
    let count = max(1, min(params.arguments?["count"]?.intValue ?? 10, 50))
    let dateFrom = params.arguments?["date_from"]?.stringValue
    let dateTo = params.arguments?["date_to"]?.stringValue

    var result = try index.listRecentContext(kind: kind, count: count, dateFrom: dateFrom, dateTo: dateTo)
    hydrateMeetingTitles(in: &result.items, kind: \.kind, filename: \.filename, title: \.title, meetingDirs: meetingDirs)

    if result.items.isEmpty {
        return try emptyResult(scope: .mixed, searchedDirectories: meetingDirs + dictationDirs, index: index)
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
        return try emptyResult(scope: .meetings, searchedDirectories: meetingDirs, index: index)
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
            // Prefer the structured summary over opening dialogue — the first
            // lines of a real call are greetings and audio checks.
            preview = meetingSummaryPreview(from: content)
                ?? extractDialogueLines(from: content).prefix(15).joined(separator: "\n")
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

func handleListActionItems(params: CallTool.Parameters, index: TranscriptIndex, meetingDirs: [URL]) throws -> CallTool.Result {
    let owner = params.arguments?["owner"]?.stringValue
    let query = params.arguments?["query"]?.stringValue
    let rawStatus = params.arguments?["status"]?.stringValue
    let status = ActionItemStatusFilter(raw: rawStatus)
    let dateFrom = params.arguments?["date_from"]?.stringValue
    let dateTo = params.arguments?["date_to"]?.stringValue
    let count = params.arguments?["count"]?.intValue ?? 50

    // Marker-backed status data exists in the index (trailing '(done)' /
    // '(status: done)' bullet markers), but the done filter stays rejected
    // until the marker write-back path is verified against a real library —
    // fail loudly rather than expose an unproven filter.
    if status == .done {
        return textResult(
            "Unsupported status filter: \"\(rawStatus ?? "done")\". The done filter is not enabled yet. Use status \"open\" (the default) or \"all\" — items whose bullet carries a '(done)' or '(status: done)' marker in the saved Markdown already drop out of \"open\" results.",
            isError: true
        )
    }

    var result = try index.listActionItems(
        owner: owner, query: query, status: status,
        dateFrom: dateFrom, dateTo: dateTo, maxItems: count
    )

    for i in result.items.indices {
        result.items[i].meetingTitle = meetingTitle(for: result.items[i].filename, meetingDirs: meetingDirs)
    }

    if result.items.isEmpty {
        return try emptyResult(scope: .summaries, searchedDirectories: meetingDirs, index: index)
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
        return try emptyResult(scope: .summaries, searchedDirectories: meetingDirs, index: index)
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
        return try emptyResult(scope: .summaries, searchedDirectories: meetingDirs, index: index)
    }

    let json = try JSONEncoder.pretty.encode(result)
    return textResult(String(data: json, encoding: .utf8) ?? "{}")
}

// MARK: - status

func handleStatus(index: TranscriptIndex, directories: TranscriptedDataDirectories) throws -> CallTool.Result {
    let counts = try index.counts()
    let result = StatusResult(
        serverVersion: TranscriptedMCP.serverVersion,
        meetingDirectories: directories.meetingDirs.map(\.path),
        dictationDirectories: directories.dictationDirs.map(\.path),
        resolutionSource: directories.resolutionSource.rawValue,
        legacyFallbackAppended: directories.legacyFallbackAppended,
        indexDirectory: directories.indexDir.path,
        indexedMeetings: counts.meetings,
        indexedDictationDays: counts.dictationDays,
        indexedDictationEntries: counts.dictationEntries,
        indexedSummaryItems: counts.summaryItems,
        summarizedMeetings: counts.summarizedMeetings,
        summariesIndexed: counts.summaryItems > 0
    )

    let json = try JSONEncoder.pretty.encode(result)
    return textResult(String(data: json, encoding: .utf8) ?? "{}")
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
