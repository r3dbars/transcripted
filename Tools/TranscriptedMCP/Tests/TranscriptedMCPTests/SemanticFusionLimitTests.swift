import Foundation

#if MCP_FUSION_COMPONENT_TEST
import Darwin
#else
import XCTest
@testable import transcripted_mcp
#endif

private enum FusionFixtureFailure: Error { case mismatch(String) }

/// Pure value inputs: no index, embedding provider, server or user library.
private func runFusionLimitCases() throws -> Int {
    var assertions = 0
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        assertions += 1
        guard condition() else { throw FusionFixtureFailure.mismatch(message) }
    }
    func meeting(_ id: String, snippets: [SearchSnippet]? = nil) -> MeetingSearchGroup {
        MeetingSearchGroup(meetingTitle: id, meetingDate: "2026-01-01",
            meetingDateTime: "2026-01-01T00:00:00Z", filename: id,
            snippets: snippets ?? [snippet(id)])
    }
    func snippet(_ text: String) -> SearchSnippet {
        SearchSnippet(speaker: "Synthetic", speakerId: nil, timestamp: "0:00", text: text)
    }
    func result(_ groups: [MeetingSearchGroup]) -> GroupedSearchResult {
        GroupedSearchResult(results: groups, totalMeetingsMatched: groups.count, truncated: false)
    }
    func context(_ id: String, entry: String? = nil) -> ContextSearchGroup {
        ContextSearchGroup(kind: .dictation, title: id, filename: id, entryId: entry,
            date: "2026-01-01", datetime: "2026-01-01T00:00:00Z", snippets: [])
    }
    let lexical = (0..<6).map { meeting("L\($0)") }
    let semantic = (0..<6).map { meeting("S\($0)") }
    let limited = SemanticSearchFusion.fuseGrouped(lexical: result(lexical),
        semantic: result(semantic), maxMeetings: 6, snippetsPerMeeting: 3)
    try expect(limited.results.map(\.filename) == ["L0", "S0", "L1", "S1", "L2", "S2"],
        "Meeting fusion ranks both sources and keeps first-seen order on equal scores")
    try expect(!limited.results.contains { $0.filename == "L5" },
        "A lower-ranked lexical candidate can fall outside the final limit")
    try expect(limited.totalMeetingsMatched == 12 && limited.truncated,
        "Meeting fusion reports the candidate union before truncation")
    let full = SemanticSearchFusion.fuseGrouped(lexical: result(lexical),
        semantic: result(semantic), maxMeetings: 12, snippetsPerMeeting: 3)
    try expect(Set(full.results.map(\.filename)) == Set((lexical + semantic).map(\.filename)),
        "Sufficient capacity retains every candidate from both input lists")
    try expect(!full.truncated, "A fitting union is not marked truncated")

    let overlapping = SemanticSearchFusion.fuseGrouped(
        lexical: result([meeting("A"), meeting("B")]),
        semantic: result([meeting("B"), meeting("C")]), maxMeetings: 1, snippetsPerMeeting: 3)
    try expect(overlapping.results.map(\.filename) == ["B"],
        "A candidate found in both sources outranks a single-source candidate")
    let merged = SemanticSearchFusion.fuseGrouped(
        lexical: result([meeting("A", snippets: [snippet("shared"), snippet("exact")])]),
        semantic: result([meeting("A", snippets: [snippet("shared"), snippet("paraphrase")])]),
        maxMeetings: 1, snippetsPerMeeting: 2)
    try expect(merged.results.first?.snippets.map(\.text) == ["shared", "exact"],
        "Returned meetings keep lexical snippets first within the snippet limit")

    let contextLimited = SemanticSearchFusion.fuseContextGroups(
        lexical: (0..<6).map { context("L\($0)") },
        semantic: (0..<6).map { context("S\($0)") }, maxItems: 6)
    try expect(contextLimited.map(\.filename) == ["L0", "S0", "L1", "S1", "L2", "S2"],
        "Context fusion ranks and caps the union with first-seen equal-score order")
    let entries = SemanticSearchFusion.fuseContextGroups(
        lexical: [context("D", entry: "one"), context("D", entry: "two")],
        semantic: [context("D", entry: "two")], maxItems: 3)
    try expect(entries.compactMap(\.entryId) == ["two", "one"],
        "A repeated entry ranks once while different entries in one file remain distinct")
    let empty = SemanticSearchFusion.fuseGrouped(lexical: result(lexical),
        semantic: result(semantic), maxMeetings: 0, snippetsPerMeeting: 3)
    try expect(empty.results.isEmpty && empty.totalMeetingsMatched == 12 && empty.truncated,
        "Zero meeting capacity returns no rows while retaining candidate metadata")
    try expect(SemanticSearchFusion.fuseContextGroups(lexical: [context("D")],
        semantic: [], maxItems: 0).isEmpty, "Zero context capacity returns no rows")
    return assertions
}

#if MCP_FUSION_COMPONENT_TEST
/// Link-only sentinel for the unexercised cross-kind method in the same source
/// file. Any accidental parser use fails; this fixture covers within-kind RRF.
struct RecentContextInstantParser {
    init(timeZone: TimeZone) { fatalError("Parser is outside this pure fixture") }
    func date(from value: String) -> Date? { fatalError("Parser is outside this pure fixture") }
}

@main
struct SemanticFusionLimitFixture {
    static func main() {
        do {
            let assertions = try runFusionLimitCases()
            print("PASS: \(assertions) pure fusion assertions")
        } catch {
            print("FAIL: \(error)")
            exit(1)
        }
    }
}
#else
final class SemanticFusionLimitTests: XCTestCase {
    func testHybridCandidateRankingAndLimits() throws {
        XCTAssertEqual(try runFusionLimitCases(), 11)
    }
}
#endif
