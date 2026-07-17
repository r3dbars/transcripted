import Foundation
import MCP
import TranscriptedCaptureKit

// MARK: - search

func handleSearch(params: CallTool.Parameters, index: TranscriptIndex, meetingDirs: [URL]) throws -> CallTool.Result {
    guard let query = params.arguments?["query"]?.stringValue,
          !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return invalidAgentCaptureQueryInputResult("Missing required parameter: query")
    }

    let speaker = params.arguments?["speaker"]?.stringValue
    let dateFrom = params.arguments?["date_from"]?.stringValue
    let dateTo = params.arguments?["date_to"]?.stringValue
    let mode = parseSearchMode(params.arguments?["mode"]?.stringValue)

    var results = try index.searchUtterances(query: query, speaker: speaker, dateFrom: dateFrom, dateTo: dateTo, mode: mode)
    hydrateMeetingSearchTitles(in: &results, meetingDirs: meetingDirs)

    if results.results.isEmpty {
        return try emptyResult(scope: .meetings, searchedDirectories: meetingDirs, index: index)
    }

    trackAgentCaptureQueryObserved(
        toolKind: "search",
        captureKind: "meeting",
        sourceCount: Set(results.results.map(\.filename)).count,
        resultCount: results.results.count
    )

    let json = try JSONEncoder.pretty.encode(results)
    return textResult(String(data: json, encoding: .utf8) ?? "[]")
}

// MARK: - search_context

func handleSearchContext(params: CallTool.Parameters, index: TranscriptIndex, meetingDirs: [URL], dictationDirs: [URL]) throws -> CallTool.Result {
    guard let query = params.arguments?["query"]?.stringValue,
          !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return invalidAgentCaptureQueryInputResult("Missing required parameter: query")
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
        return try emptyResult(scope: .mixed, searchedDirectories: meetingDirs + dictationDirs, index: index)
    }

    trackAgentCaptureQueryObserved(
        toolKind: "search",
        captureKind: artifactKind(for: results.results.map(\.kind)),
        sourceCount: Set(results.results.map(\.filename)).count,
        resultCount: results.results.count
    )

    let json = try JSONEncoder.pretty.encode(results)
    return textResult(String(data: json, encoding: .utf8) ?? "{}")
}

// MARK: - recent_context

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
        toolKind: "recent",
        captureKind: artifactKind(for: result.items.map(\.kind)),
        sourceCount: Set(result.items.map(\.filename)).count,
        resultCount: result.items.count
    )

    let json = try JSONEncoder.pretty.encode(result)
    return textResult(String(data: json, encoding: .utf8) ?? "{}")
}

// MARK: - who_is

func handleWhoIs(params: CallTool.Parameters, index: TranscriptIndex) throws -> CallTool.Result {
    guard let speaker = params.arguments?["speaker"]?.stringValue,
          !speaker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return invalidAgentCaptureQueryInputResult("Missing required parameter: speaker")
    }

    let profile = try index.getPersonProfile(speaker: speaker)

    if profile.meetingCount == 0 {
        return emptyOrMissingAgentCaptureQueryResult(
            "No meetings found for \"\(speaker)\". Try a different name or use list_meetings to see known speakers."
        )
    }

    trackAgentCaptureQueryObserved(
        toolKind: "speaker_lookup",
        captureKind: "meeting",
        sourceCount: profile.meetingCount,
        resultCount: profile.recentMeetings.count
    )

    let json = try JSONEncoder.pretty.encode(profile)
    return textResult(String(data: json, encoding: .utf8) ?? "{}")
}

// MARK: - Helpers

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
