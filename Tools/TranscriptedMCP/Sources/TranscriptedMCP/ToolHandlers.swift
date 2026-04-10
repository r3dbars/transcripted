import Foundation
import MCP

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
        ])
    }

    await server.withMethodHandler(CallTool.self) { params in
        do {
            switch params.name {
            case "list_meetings":
                return try handleListMeetings(params: params, index: index, meetingsDir: directories.meetingsDir)
            case "list_dictations":
                return try handleListDictations(params: params, index: index)
            case "read_meeting":
                return try handleReadMeeting(params: params, meetingsDir: directories.meetingsDir)
            case "read_dictation":
                return try handleReadDictation(params: params, dictationsDir: directories.dictationsDir)
            case "search":
                return try handleSearch(params: params, index: index)
            case "search_context":
                return try handleSearchContext(params: params, index: index, meetingsDir: directories.meetingsDir)
            case "recent_context":
                return try handleRecentContext(params: params, index: index, meetingsDir: directories.meetingsDir)
            case "who_is":
                return try handleWhoIs(params: params, index: index)
            case "recap":
                return try handleRecap(params: params, index: index, meetingsDir: directories.meetingsDir)
            default:
                return .init(content: [.text(text: "Unknown tool: \(params.name)")], isError: true)
            }
        } catch {
            return .init(content: [.text(text: "Error: \(error.localizedDescription)")], isError: true)
        }
    }
}

// MARK: - list_meetings

private func handleListMeetings(params: CallTool.Parameters, index: TranscriptIndex, meetingsDir: URL) throws -> CallTool.Result {
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
            in: meetingsDir
        ) else { continue }
        if let content = try? String(contentsOf: mdURL, encoding: .utf8) {
            results[i].title = extractTitle(from: content) ?? results[i].filename
        }
    }

    if results.isEmpty {
        return .init(content: [.text(text: "No meetings found.")])
    }

    let json = try JSONEncoder.pretty.encode(results)
    return .init(content: [.text(text: String(data: json, encoding: .utf8) ?? "[]")])
}

private func handleListDictations(params: CallTool.Parameters, index: TranscriptIndex) throws -> CallTool.Result {
    let count = params.arguments?["count"]?.intValue ?? 10
    let date = params.arguments?["date"]?.stringValue
    let dateFrom = params.arguments?["date_from"]?.stringValue ?? date
    let dateTo = params.arguments?["date_to"]?.stringValue ?? date

    let results = try index.listDictationDays(count: count, dateFrom: dateFrom, dateTo: dateTo)

    if results.isEmpty {
        return .init(content: [.text(text: "No dictations found.")])
    }

    let json = try JSONEncoder.pretty.encode(results)
    return .init(content: [.text(text: String(data: json, encoding: .utf8) ?? "[]")])
}

/// Extract title from markdown YAML frontmatter
private func extractTitle(from content: String) -> String? {
    // Minimum valid frontmatter is "---\n...\n---\n" (8+ chars)
    guard content.count >= 8, content.hasPrefix("---"),
          let endRange = content.range(of: "\n---\n", range: content.index(content.startIndex, offsetBy: 3)..<content.endIndex) else { return nil }
    let yaml = String(content[content.index(content.startIndex, offsetBy: 4)..<endRange.lowerBound])
    for line in yaml.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed == "---" { break }
        if trimmed.hasPrefix("title:") {
            let title = String(trimmed.dropFirst(6)).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            return title.isEmpty ? nil : title
        }
    }
    return nil
}

/// Returns non-empty transcript dialogue lines from the `## Full Transcript` section, filtering boilerplate.
private func extractDialogueLines(from content: String) -> [String] {
    guard let range = content.range(of: "## Full Transcript\n") else { return [] }
    return String(content[range.upperBound...])
        .components(separatedBy: "\n")
        .filter { !$0.isEmpty && !$0.hasPrefix("*Generated by") && $0 != "---" }
}

// MARK: - read_meeting

