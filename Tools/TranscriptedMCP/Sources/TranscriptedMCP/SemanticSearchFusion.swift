import Foundation

/// Combines lexical (FTS) and semantic (vector) result lists using Reciprocal
/// Rank Fusion. RRF is scale-free — it only uses each item's rank within its own
/// list, so it merges two scores (FTS `rank`, cosine similarity) that aren't
/// otherwise comparable without tuning weights.
///
/// Fusion happens at the grouped level (per meeting / per dictation entry), which
/// is the granularity the MCP API already returns. The result is a strict
/// superset of the lexical list's recall: any FTS hit keeps its snippets and
/// only gets reordered, while semantic-only matches are appended by score.
enum SemanticSearchFusion {
    /// Standard RRF damping constant. Larger = flatter contribution from rank.
    static let rrfK: Double = 60

    private static func rrf(_ rank: Int) -> Double { 1.0 / (rrfK + Double(rank)) }

    /// Fuse two meeting-grouped result sets.
    static func fuseGrouped(
        lexical: GroupedSearchResult,
        semantic: GroupedSearchResult,
        maxMeetings: Int,
        snippetsPerMeeting: Int
    ) -> GroupedSearchResult {
        var score: [String: Double] = [:]
        var lexByName: [String: MeetingSearchGroup] = [:]
        var semByName: [String: MeetingSearchGroup] = [:]
        var order: [String] = []

        for (rank, group) in lexical.results.enumerated() {
            score[group.filename, default: 0] += rrf(rank)
            if lexByName[group.filename] == nil { order.append(group.filename) }
            lexByName[group.filename] = group
        }
        for (rank, group) in semantic.results.enumerated() {
            score[group.filename, default: 0] += rrf(rank)
            if lexByName[group.filename] == nil, semByName[group.filename] == nil {
                order.append(group.filename)
            }
            semByName[group.filename] = group
        }

        let ranked = order.sorted { (score[$0] ?? 0) > (score[$1] ?? 0) }

        let fused: [MeetingSearchGroup] = ranked.compactMap { name in
            let base = lexByName[name] ?? semByName[name]
            guard let base else { return nil }
            let lexSnippets = lexByName[name]?.snippets ?? []
            let semSnippets = semByName[name]?.snippets ?? []
            let snippets = mergeSnippets(lexSnippets, semSnippets, limit: snippetsPerMeeting)
            return MeetingSearchGroup(
                meetingTitle: base.meetingTitle,
                meetingDate: base.meetingDate,
                meetingDateTime: base.meetingDateTime,
                filename: name,
                snippets: snippets
            )
        }

        let total = ranked.count
        return GroupedSearchResult(
            results: Array(fused.prefix(maxMeetings)),
            totalMeetingsMatched: total,
            truncated: total > maxMeetings
        )
    }

    /// Fuse two dictation/context result lists keyed by (filename, entry).
    static func fuseContextGroups(
        lexical: [ContextSearchGroup],
        semantic: [ContextSearchGroup],
        maxItems: Int
    ) -> [ContextSearchGroup] {
        func key(_ g: ContextSearchGroup) -> String { "\(g.filename)\u{1}\(g.entryId ?? "")" }

        var score: [String: Double] = [:]
        var byKey: [String: ContextSearchGroup] = [:]
        var order: [String] = []

        for (rank, group) in lexical.enumerated() {
            let k = key(group)
            score[k, default: 0] += rrf(rank)
            if byKey[k] == nil { order.append(k); byKey[k] = group }
        }
        for (rank, group) in semantic.enumerated() {
            let k = key(group)
            score[k, default: 0] += rrf(rank)
            if byKey[k] == nil { order.append(k); byKey[k] = group }
        }

        let ranked = order.sorted { (score[$0] ?? 0) > (score[$1] ?? 0) }
        let fused = ranked.compactMap { byKey[$0] }
        return Array(fused.prefix(maxItems))
    }

    /// Merge already-ranked per-kind lists (meetings, dictations, writing) by
    /// RRF over each item's rank within its own list. Items at the same rank in
    /// different lists tie; ties go to the newer item. Nothing is truncated.
    static func fuseRankedContextLists(_ lists: [[ContextSearchGroup]]) -> [ContextSearchGroup] {
        func key(_ g: ContextSearchGroup) -> String { "\(g.kind)\u{1}\(g.filename)\u{1}\(g.entryId ?? "")" }

        var score: [String: Double] = [:]
        var byKey: [String: ContextSearchGroup] = [:]
        var order: [String] = []

        for list in lists {
            for (rank, group) in list.enumerated() {
                let k = key(group)
                score[k, default: 0] += rrf(rank)
                if byKey[k] == nil { order.append(k); byKey[k] = group }
            }
        }

        // Swift's sort isn't stable, so first-seen order is the last tiebreak.
        let ranked = order.enumerated().sorted { a, b in
            let sa = score[a.element] ?? 0, sb = score[b.element] ?? 0
            if sa != sb { return sa > sb }
            let da = byKey[a.element]?.datetime ?? "", db = byKey[b.element]?.datetime ?? ""
            if da != db { return da > db }
            return a.offset < b.offset
        }
        return ranked.compactMap { byKey[$0.element] }
    }

    /// Lexical snippets first (they're exact matches), then any semantic snippet
    /// not already present, capped at `limit`. Dedupe on timestamp+text.
    private static func mergeSnippets(
        _ lexical: [SearchSnippet],
        _ semantic: [SearchSnippet],
        limit: Int
    ) -> [SearchSnippet] {
        var seen: Set<String> = []
        var out: [SearchSnippet] = []
        for snippet in lexical + semantic {
            guard out.count < limit else { break }
            let id = "\(snippet.timestamp)\u{1}\(snippet.text)"
            if seen.insert(id).inserted {
                out.append(snippet)
            }
        }
        return out
    }
}
