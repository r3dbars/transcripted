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
            default:
                return textResult("Unknown tool: \(params.name)", isError: true)
            }
        } catch {
            return textResult("Error: \(error.localizedDescription)", isError: true)
        }
    }
}

// MARK: - list_meetings

private func handleListMeetings(params: CallTool.Parameters, index: TranscriptIndex, meetingDirs: [URL]) throws -> CallTool.Result {
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

    let json = try JSONEncoder.pretty.encode(results)
    return textResult(String(data: json, encoding: .utf8) ?? "[]")
}

private func handleListDictations(params: CallTool.Parameters, index: TranscriptIndex) throws -> CallTool.Result {
    let count = params.arguments?["count"]?.intValue ?? 10
    let date = params.arguments?["date"]?.stringValue
    let dateFrom = params.arguments?["date_from"]?.stringValue ?? date
    let dateTo = params.arguments?["date_to"]?.stringValue ?? date

    let results = try index.listDictationDays(count: count, dateFrom: dateFrom, dateTo: dateTo)

    if results.isEmpty {
        return textResult("No dictations found.")
    }

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
    let mode = parseSearchMode(params.arguments?["mode"]?.stringValue)

    var results = try index.searchUtterances(query: query, speaker: speaker, dateFrom: dateFrom, dateTo: dateTo, mode: mode)
    hydrateMeetingSearchTitles(in: &results, meetingDirs: meetingDirs)

    if results.results.isEmpty {
        var msg = "No results found for \"\(query)\""
        if let s = speaker { msg += " by \(s)" }
        return textResult(msg)
    }

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
    let mode = parseSearchMode(params.arguments?["mode"]?.stringValue)

    var results = try index.searchContext(
        query: query,
        speaker: speaker,
        kind: kind,
        dateFrom: dateFrom,
        dateTo: dateTo,
        maxItems: count,
        mode: mode
    )

    hydrateMeetingTitles(in: &results.results, kind: \.kind, filename: \.filename, title: \.title, meetingDirs: meetingDirs)

    if results.results.isEmpty {
        return textResult("No context found for \"\(query)\".")
    }

    let json = try JSONEncoder.pretty.encode(results)
    return textResult(String(data: json, encoding: .utf8) ?? "{}")
}

private func handleRecentContext(params: CallTool.Parameters, index: TranscriptIndex, meetingDirs: [URL]) throws -> CallTool.Result {
    let kind = parseContextKind(params.arguments?["kind"]?.stringValue)
    let count = max(1, min(params.arguments?["count"]?.intValue ?? 10, 50))
    let dateFrom = params.arguments?["date_from"]?.stringValue
    let dateTo = params.arguments?["date_to"]?.stringValue

    var result = try index.listRecentContext(kind: kind, count: count, dateFrom: dateFrom, dateTo: dateTo)
    hydrateMeetingTitles(in: &result.items, kind: \.kind, filename: \.filename, title: \.title, meetingDirs: meetingDirs)

    if result.items.isEmpty {
        return textResult("No recent context found.")
    }

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

    let json = try JSONEncoder.pretty.encode(result)
    return textResult(String(data: json, encoding: .utf8) ?? "[]")
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

/// Default to hybrid so paraphrase matches surface without the caller opting in.
/// Falls back to lexical automatically when no embedding backend is available.
private func parseSearchMode(_ raw: String?) -> SearchMode {
    guard let raw, let mode = SearchMode(rawValue: raw.lowercased()) else {
        return .hybrid
    }
    return mode
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