private func handleReadMeeting(params: CallTool.Parameters, meetingsDir: URL) throws -> CallTool.Result {
    guard let filename = params.arguments?["filename"]?.stringValue, !filename.isEmpty else {
        return .init(content: [.text(text: "Missing required parameter: filename")], isError: true)
    }

    let section = params.arguments?["section"]?.stringValue ?? "full"

    let mdURL: URL
    switch PathSecurity.resolveReadableFile(named: filename, appendingExtension: "md", in: meetingsDir) {
    case .valid(let url):
        mdURL = url
    case .missing:
        return .init(content: [.text(text: "Meeting not found: \(filename). Use list_meetings to see available meetings.")], isError: true)
    case .invalid:
        return .init(content: [.text(text: "Invalid filename: \(filename)")], isError: true)
    }

    guard let content = try? String(contentsOf: mdURL, encoding: .utf8) else {
        return .init(content: [.text(text: "Meeting not found: \(filename). Use list_meetings to see available meetings.")], isError: true)
    }

    switch section {
    case "transcript":
        let dialogue = extractDialogueLines(from: content).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(content: [.text(text: dialogue.isEmpty ? content : dialogue)])

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
        return .init(content: [.text(text: result.isEmpty ? content : result)])

    default: // "full"
        return .init(content: [.text(text: content)])
    }
}

private func handleReadDictation(params: CallTool.Parameters, dictationsDir: URL) throws -> CallTool.Result {
    guard let filename = params.arguments?["filename"]?.stringValue, !filename.isEmpty else {
        return .init(content: [.text(text: "Missing required parameter: filename")], isError: true)
    }

    let entryId = params.arguments?["entry_id"]?.stringValue
    let sidecarURL: URL
    switch PathSecurity.resolveReadableFile(named: filename, appendingExtension: "json", in: dictationsDir) {
    case .valid(let url):
        sidecarURL = url
    case .missing:
        return .init(content: [.text(text: "Dictation not found: \(filename). Use list_dictations to see available days.")], isError: true)
    case .invalid:
        return .init(content: [.text(text: "Invalid filename: \(filename)")], isError: true)
    }

    guard let day = TranscriptLoader.loadDictationDay(sidecarURL) else {
        return .init(content: [.text(text: "Dictation not found: \(filename). Use list_dictations to see available days.")], isError: true)
    }

    if let entryId {
        guard let entry = day.entries.first(where: { $0.id == entryId }) else {
            return .init(content: [.text(text: "Entry not found: \(entryId). Use recent_context or search_context to inspect entry IDs.")], isError: true)
        }

        let result = """
        # \(entry.title)

        Captured: \(entry.createdAt)
        Source app: \(entry.sourceAppName)
        Delivery: \(entry.delivery)
        Words: \(entry.wordCount)

        \(entry.text)
        """
        return .init(content: [.text(text: result)])
    }

    let markdownURL: URL
    switch PathSecurity.resolveReadableFile(named: day.markdownFilename, in: dictationsDir) {
    case .valid(let url):
        markdownURL = url
    case .missing:
        let json = try JSONEncoder.pretty.encode(day)
        return .init(content: [.text(text: String(data: json, encoding: .utf8) ?? "{}")])
    case .invalid:
        return .init(content: [.text(text: "Invalid markdown filename for \(filename)")], isError: true)
    }

    guard let content = try? String(contentsOf: markdownURL, encoding: .utf8) else {
        let json = try JSONEncoder.pretty.encode(day)
        return .init(content: [.text(text: String(data: json, encoding: .utf8) ?? "{}")])
    }

    return .init(content: [.text(text: content)])
}

// MARK: - search

private func handleSearch(params: CallTool.Parameters, index: TranscriptIndex) throws -> CallTool.Result {
    guard let query = params.arguments?["query"]?.stringValue, !query.isEmpty else {
        return .init(content: [.text(text: "Missing required parameter: query")], isError: true)
    }

    let speaker = params.arguments?["speaker"]?.stringValue
    let dateFrom = params.arguments?["date_from"]?.stringValue
    let dateTo = params.arguments?["date_to"]?.stringValue

    let results = try index.searchUtterances(query: query, speaker: speaker, dateFrom: dateFrom, dateTo: dateTo)

    if results.results.isEmpty {
        var msg = "No results found for \"\(query)\""
        if let s = speaker { msg += " by \(s)" }
        return .init(content: [.text(text: msg)])
    }

    let json = try JSONEncoder.pretty.encode(results)
    return .init(content: [.text(text: String(data: json, encoding: .utf8) ?? "[]")])
}

