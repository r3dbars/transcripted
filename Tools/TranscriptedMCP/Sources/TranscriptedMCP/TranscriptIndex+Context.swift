import Foundation
import SQLite3
import TranscriptedCaptureKit

// Cross-kind context (search and recent feed across meetings, dictations,
// and writing) plus the row counts behind the status tool. Split out of
// TranscriptIndex.swift; every query keeps its own queue.sync.

extension TranscriptIndex {
    // MARK: - Index counts (status tool + self-describing empty results)

    /// Row counts across the derived tables so agents can tell an unindexed
    /// library apart from a query that matched nothing.
    struct IndexCounts {
        let meetings: Int
        let dictationDays: Int
        let dictationEntries: Int
        let writingDays: Int
        let writingEntries: Int
        let summaryItems: Int
        let summarizedMeetings: Int
    }

    func counts() throws -> IndexCounts {
        try queue.sync {
            IndexCounts(
                meetings: try scalarCount("SELECT COUNT(*) FROM meetings"),
                dictationDays: try scalarCount("SELECT COUNT(*) FROM dictation_days"),
                dictationEntries: try scalarCount("SELECT COUNT(*) FROM dictation_entries"),
                writingDays: try scalarCount("SELECT COUNT(*) FROM writing_days"),
                writingEntries: try scalarCount("SELECT COUNT(*) FROM writing_entries"),
                summaryItems: try scalarCount("SELECT COUNT(*) FROM meeting_summary_items"),
                summarizedMeetings: try scalarCount("SELECT COUNT(DISTINCT filename) FROM meeting_summary_items")
            )
        }
    }

    /// Single-value COUNT query. Must run inside `queue.sync`.
    private func scalarCount(_ sql: String) throws -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MCPIndexError.queryFailed(dbError())
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw MCPIndexError.queryFailed(dbError())
        }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    func searchContext(query: String, speaker: String?, kind: ContextKind, dateFrom: String?, dateTo: String?, maxItems: Int = 10, mode: SearchMode = .lexical) throws -> ContextSearchResult {
        // One relevance-ranked list per kind. Every per-kind search ranks by
        // relevance in every mode (FTS rank, cosine, or their RRF), so the lists
        // are merged by rank, never by date.
        var rankedLists: [[ContextSearchGroup]] = []

        if kind.includes(.meeting) {
            let meetings = try searchUtterances(
                query: query,
                speaker: speaker,
                dateFrom: dateFrom,
                dateTo: dateTo,
                maxMeetings: maxItems,
                snippetsPerMeeting: 3,
                mode: mode
            )
            rankedLists.append(meetings.results.map {
                ContextSearchGroup(
                    kind: .meeting,
                    title: $0.meetingTitle,
                    filename: $0.filename,
                    entryId: nil,
                    date: $0.meetingDate,
                    datetime: $0.meetingDateTime,
                    snippets: $0.snippets.map {
                        ContextSearchSnippet(
                            text: $0.text,
                            speaker: $0.speaker,
                            speakerId: $0.speakerId,
                            timestamp: $0.timestamp,
                            sourceAppName: nil,
                            delivery: nil
                        )
                    }
                )
            })
        }

        if kind.includes(.dictation), speaker == nil {
            rankedLists.append(try searchDictationEntries(
                query: query,
                dateFrom: dateFrom,
                dateTo: dateTo,
                maxItems: maxItems,
                mode: mode
            ))
        }

        // Writing has no speakers, so a speaker filter skips it like dictations.
        if kind.includes(.writing), speaker == nil {
            rankedLists.append(try searchWritingEntries(
                query: query,
                dateFrom: dateFrom,
                dateTo: dateTo,
                maxItems: maxItems
            ))
        }

        // BM25 and cosine scores aren't comparable across kinds, so fuse by
        // each item's rank within its own list.
        let combined = SemanticSearchFusion.fuseRankedContextLists(rankedLists)
        let total = combined.count

        return ContextSearchResult(
            results: Array(combined.prefix(maxItems)),
            totalItemsMatched: total,
            truncated: total > maxItems
        )
    }

    func listRecentContext(kind: ContextKind, count: Int, dateFrom: String? = nil, dateTo: String? = nil) throws -> RecentContextResult {
        var items: [RecentContextItem] = []

        if kind.includes(.meeting) {
            let meetings = try queryMeetings(
                count: count,
                dateFrom: dateFrom,
                dateTo: dateTo,
                includeFirstUtterance: true
            )
            items.append(contentsOf: meetings.map {
                let meeting = $0.summary
                let firstUtterance = $0.firstUtterance
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return RecentContextItem(
                    kind: .meeting,
                    title: meeting.title ?? meeting.filename,
                    filename: meeting.filename,
                    entryId: nil,
                    date: meeting.date,
                    datetime: meeting.datetime,
                    preview: firstUtterance.isEmpty ? "No transcript captured." : String(firstUtterance.prefix(220)),
                    wordCount: meeting.wordCount,
                    speakers: uniqueSpeakerNames(from: meeting.speakers.map(\.name)),
                    sourceAppName: nil,
                    delivery: nil
                )
            })
        }

        if kind.includes(.dictation) {
            items.append(contentsOf: try listRecentDictationEntries(count: count, dateFrom: dateFrom, dateTo: dateTo))
        }

        if kind.includes(.writing) {
            items.append(contentsOf: try listRecentWritingEntries(count: count, dateFrom: dateFrom, dateTo: dateTo))
        }

        items.sort { $0.datetime > $1.datetime }
        return RecentContextResult(items: Array(items.prefix(max(1, min(count, 50)))))
    }

    private func uniqueSpeakerNames(from names: [String]) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []

        for name in names {
            let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
            ordered.append(name)
        }

        return ordered
    }
}
