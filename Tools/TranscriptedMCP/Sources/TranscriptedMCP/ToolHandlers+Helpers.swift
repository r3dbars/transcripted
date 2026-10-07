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
    case writing
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
    case .writing:
        payload = EmptyQueryResult(
            searchedDirectories: directories,
            indexedMeetings: nil,
            indexedDictationDays: nil,
            indexedDictationEntries: nil,
            indexedWritingDays: counts.writingDays,
            indexedWritingEntries: counts.writingEntries,
            indexedSummaryItems: nil,
            hint: counts.writingDays == 0
                ? "No writing is indexed. Writing is saved only when Save my writing is on in Transcripted's Writing settings; call the status tool to see the writing folder."
                : "No writing matched these filters — try widening the date range or changing the query."
        )
    case .mixed:
        payload = EmptyQueryResult(
            searchedDirectories: directories,
            indexedMeetings: counts.meetings,
            indexedDictationDays: counts.dictationDays,
            indexedDictationEntries: nil,
            indexedWritingDays: counts.writingDays,
            indexedWritingEntries: counts.writingEntries,
            indexedSummaryItems: nil,
            hint: counts.meetings == 0 && counts.dictationDays == 0 && counts.writingDays == 0
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
        case "list_writing":
            self.init(toolKind: "list", captureKind: "writing")
        case "read_writing":
            self.init(toolKind: "read", captureKind: "writing")
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
        case "writing":
            return "writing"
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

    let resolvedBuildIdentity = buildIdentity ?? AgentCaptureQueryTelemetryRuntime.buildIdentity()
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