private func handleSearchContext(params: CallTool.Parameters, index: TranscriptIndex, meetingsDir: URL) throws -> CallTool.Result {
    guard let query = params.arguments?["query"]?.stringValue, !query.isEmpty else {
        return .init(content: [.text(text: "Missing required parameter: query")], isError: true)
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

    hydrateMeetingTitles(in: &results.results, kind: \.kind, filename: \.filename, title: \.title, meetingsDir: meetingsDir)

    if results.results.isEmpty {
        return .init(content: [.text(text: "No context found for \"\(query)\".")])
    }

    let json = try JSONEncoder.pretty.encode(results)
    return .init(content: [.text(text: String(data: json, encoding: .utf8) ?? "{}")])
}

private func handleRecentContext(params: CallTool.Parameters, index: TranscriptIndex, meetingsDir: URL) throws -> CallTool.Result {
    let kind = parseContextKind(params.arguments?["kind"]?.stringValue)
    let count = max(1, min(params.arguments?["count"]?.intValue ?? 10, 50))
    let dateFrom = params.arguments?["date_from"]?.stringValue
    let dateTo = params.arguments?["date_to"]?.stringValue

    var result = try index.listRecentContext(kind: kind, count: count, dateFrom: dateFrom, dateTo: dateTo)
    hydrateMeetingTitles(in: &result.items, kind: \.kind, filename: \.filename, title: \.title, meetingsDir: meetingsDir)

    if result.items.isEmpty {
        return .init(content: [.text(text: "No recent context found.")])
    }

    let json = try JSONEncoder.pretty.encode(result)
    return .init(content: [.text(text: String(data: json, encoding: .utf8) ?? "{}")])
}

// MARK: - who_is

private func handleWhoIs(params: CallTool.Parameters, index: TranscriptIndex) throws -> CallTool.Result {
    guard let speaker = params.arguments?["speaker"]?.stringValue, !speaker.isEmpty else {
        return .init(content: [.text(text: "Missing required parameter: speaker")], isError: true)
    }

    let profile = try index.getPersonProfile(speaker: speaker)

    if profile.meetingCount == 0 {
        return .init(content: [.text(text: "No meetings found for \"\(speaker)\". Try a different name or use list_meetings to see known speakers.")])
    }

    let json = try JSONEncoder.pretty.encode(profile)
    return .init(content: [.text(text: String(data: json, encoding: .utf8) ?? "{}")])
}

// MARK: - recap

private func handleRecap(params: CallTool.Parameters, index: TranscriptIndex, meetingsDir: URL) throws -> CallTool.Result {
    // Use local calendar so "today" matches transcript dates (which are stored in local time)
    let today = DateFormatter.localYYYYMMDD.string(from: Date())
    let dateFrom = params.arguments?["date_from"]?.stringValue ?? String(today)
    let dateTo = params.arguments?["date_to"]?.stringValue ?? dateFrom

    let meetings = try index.listMeetings(count: 50, dateFrom: dateFrom, dateTo: dateTo)

    if meetings.isEmpty {
        return .init(content: [.text(text: "No meetings found from \(dateFrom) to \(dateTo).")])
    }

    var recapParts: [RecapEntry] = []

    for meeting in meetings {
        // Read first ~200 words of transcript as preview
        guard case .valid(let mdURL) = PathSecurity.resolveReadableFile(
            named: meeting.filename,
            appendingExtension: "md",
            in: meetingsDir
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
    return .init(content: [.text(text: String(data: json, encoding: .utf8) ?? "[]")])
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

private func parseContextKind(_ raw: String?) -> ContextKind {
    guard let raw, let kind = ContextKind(rawValue: raw.lowercased()) else {
        return .all
    }
    return kind
}

private func meetingTitle(for filename: String, meetingsDir: URL) -> String {
    guard case .valid(let mdURL) = PathSecurity.resolveReadableFile(
        named: filename,
        appendingExtension: "md",
        in: meetingsDir
    ),
    let content = try? String(contentsOf: mdURL, encoding: .utf8) else {
        return filename
    }
    return extractTitle(from: content) ?? filename
}

private func hydrateMeetingTitles<T>(
    in collection: inout [T],
    kind: KeyPath<T, ContextKind>,
    filename: KeyPath<T, String>,
    title: WritableKeyPath<T, String>,
    meetingsDir: URL
) {
    for index in collection.indices where collection[index][keyPath: kind] == .meeting {
        collection[index][keyPath: title] = meetingTitle(for: collection[index][keyPath: filename], meetingsDir: meetingsDir)
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
