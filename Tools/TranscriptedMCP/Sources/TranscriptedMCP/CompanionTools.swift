import Foundation
import MCP

/// Companion view data stays in tool-result _meta until the user attaches it.
/// _meta hides it from model context; the ChatGPT host still receives this data.
enum CompanionTools {
    static let resourceURI = "ui://transcripted/companion.html"
    static let payloadKey = "transcripted/companion"
    /// Packaged companion excludes the legacy audio-embedding widget. Default
    /// stdio clients keep their existing saved-audio surface.
    static var companionMode: Bool { ProcessInfo.processInfo.environment["TRANSCRIPTED_MCP_COMPANION_MODE"] == "1" }
    static let names: Set<String> = ["show_companion", "get_recording_status", "start_meeting", "stop_meeting", "read_live_transcript", "get_live_meeting_context", "set_live_context_sharing", "browse_companion_context", "read_context_passage"]
    static var tools: [Tool] {
        let session: Value = .object(["type": .string("string"), "description": .string("Current meeting session_id from get_recording_status. Never reuse an earlier session.")])
        let limit: Value = .object(["type": .string("integer"), "minimum": .int(1), "maximum": .int(40)])
        return [
            descriptor("show_companion", "Open Transcripted's companion: saved context, meeting controls, and explicitly shared live text. Opening this view never starts recording or enables sharing.", [:], meta: openerMeta),
            descriptor("get_recording_status", "Read Transcripted connection, capture state, current session and sharing permission. Returns no transcript text.", [:]),
            descriptor("start_meeting", "Start microphone and system-audio meeting capture in Transcripted only when the user explicitly asks. Requires companion meeting-control permission in Transcripted. Live text sharing stays off. Check status after a timeout before retrying.", [:], writes: true),
            descriptor("stop_meeting", "Stop the specified current meeting and save it through Transcripted's normal processing flow. Never stops a different session. A stopped response means queued for final transcription, not that the final transcript is ready.", ["session_id": session], required: ["session_id"], writes: true),
            descriptor("set_live_context_sharing", "Enable or disable sharing live text with ChatGPT for this one meeting, only after an explicit user request or toggle. Sharing is off for every new session. Requires Transcripted's live-sharing permission.", ["session_id": session, "enabled": .object(["type": .string("boolean")])], required: ["session_id", "enabled"], writes: true, idempotent: true),
            descriptor("read_live_transcript", "View a bounded provisional live transcript in the companion. Requires per-session live sharing. Text is returned to the host view, not attached to model context automatically. Final diarized saved text remains authoritative.", ["session_id": session, "after_sequence": .object(["type": .string("integer"), "minimum": .int(0)]), "limit": limit], required: ["session_id"], meta: appOnlyMeta),
            descriptor("get_live_meeting_context", "Get a bounded recent live transcript for a question about the ongoing meeting. Only succeeds while the user has explicitly enabled live text sharing for this session. Never enable sharing automatically. Text is provisional and may change in the final saved transcript.", ["session_id": session, "limit": limit], required: ["session_id"]),
            descriptor("browse_companion_context", "Browse or search the saved local library in the companion view. Returned passages remain outside model context until explicitly attached.", ["query": .object(["type": .string("string"), "maxLength": .int(300)]), "kind": .object(["type": .string("string"), "enum": .array([.string("all"), .string("meeting"), .string("dictation"), .string("writing")])])], meta: appOnlyMeta),
            descriptor("read_context_passage", "Read one selected saved meeting utterance or dictation/writing entry into the companion view. No audio; at most 4000 characters. Attach only the relevant passage when the user chooses.", ["kind": .object(["type": .string("string"), "enum": .array([.string("meeting"), .string("dictation"), .string("writing")])]), "filename": .object(["type": .string("string")]), "passage_index": .object(["type": .string("integer"), "minimum": .int(0)]), "entry_id": .object(["type": .string("string")])], required: ["kind", "filename"], meta: appOnlyMeta)
        ]
    }

    private static func descriptor(_ name: String, _ description: String, _ properties: [String: Value], required: [String] = [], writes: Bool = false, idempotent: Bool = false, meta: Metadata? = nil) -> Tool {
        Tool(name: name, title: name == "show_companion" ? "Transcripted" : nil, description: description,
             inputSchema: .object(["type": .string("object"), "properties": .object(properties), "required": .array(required.map(Value.string)), "additionalProperties": .bool(false)]),
             annotations: .init(readOnlyHint: !writes, destructiveHint: false, idempotentHint: writes ? idempotent : nil, openWorldHint: false), _meta: meta)
    }

