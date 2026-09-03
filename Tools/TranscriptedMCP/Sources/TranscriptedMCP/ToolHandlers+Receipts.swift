import Foundation
import MCP
import TranscriptedCaptureKit

// MARK: - decisions / commitments / open_questions / search_meetings
//
// These four tools share the same tail: build a CrossMeetingToolResult from a
// list of receipts, fire telemetry if non-empty, and encode. handleReceiptQuery
// below is that shared tail, factored out of what used to be four near-identical
// copy-paste blocks. Each tool keeps its own thin wrapper (and its own index
// query + item-to-receipt mapping, which do differ) so the MCP tool surface —
// names, params, output shape — is unchanged.

func handleDecisions(params: CallTool.Parameters, index: TranscriptIndex, meetingDirs: [URL]) throws -> CallTool.Result {
    let topic = params.arguments?["topic"]?.stringValue
    let range = parseToolRange(params.arguments?["range"]?.stringValue)
    let count = cappedCrossMeetingCount(params.arguments?["count"]?.intValue)
    let indexed = try index.listDecisions(
        query: topic,
        dateFrom: range.dateFrom,
        dateTo: range.dateTo,
        maxItems: count + 1
    )
    let receipts = indexed.decisions.prefix(count).map { item in
        CrossMeetingReceipt(
            meetingId: item.filename,
            meetingTitle: meetingTitle(for: item.filename, meetingDirs: meetingDirs),
            timestamp: nil,
            quote: item.text,
            date: item.date,
            datetime: item.datetime,
            kind: "decision",
            person: nil
        )
    }
    return try handleReceiptQuery(query: topic, range: range, toolKind: "decisions") {
        (receipts, indexed.truncated || indexed.decisions.count > count)
    }
}

func handleCommitments(params: CallTool.Parameters, index: TranscriptIndex, meetingDirs: [URL]) throws -> CallTool.Result {
    let person = params.arguments?["person"]?.stringValue
    let range = parseToolRange(params.arguments?["range"]?.stringValue)
    let count = cappedCrossMeetingCount(params.arguments?["count"]?.intValue)
    let indexed = try index.listActionItems(
        owner: person,
        query: nil,
        status: .open,
        dateFrom: range.dateFrom,
        dateTo: range.dateTo,
        maxItems: count + 1
    )
    let receipts = indexed.items.prefix(count).map { item in
        CrossMeetingReceipt(
            meetingId: item.filename,
            meetingTitle: meetingTitle(for: item.filename, meetingDirs: meetingDirs),
            timestamp: nil,
            quote: item.owner.map { "\($0): \(item.text)" } ?? item.text,
            date: item.date,
            datetime: item.datetime,
            kind: "commitment",
            person: item.owner
        )
    }
    return try handleReceiptQuery(query: person, range: range, toolKind: "commitments") {
        (receipts, indexed.truncated || indexed.items.count > count)
    }
}

func handleOpenQuestions(params: CallTool.Parameters, index: TranscriptIndex, meetingDirs: [URL]) throws -> CallTool.Result {
    let project = params.arguments?["project"]?.stringValue
    let range = parseToolRange(params.arguments?["range"]?.stringValue)
    let count = cappedCrossMeetingCount(params.arguments?["count"]?.intValue)
    let fetchLimit = project?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? 1000 : count + 1
    let indexed = try index.listSummaryItems(
        kind: TranscriptIndex.SummaryItemKind.openQuestion,
        dateFrom: range.dateFrom,
        dateTo: range.dateTo,
        limit: fetchLimit
    )
    let filtered = filterSummaryItems(indexed, matching: project)
    let receipts = filtered.prefix(count).map { item in
        CrossMeetingReceipt(
            meetingId: item.filename,
            meetingTitle: meetingTitle(for: item.filename, meetingDirs: meetingDirs),
            timestamp: nil,
            quote: item.text,
            date: item.meetingDate,
            datetime: item.meetingDateTime,
            kind: "open_question",
            person: nil
        )
    }
    return try handleReceiptQuery(query: project, range: range, toolKind: "open_questions") {
        (receipts, filtered.count > count)
    }
}

