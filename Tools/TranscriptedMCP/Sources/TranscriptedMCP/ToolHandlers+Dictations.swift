import Foundation
import MCP
import TranscriptedCaptureKit

// MARK: - list_dictations

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
        toolKind: "list",
        captureKind: "dictation",
        sourceCount: results.count,
        resultCount: results.count
    )

    let json = try JSONEncoder.pretty.encode(results)
    return textResult(String(data: json, encoding: .utf8) ?? "[]")
}

// MARK: - read_dictation

func handleReadDictation(params: CallTool.Parameters, dictationDirs: [URL]) throws -> CallTool.Result {
    guard let filename = params.arguments?["filename"]?.stringValue, !filename.isEmpty else {
        return invalidAgentCaptureQueryInputResult("Missing required parameter: filename")
    }

    let entryId = params.arguments?["entry_id"]?.stringValue
    let markdownURL: URL
    switch PathSecurity.resolveReadableFile(named: filename, appendingExtension: "md", in: dictationDirs) {
    case .valid(let url):
        markdownURL = url
    case .missing:
        return emptyOrMissingAgentCaptureQueryResult(
            "Dictation not found: \(filename). Use list_dictations to see available days.",
            isError: true
        )
    case .invalid:
        return invalidAgentCaptureQueryInputResult("Invalid filename: \(filename)")
    }

    guard let (day, content) = TranscriptLoader.loadDictationDayWithContent(markdownURL) else {
        return emptyOrMissingAgentCaptureQueryResult(
            "Dictation not found: \(filename). Use list_dictations to see available days.",
            isError: true
        )
    }

    if let entryId {
        guard let entry = day.entries.first(where: { $0.id == entryId }) else {
            return emptyOrMissingAgentCaptureQueryResult(
                "Entry not found: \(entryId). Use recent_context or search_context to inspect entry IDs.",
                isError: true
            )
        }

        trackAgentCaptureQueryObserved(
            toolKind: "read",
            captureKind: "dictation",
            sourceCount: 1,
            resultCount: 1
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

    let offset = max(0, params.arguments?["offset"]?.intValue ?? 0)
    let limit = params.arguments?["limit"]?.intValue
    let paginationRequested = limit != nil || offset > 0

    if !paginationRequested, content.count <= maxUnpaginatedReadCharacters {
        trackAgentCaptureQueryObserved(
            toolKind: "read",
            captureKind: "dictation",
            sourceCount: 1,
            resultCount: day.entries.count
        )
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
    trackAgentCaptureQueryObserved(
        toolKind: "read",
        captureKind: "dictation",
        sourceCount: 1,
        resultCount: returned
    )
    return textResult(String(data: json, encoding: .utf8) ?? "{}")
}