    static var appOnlyMeta: Metadata { Metadata(additionalFields: ["ui": .object(["visibility": .array([.string("app")])])]) }
    static var openerMeta: Metadata {
        Metadata(additionalFields: [
            "ui": .object(["resourceUri": .string(resourceURI), "visibility": .array([.string("model"), .string("app")])]),
            "openai/outputTemplate": .string(resourceURI),
            "openai/ui": .object(["entrypoints": .array([.object(["type": .string("global")]), .object(["type": .string("thread")])])])
        ])
    }
    static var resourceMeta: Metadata {
        Metadata(additionalFields: [
            "ui": .object(["csp": .object(["connectDomains": .array([]), "resourceDomains": .array([])]), "prefersBorder": .bool(false)]),
            "openai/ui": .object(["availableDisplayModes": .array([.string("fullscreen")]), "preferredDisplayMode": .string("fullscreen")])
        ])
    }
    static var resource: Resource {
        Resource(name: "transcripted_companion", uri: resourceURI, title: "Transcripted", description: "Meeting companion and selected saved context.", mimeType: "text/html;profile=mcp-app", _meta: resourceMeta)
    }

    static func call(params: CallTool.Parameters, index: TranscriptIndex, directories: TranscriptedDataDirectories, client: CompanionClient = CompanionClient()) async -> CallTool.Result {
        do {
            let args = params.arguments ?? [:]
            switch params.name {
            case "show_companion":
                let status: [String: Value]
                do { status = try await native(client, "status") }
                catch { status = ["connected": .bool(false), "state": .string("offline"), "message": .string((error as? CompanionClient.Failure)?.errorDescription ?? "Open Transcripted to connect.")] }
                let items = try browse(query: nil, kind: .all, index: index, directories: directories)
                return try viewResult("Transcripted companion opened. Recording and live sharing require explicit actions.", payload: ["status": .object(status), "items": .array(items)], summary: ["view": .string("companion")], opener: true)
            case "browse_companion_context":
                let query = args["query"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                guard (query?.count ?? 0) <= 300 else { throw CompanionClient.Failure(code: "invalid_request") }
                let kind = ContextKind(rawValue: args["kind"]?.stringValue ?? "all") ?? .all
                let items = try browse(query: query, kind: kind, index: index, directories: directories)
                return try viewResult("Saved context list refreshed. Select a passage to attach.", payload: ["items": .array(items)], summary: ["count": .int(items.count)])
            case "read_context_passage":
                let passage = try savedPassage(args: args, directories: directories)
                return try viewResult("Selected passage loaded in the companion. It has not been attached to chat.", payload: ["passage": .object(passage)], summary: ["loaded": .bool(true)])
            case "get_recording_status":
                return try visibleResult(try await native(client, "status"))
            case "start_meeting":
                return try visibleResult(try await native(client, "start_meeting", ["share_live": .bool(false)], timeout: 35))
            case "stop_meeting":
                return try visibleResult(try await native(client, "stop_meeting", ["session_id": .string(try sessionID(args))], timeout: 35))
            case "set_live_context_sharing":
                guard case .bool(let enabled) = args["enabled"] else { throw CompanionClient.Failure(code: "invalid_request") }
                return try visibleResult(try await native(client, "set_live_sharing", ["session_id": .string(try sessionID(args)), "enabled": .bool(enabled)]))
            case "read_live_transcript", "get_live_meeting_context":
                let session = try sessionID(args)
                let limit = try integer(args, "limit", default: 20, range: 1...40)
                var after = try integer(args, "after_sequence", default: 0, range: 0...Int.max)
                if params.name == "get_live_meeting_context" {
                    let status = try await native(client, "status")
                    guard status["session_id"] == .string(session) else { throw CompanionClient.Failure(code: "stale_session") }
                    guard status["sharing_enabled"] == .bool(true) else { throw CompanionClient.Failure(code: "permission_denied") }
                    after = max(0, (status["latest_sequence"]?.intValue ?? 0) - limit)
                }
                let result = try await native(client, "read_live_transcript", ["session_id": .string(session), "after_sequence": .int(after), "limit": .int(limit)])
                guard result["session_id"] == .string(session) else { throw CompanionClient.Failure(code: "stale_session") }
                guard result["sharing_enabled"] == .bool(true) else { throw CompanionClient.Failure(code: "permission_denied") }
                let bounded = boundedLiveResult(result, newest: params.name == "get_live_meeting_context")
                if params.name == "get_live_meeting_context" { return try visibleResult(bounded) }
                var summary = bounded; summary.removeValue(forKey: "segments")
                return try viewResult("Live transcript refreshed in the companion view. Provisional text; final saved transcript remains authoritative.", payload: ["live": .object(bounded)], summary: summary)
            default: throw CompanionClient.Failure(code: "invalid_request")
            }
        } catch {
            let failure = (error as? CompanionClient.Failure) ?? CompanionClient.Failure(code: "internal_error")
            return CallTool.Result(content: [.text(text: failure.errorDescription ?? "Companion request failed.", annotations: nil, _meta: nil)], isError: true,
                _meta: Metadata(additionalFields: ["transcripted/errorCode": .string(failure.code)]))
        }
    }

    private static func native(_ client: CompanionClient, _ method: String, _ params: [String: Value] = [:], timeout: TimeInterval? = nil) async throws -> [String: Value] {
        let transport = timeout.map { CompanionClient(root: client.root, timeout: $0) } ?? client
        return try await Task.detached(priority: .userInitiated) { try transport.call(method, params: params) }.value
    }
    private static func sessionID(_ args: [String: Value]) throws -> String {
        guard let session = args["session_id"]?.stringValue, UUID(uuidString: session) != nil else { throw CompanionClient.Failure(code: "invalid_request") }
        return session
    }
    private static func integer(_ args: [String: Value], _ key: String, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
        guard let raw = args[key] else { return fallback }
        guard case .int(let number) = raw, range.contains(number) else { throw CompanionClient.Failure(code: "invalid_request") }
        return number
    }
    private static func visibleResult(_ object: [String: Value]) throws -> CallTool.Result {
        let text = String(decoding: try JSONEncoder().encode(object), as: UTF8.self)
        return try CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], structuredContent: object, isError: false)
    }
    static func viewResult(_ text: String, payload: [String: Value], summary: [String: Value], opener: Bool = false) throws -> CallTool.Result {
        var meta: [String: Value] = [payloadKey: .object(payload)]
        if opener { meta["ui"] = .object(["resourceUri": .string(resourceURI)]) }
        return try CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], structuredContent: summary, isError: false, _meta: Metadata(additionalFields: meta))
    }
    static func boundedLiveResult(_ result: [String: Value], newest: Bool = false) -> [String: Value] {
        var output = result
        guard case .array(let segments) = result["segments"] else { output["segments"] = .array([]); return output }
        var budget = 8_000
        var bounded: [Value] = []
        let ordered = newest ? Array(segments.suffix(40).reversed()) : Array(segments.prefix(40))
        for segment in ordered {
            guard case .object(var fields) = segment, let text = fields["text"]?.stringValue else { continue }
            let allowance = min(budget, 2_000)
            let slice = newest ? String(text.suffix(allowance)) : String(text.prefix(allowance))
            if slice.count != text.count { fields["truncated"] = .bool(true) }
            fields["text"] = .string(slice)
            bounded.append(.object(fields)); budget -= slice.count
            if budget <= 0 { break }
        }
        if newest { bounded.reverse() }
        output["segments"] = .array(bounded)
        if bounded.count != segments.count { output["truncated"] = .bool(true) }
        if let last = bounded.last, case .object(let item) = last { output["next_sequence"] = item["sequence"] }
        return output
    }

    private static func encodedValue<T: Encodable>(_ value: T) throws -> Value { try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(value)) }
    static func browse(query: String?, kind: ContextKind, index: TranscriptIndex, directories: TranscriptedDataDirectories) throws -> [Value] {
        var items: [Value]
        if let query, !query.isEmpty {
            let result = try index.searchContext(query: query, speaker: nil, kind: kind, dateFrom: nil, dateTo: nil, maxItems: 15, mode: .hybrid)
            items = try result.results.map { try encodedValue($0) }
        } else {
            let result = try index.listRecentContext(kind: kind, count: 15)
            items = try result.items.map { try encodedValue($0) }
        }
        return items.map { item in
            guard case .object(var fields) = item else { return item }
            if fields["kind"] == .string("meeting"), let filename = fields["filename"]?.stringValue { fields["title"] = .string(String(meetingTitle(for: filename, meetingDirs: directories.meetingDirs).prefix(200))) }
            if let preview = fields["preview"]?.stringValue { fields["preview"] = .string(String(preview.prefix(220))) }
            if case .array(let snippets) = fields["snippets"] {
                fields["preview"] = .string(String(snippets.compactMap { if case .object(let snippet) = $0 { return snippet["text"]?.stringValue }; return nil }.joined(separator: " · ").prefix(220)))
                fields.removeValue(forKey: "snippets")
            }
            return .object(fields)
        }
    }

    static func sourceURL(kind: String, filename: String, passage: Int, entryID: String?) -> String {
        var route = URLComponents(); route.path = "/context"
        route.queryItems = [URLQueryItem(name: "kind", value: kind), URLQueryItem(name: "filename", value: filename), URLQueryItem(name: "passage", value: String(passage))]
        if let entryID { route.queryItems?.append(URLQueryItem(name: "entry_id", value: entryID)) }
        var url = URLComponents(); url.scheme = "codex"; url.host = "plugins"; url.path = "/transcripted@transcripted-local/app/show_companion"
        url.queryItems = [URLQueryItem(name: "path", value: route.string)]
        return url.string ?? ""
    }

    static func savedPassage(args: [String: Value], directories: TranscriptedDataDirectories) throws -> [String: Value] {
        guard let kind = args["kind"]?.stringValue, let filename = args["filename"]?.stringValue, !filename.isEmpty else { throw CompanionClient.Failure(code: "invalid_request") }
        let passage = try integer(args, "passage_index", default: 0, range: 0...Int.max)
        let entryID = args["entry_id"]?.stringValue
        let dirs: [URL]
        switch kind { case "meeting": dirs = directories.meetingDirs; case "dictation": dirs = directories.dictationDirs; case "writing": dirs = directories.writingDirs; default: throw CompanionClient.Failure(code: "invalid_request") }
        guard case .valid(let url) = PathSecurity.resolveReadableFile(named: filename, appendingExtension: "md", in: dirs) else { throw CompanionClient.Failure(code: "invalid_request") }
        let text: String; let title: String; let speaker: String; let total: Int; var timestamp: Double?; var selectedID: String?
        switch kind {
        case "meeting":
            guard let meeting = TranscriptLoader.loadMeeting(url), meeting.utterances.indices.contains(passage) else { throw CompanionClient.Failure(code: "invalid_request") }
            let utterance = meeting.utterances[passage]
            text = utterance.text; timestamp = utterance.start; total = meeting.utterances.count
            speaker = meeting.speakers.first { $0.id == utterance.speakerId }?.name ?? utterance.speakerId
            title = meetingTitle(for: filename, meetingDirs: dirs)
        case "dictation":
            guard let day = TranscriptLoader.loadDictationDay(url) else { throw CompanionClient.Failure(code: "invalid_request") }
            let entries = entryID.map { id in day.entries.filter { $0.id == id } } ?? day.entries
            guard entries.indices.contains(passage) else { throw CompanionClient.Failure(code: "invalid_request") }
            let entry = entries[passage]; text = entry.text; title = entry.title; speaker = entry.sourceAppName; selectedID = entry.id; total = entries.count
        default:
            guard let day = TranscriptLoader.loadWritingDay(url) else { throw CompanionClient.Failure(code: "invalid_request") }
            let entries = entryID.map { id in day.entries.filter { $0.id == id } } ?? day.entries
            guard entries.indices.contains(passage) else { throw CompanionClient.Failure(code: "invalid_request") }
            let entry = entries[passage]; text = entry.text; title = entry.title; speaker = entry.sourceAppName; selectedID = entry.id; total = entries.count
        }
        var result: [String: Value] = ["kind": .string(kind), "filename": .string(filename), "passage_index": .int(passage), "total_passages": .int(total), "title": .string(String(title.prefix(200))), "speaker": .string(String(speaker.prefix(200))), "text": .string(String(text.prefix(4_000))), "truncated": .bool(text.count > 4_000), "source_url": .string(sourceURL(kind: kind, filename: filename, passage: passage, entryID: entryID))]
        if let timestamp { result["start_seconds"] = .double(timestamp) }
        if let selectedID { result["entry_id"] = .string(selectedID) }
        return result
    }
}
