import Foundation
import MCP
import TranscriptedCaptureKit

// MARK: - recap

func handleRecap(params: CallTool.Parameters, index: TranscriptIndex, meetingDirs: [URL]) throws -> CallTool.Result {
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
        guard case .valid(let mdURL) = PathSecurity.resolveReadableFile(
            named: meeting.filename,
            appendingExtension: "md",
            in: meetingDirs
        ) else { continue }
        var preview = ""
        var title = meeting.filename
        var decisions: [String] = []
        var actionItems: [RecapActionItem] = []
        var openQuestions: [String] = []
        var summarySource = "transcript_fallback"

        if let content = CaptureMarkdown.readBoundedContents(of: mdURL) {
            title = extractTitle(from: content) ?? meeting.filename
            if let summary = TranscriptLoader.loadMeetingSummary(forTranscript: mdURL) {
                title = summary.title ?? title
                decisions = summary.decisions
                actionItems = summary.actionItems.map {
                    RecapActionItem(owner: $0.owner, text: $0.text, status: $0.status, due: $0.due)
                }
                openQuestions = summary.openQuestions
                let hasStructuredFacts = !decisions.isEmpty || !actionItems.isEmpty || !openQuestions.isEmpty
                if hasStructuredFacts {
                    preview = summaryPreview(decisions: decisions, actionItems: actionItems, openQuestions: openQuestions)
                    summarySource = "summary"
                } else {
                    preview = extractDialogueLines(from: content).prefix(15).joined(separator: "\n")
                }
            } else {
                preview = extractDialogueLines(from: content).prefix(15).joined(separator: "\n")
            }
        }

        recapParts.append(RecapEntry(
            filename: meeting.filename,
            title: title,
            date: meeting.date,
            datetime: meeting.datetime,
            durationFormatted: formatDuration(meeting.durationSeconds),
            speakers: meeting.speakers.map { $0.name },
            wordCount: meeting.wordCount,
            preview: preview,
            decisions: decisions,
            actionItems: actionItems,
            openQuestions: openQuestions,
            summarySource: summarySource
        ))
    }

    let result = RecapResult(
        dateRange: dateFrom == dateTo ? dateFrom : "\(dateFrom) to \(dateTo)",
        meetingCount: recapParts.count,
        meetings: recapParts
    )

    if recapParts.isEmpty {
        markAgentCaptureQueryTerminal(.emptyNotFound, sourceCount: 0, resultCount: 0)
    } else {
        trackAgentCaptureQueryObserved(
            toolKind: "recap",
            captureKind: "meeting",
            sourceCount: recapParts.count,
            resultCount: recapParts.count
        )
    }

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

    trackAgentCaptureQueryObserved(
        toolKind: "action_items",
        captureKind: "meeting",
        sourceCount: distinctActionItemSourceCount(in: result.items),
        resultCount: result.items.count
    )

    let json = try JSONEncoder.pretty.encode(result)
    return textResult(String(data: json, encoding: .utf8) ?? "{}")
}

func handleListDecisions(params: CallTool.Parameters, index: TranscriptIndex, meetingDirs: [URL]) throws -> CallTool.Result {
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

    trackAgentCaptureQueryObserved(
        toolKind: "decisions",
        captureKind: "meeting",
        sourceCount: distinctDecisionSourceCount(in: result.decisions),
        resultCount: result.decisions.count
    )

    let json = try JSONEncoder.pretty.encode(result)
    return textResult(String(data: json, encoding: .utf8) ?? "{}")
}

func handleDigest(params: CallTool.Parameters, index: TranscriptIndex, meetingDirs: [URL]) throws -> CallTool.Result {
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

    trackAgentCaptureQueryObserved(
        toolKind: "digest",
        captureKind: "meeting",
        sourceCount: Set(result.meetings.map(\.filename)).count,
        resultCount: result.meetings.count
    )

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
    let decisions: [String]
    let actionItems: [RecapActionItem]
    let openQuestions: [String]
    let summarySource: String
}

struct RecapActionItem: Codable, Equatable {
    let owner: String?
    let text: String
    let status: String?
    let due: String?

    init(owner: String?, text: String, status: String? = nil, due: String? = nil) {
        self.owner = owner
        self.text = text
        self.status = status
        self.due = due
    }
}

struct RecapResult: Codable {
    let dateRange: String
    let meetingCount: Int
    let meetings: [RecapEntry]
}

// MARK: - Helpers

private func formatDuration(_ seconds: Int) -> String {
    let h = seconds / 3600
    let m = (seconds % 3600) / 60
    if h > 0 { return "\(h)h \(m)m" }
    return "\(m)m"
}

private func summaryPreview(
    decisions: [String],
    actionItems: [RecapActionItem],
    openQuestions: [String]
) -> String {
    var sections: [String] = []
    appendSummarySection("Decisions", decisions, to: &sections)
    appendSummarySection(
        "Action Items",
        actionItems.map { item in
            if let owner = item.owner, !owner.isEmpty {
                return "\(owner): \(item.text)"
            }
            return item.text
        },
        to: &sections
    )
    appendSummarySection("Open Questions", openQuestions, to: &sections)
    return sections.joined(separator: "\n\n")
}

private func appendSummarySection(_ title: String, _ items: [String], to sections: inout [String]) {
    guard !items.isEmpty else { return }
    let body = items.map { "- \($0)" }.joined(separator: "\n")
    sections.append("## \(title)\n\(body)")
}

private func distinctActionItemSourceCount(in results: [ActionItemRecord]) -> Int {
    Set(results.map(\.filename)).count
}

private func distinctDecisionSourceCount(in results: [DecisionRecord]) -> Int {
    Set(results.map(\.filename)).count
}