func handleSearchMeetings(params: CallTool.Parameters, index: TranscriptIndex, meetingDirs: [URL]) throws -> CallTool.Result {
    guard let query = params.arguments?["query"]?.stringValue, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return invalidAgentCaptureQueryInputResult("Missing required parameter: query")
    }

    let range = parseToolRange(params.arguments?["range"]?.stringValue)
    let count = cappedCrossMeetingCount(params.arguments?["count"]?.intValue)
    var groups = try index.searchUtterances(
        query: query,
        speaker: nil,
        dateFrom: range.dateFrom,
        dateTo: range.dateTo,
        maxMeetings: count,
        snippetsPerMeeting: 3
    )
    hydrateMeetingSearchTitles(in: &groups, meetingDirs: meetingDirs)

    let receipts = groups.results.flatMap { group in
        group.snippets.map { snippet in
            CrossMeetingReceipt(
                meetingId: group.filename,
                meetingTitle: group.meetingTitle,
                timestamp: snippet.timestamp,
                quote: snippet.text,
                date: group.meetingDate,
                datetime: group.meetingDateTime,
                kind: "utterance",
                person: snippet.speaker
            )
        }
    }
    return try handleReceiptQuery(query: query, range: range, toolKind: "search") {
        (Array(receipts.prefix(count)), groups.truncated || receipts.count > count)
    }
}

/// Shared tail for the four receipt-query tools above: wrap receipts in a
/// CrossMeetingToolResult, record the terminal telemetry outcome, and encode.
/// `fetchReceipts` returns the already-hydrated receipts (titles resolved,
/// count already capped) plus whether the underlying query was truncated by
/// its own limit.
private func handleReceiptQuery(
    query: String?,
    range: ParsedToolRange,
    toolKind: String,
    fetchReceipts: () throws -> (receipts: [CrossMeetingReceipt], truncated: Bool)
) throws -> CallTool.Result {
    let (receipts, truncated) = try fetchReceipts()
    let result = CrossMeetingToolResult(
        query: query,
        range: range.label,
        count: receipts.count,
        truncated: truncated,
        results: receipts
    )
    if receipts.isEmpty {
        markAgentCaptureQueryTerminal(.emptyNotFound, sourceCount: 0, resultCount: 0)
    } else {
        trackAgentCaptureQueryObserved(
            toolKind: toolKind,
            captureKind: "meeting",
            sourceCount: distinctReceiptSourceCount(in: receipts),
            resultCount: receipts.count
        )
    }
    return try encodedToolResult(result)
}

// MARK: - Helpers

private struct ParsedToolRange {
    let dateFrom: String?
    let dateTo: String?
    let label: String?
}

private func parseToolRange(_ raw: String?) -> ParsedToolRange {
    guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
        return ParsedToolRange(dateFrom: nil, dateTo: nil, label: nil)
    }
    let lower = raw.lowercased()
    if lower == "all" || lower == "all time" {
        return ParsedToolRange(dateFrom: nil, dateTo: nil, label: raw)
    }
    if lower == "today" {
        let today = DateFormatter.localYYYYMMDD.string(from: Date())
        return ParsedToolRange(dateFrom: today, dateTo: today, label: today)
    }

    let separators = ["..", " to ", " - "]
    for separator in separators where raw.contains(separator) {
        let parts = raw.components(separatedBy: separator).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if parts.count == 2 {
            let from = parts[0].isEmpty ? nil : parts[0]
            let to = parts[1].isEmpty ? nil : parts[1]
            return ParsedToolRange(dateFrom: from, dateTo: to, label: raw)
        }
    }

    return ParsedToolRange(dateFrom: raw, dateTo: raw, label: raw)
}

private func cappedCrossMeetingCount(_ raw: Int?) -> Int {
    max(1, min(raw ?? 20, 100))
}

private func filterSummaryItems(_ items: [TranscriptIndex.IndexedSummaryItem], matching query: String?) -> [TranscriptIndex.IndexedSummaryItem] {
    guard let query = query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
        return items
    }
    let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    guard !terms.isEmpty else { return items }
    return items.filter { item in
        let haystack = item.text.lowercased()
        return terms.allSatisfy { haystack.contains($0) }
    }
}

private func encodedToolResult<T: Encodable>(_ result: T) throws -> CallTool.Result {
    let json = try JSONEncoder.pretty.encode(result)
    return textResult(String(data: json, encoding: .utf8) ?? "{}")
}

private func distinctReceiptSourceCount(in results: [CrossMeetingReceipt]) -> Int {
    Set(results.map(\.meetingId)).count
}
