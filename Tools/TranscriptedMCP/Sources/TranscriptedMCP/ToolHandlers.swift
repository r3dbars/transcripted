import Foundation
import MCP

func registerToolHandlers(server: Server, index: TranscriptIndex, dataDir: URL) async {
    await server.withMethodHandler(ListTools.self) { _ in
        .init(tools: [
            Tool(
                name: "search_transcripts",
                description: "Full-text search across all meeting transcripts. Returns matching utterances grouped by meeting, with speaker names, timestamps, and meeting context. Supports natural language queries.",
                inputSchema: .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Search query (e.g. 'product roadmap discussion')")
                    ]),
                    "speaker": .object([
                        "type": .string("string"),
                        "description": .string("Filter to utterances by this speaker (supports name variants: Mike matches Michael)")
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
                annotations: .init(readOnlyHint: true)
            ),
            Tool(
                name: "get_speaker_history",
                description: "Get all meetings a speaker participated in, with per-meeting stats and preview snippets. Supports name variants (Mike finds Michael) and persistent speaker UUIDs.",
                inputSchema: .object([
                    "speaker": .object([
                        "type": .string("string"),
                        "description": .string("Speaker name or persistent speaker UUID")
                    ]),
                ]),
                annotations: .init(readOnlyHint: true)
            ),
            Tool(
                name: "list_recent_meetings",
                description: "List recent meetings with participants, duration, word count, and speaker details.",
                inputSchema: .object([
                    "count": .object([
                        "type": .string("integer"),
                        "description": .string("Number of meetings to return (default: 10, max: 50)")
                    ]),
                ]),
                annotations: .init(readOnlyHint: true)
            ),
        ])
    }

    await server.withMethodHandler(CallTool.self) { params in
        do {
            switch params.name {
            case "search_transcripts":
                return try handleSearch(params: params, index: index)
            case "get_speaker_history":
                return try handleSpeakerHistory(params: params, index: index)
            case "list_recent_meetings":
                return try handleListMeetings(params: params, index: index)
            default:
                return .init(content: [.text(text:"Unknown tool: \(params.name)")], isError: true)
            }
        } catch {
            return .init(content: [.text(text:"Error: \(error.localizedDescription)")], isError: true)
        }
    }
}

private func handleSearch(params: CallTool.Parameters, index: TranscriptIndex) throws -> CallTool.Result {
    guard let query = params.arguments?["query"]?.stringValue, !query.isEmpty else {
        return .init(content: [.text(text:"Missing required parameter: query")], isError: true)
    }

    let speaker = params.arguments?["speaker"]?.stringValue
    let dateFrom = params.arguments?["date_from"]?.stringValue
    let dateTo = params.arguments?["date_to"]?.stringValue

    let results = try index.searchUtterances(
        query: query, speaker: speaker, dateFrom: dateFrom, dateTo: dateTo
    )

    if results.results.isEmpty {
        var msg = "No results found for \"\(query)\""
        if let s = speaker { msg += " by \(s)" }
        if let d = dateFrom { msg += " from \(d)" }
        if let d = dateTo { msg += " to \(d)" }
        return .init(content: [.text(text:msg)])
    }

    let json = try JSONEncoder.pretty.encode(results)
    return .init(content: [.text(text:String(data: json, encoding: .utf8) ?? "[]")])
}

private func handleSpeakerHistory(params: CallTool.Parameters, index: TranscriptIndex) throws -> CallTool.Result {
    guard let speaker = params.arguments?["speaker"]?.stringValue, !speaker.isEmpty else {
        return .init(content: [.text(text:"Missing required parameter: speaker")], isError: true)
    }

    let results = try index.getSpeakerHistory(speaker: speaker)

    if results.meetings.isEmpty {
        return .init(content: [.text(text:"No meetings found for speaker \"\(speaker)\". Use list_recent_meetings to see known speakers.")])
    }

    let json = try JSONEncoder.pretty.encode(results)
    return .init(content: [.text(text:String(data: json, encoding: .utf8) ?? "{}")])
}

private func handleListMeetings(params: CallTool.Parameters, index: TranscriptIndex) throws -> CallTool.Result {
    let count = params.arguments?["count"]?.intValue ?? 10

    let results = try index.listRecentMeetings(count: count)

    if results.isEmpty {
        return .init(content: [.text(text:"No meetings found. Record a meeting with Transcripted first.")])
    }

    let json = try JSONEncoder.pretty.encode(results)
    return .init(content: [.text(text:String(data: json, encoding: .utf8) ?? "[]")])
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
