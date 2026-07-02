import XCTest
@testable import transcripted_mcp

/// Deterministic embedding provider for tests. Maps a small fixed lexicon of
/// words to "concept" axes so paraphrases (different words, same concept) land on
/// the same vector and unrelated text stays orthogonal. This keeps the semantic
/// tests independent of whether the OS NLEmbedding assets are present in CI.
private struct StubEmbeddingProvider: EmbeddingProvider {
    let modelID: String
    var dimension: Int { concepts.count }
    var isAvailable: Bool { true }

    /// concept index -> member words
    private static let concepts: [[String]] = [
        ["cost", "pricing", "price", "expensive", "balked", "pushback", "budget"],
        ["weather", "sunny", "rain", "cloudy", "forecast"],
        ["roadmap", "plan", "timeline", "schedule", "milestone"],
    ]
    private let concepts = StubEmbeddingProvider.concepts

    private var lexicon: [String: Int] {
        var map: [String: Int] = [:]
        for (idx, words) in concepts.enumerated() {
            for word in words { map[word] = idx }
        }
        return map
    }

    init(modelID: String = "stub.v1") { self.modelID = modelID }

    func embed(_ text: String) -> [Float]? {
        let lex = lexicon
        var vec = [Float](repeating: 0, count: concepts.count)
        var hits = 0
        for token in text.lowercased().split(whereSeparator: { !$0.isLetter }) {
            if let idx = lex[String(token)] {
                vec[idx] += 1
                hits += 1
            }
        }
        guard hits > 0 else { return nil }
        return VectorMath.normalized(vec)
    }
}

private struct UnavailableEmbeddingProvider: EmbeddingProvider {
    let modelID = "unavailable"
    var dimension: Int { 0 }
    var isAvailable: Bool { false }
    func embed(_ text: String) -> [Float]? { nil }
}

final class SemanticSearchTests: XCTestCase {
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = makeTempDir()
    }

    override func tearDown() {
        removeTempDir(tempDir)
        super.tearDown()
    }

    private func makeIndex(_ provider: EmbeddingProvider? = StubEmbeddingProvider()) throws -> TranscriptIndex {
        try TranscriptIndex(indexDir: tempDir, embeddingProvider: provider)
    }

    // MARK: - The headline unlock: paraphrase queries hit

    func testSemanticFindsParaphraseThatLexicalMisses() throws {
        let index = try makeIndex()
        try writeFixture(makeFixtureJSON(utterances: [
            ("system_0", 0.0, 5.0, "Honestly they balked at the cost"),
            ("mic_0", 5.0, 10.0, "The weather is sunny today"),
        ]), filename: "Call_2026-03-29_10-00-00", to: tempDir)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        // Lexical alone misses the paraphrase: none of these words appear verbatim.
        let lexical = try index.searchUtterances(query: "pricing pushback", speaker: nil, dateFrom: nil, dateTo: nil, mode: .lexical)
        XCTAssertTrue(lexical.results.isEmpty)

        // Semantic matches the "cost" concept utterance, not the weather one.
        let semantic = try index.searchUtterances(query: "pricing pushback", speaker: nil, dateFrom: nil, dateTo: nil, mode: .semantic)
        XCTAssertEqual(semantic.results.count, 1)
        XCTAssertEqual(semantic.results[0].snippets.count, 1)
        XCTAssertTrue(semantic.results[0].snippets[0].text.contains("balked"))
    }

    // MARK: - Hybrid is a strict superset of lexical recall

    func testHybridUnionsLexicalAndSemantic() throws {
        let index = try makeIndex()
        // Meeting A contains the literal word "cost"; meeting B only paraphrases it.
        try writeFixture(makeFixtureJSON(date: "2026-03-29T10:00:00-0500", utterances: [
            ("system_0", 0.0, 5.0, "The cost was discussed at length"),
        ]), filename: "Call_2026-03-29_10-00-00", to: tempDir)
        try writeFixture(makeFixtureJSON(date: "2026-03-30T10:00:00-0500", utterances: [
            ("system_0", 0.0, 5.0, "They balked at the expensive pricing"),
        ]), filename: "Call_2026-03-30_10-00-00", to: tempDir)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let lexical = try index.searchUtterances(query: "cost", speaker: nil, dateFrom: nil, dateTo: nil, mode: .lexical)
        XCTAssertEqual(lexical.results.count, 1)
        XCTAssertEqual(lexical.results[0].filename, "Call_2026-03-29_10-00-00")

        let hybrid = try index.searchUtterances(query: "cost", speaker: nil, dateFrom: nil, dateTo: nil, mode: .hybrid)
        let filenames = Set(hybrid.results.map(\.filename))
        XCTAssertEqual(hybrid.results.count, 2)
        XCTAssertTrue(filenames.contains("Call_2026-03-29_10-00-00")) // exact hit preserved
        XCTAssertTrue(filenames.contains("Call_2026-03-30_10-00-00")) // paraphrase added
    }

    func testSemanticRespectsDateFilter() throws {
        let index = try makeIndex()
        try writeFixture(makeFixtureJSON(date: "2026-03-28T10:00:00-0500", utterances: [
            ("system_0", 0.0, 5.0, "They balked at the cost"),
        ]), filename: "Call_2026-03-28_10-00-00", to: tempDir)
        try writeFixture(makeFixtureJSON(date: "2026-03-30T10:00:00-0500", utterances: [
            ("system_0", 0.0, 5.0, "The pricing was too expensive"),
        ]), filename: "Call_2026-03-30_10-00-00", to: tempDir)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let semantic = try index.searchUtterances(query: "budget pushback", speaker: nil, dateFrom: "2026-03-29", dateTo: nil, mode: .semantic)
        XCTAssertEqual(semantic.results.count, 1)
        XCTAssertEqual(semantic.results[0].filename, "Call_2026-03-30_10-00-00")
    }

    func testSemanticDoesNotMatchUnrelatedConcept() throws {
        let index = try makeIndex()
        try writeFixture(makeFixtureJSON(utterances: [
            ("system_0", 0.0, 5.0, "The weather forecast looks cloudy"),
        ]), filename: "Call_2026-03-29_10-00-00", to: tempDir)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let semantic = try index.searchUtterances(query: "pricing pushback", speaker: nil, dateFrom: nil, dateTo: nil, mode: .semantic)
        XCTAssertTrue(semantic.results.isEmpty)
    }

    // MARK: - Dictation semantic search

    func testSemanticSearchOnDictationEntries() throws {
        let index = try makeIndex()
        try writeFixture(makeDictationDayJSON(entries: [
            ("dictation-20260407-091500-000", "2026-04-07T09:15:00-0500", "Budget note", "Client balked at the pricing again", "Slack", "copied"),
            ("dictation-20260407-181500-000", "2026-04-07T18:15:00-0500", "Weather note", "Tomorrow looks sunny and clear", "Notes", "copied"),
        ]), filename: "Dictations_2026-04-07", to: tempDir)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let results = try index.searchContext(query: "cost pushback", speaker: nil, kind: .dictation, dateFrom: nil, dateTo: nil, maxItems: 10, mode: .semantic)
        XCTAssertEqual(results.results.count, 1)
        XCTAssertEqual(results.results[0].kind, .dictation)
        XCTAssertTrue(results.results[0].snippets[0].text.contains("balked"))
    }

    // MARK: - Graceful degradation

    func testHybridFallsBackToLexicalWhenProviderUnavailable() throws {
        let index = try makeIndex(UnavailableEmbeddingProvider())
        XCTAssertNil(index.embeddingStore)

        try writeFixture(makeFixtureJSON(utterances: [
            ("system_0", 0.0, 5.0, "The cost was discussed"),
        ]), filename: "Call_2026-03-29_10-00-00", to: tempDir)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        // Hybrid with no backend must behave exactly like lexical, not error.
        let hybrid = try index.searchUtterances(query: "cost", speaker: nil, dateFrom: nil, dateTo: nil, mode: .hybrid)
        XCTAssertEqual(hybrid.results.count, 1)

        let paraphrase = try index.searchUtterances(query: "pricing pushback", speaker: nil, dateFrom: nil, dateTo: nil, mode: .hybrid)
        XCTAssertTrue(paraphrase.results.isEmpty) // no semantic recall without a backend
    }

    func testNoProviderLeavesSemanticDisabled() throws {
        let index = try TranscriptIndex(indexDir: tempDir) // default: no provider
        XCTAssertNil(index.embeddingStore)
        try writeFixture(makeFixtureJSON(utterances: [
            ("system_0", 0.0, 5.0, "The cost was discussed"),
        ]), filename: "Call_2026-03-29_10-00-00", to: tempDir)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let hybrid = try index.searchUtterances(query: "cost", speaker: nil, dateFrom: nil, dateTo: nil, mode: .hybrid)
        XCTAssertEqual(hybrid.results.count, 1)
    }

    // MARK: - Re-embedding on model change

    func testModelChangeReEmbeds() throws {
        // Index once with stub v1.
        let index1 = try makeIndex(StubEmbeddingProvider(modelID: "stub.v1"))
        try writeFixture(makeFixtureJSON(utterances: [
            ("system_0", 0.0, 5.0, "They balked at the cost"),
        ]), filename: "Call_2026-03-29_10-00-00", to: tempDir)
        try index1.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)
        XCTAssertEqual(try index1.searchUtterances(query: "pricing", speaker: nil, dateFrom: nil, dateTo: nil, mode: .semantic).results.count, 1)

        // Reopen with a different model id — vectors must be rebuilt, not stale.
        let index2 = try makeIndex(StubEmbeddingProvider(modelID: "stub.v2"))
        try index2.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)
        XCTAssertEqual(try index2.searchUtterances(query: "pricing", speaker: nil, dateFrom: nil, dateTo: nil, mode: .semantic).results.count, 1)
    }
}

// MARK: - Vector math + fusion unit tests

final class VectorMathTests: XCTestCase {
    func testBlobRoundTrip() {
        let v: [Float] = [0.1, -2.0, 3.5, 0.0, 42.25]
        let restored = VectorMath.vector(from: VectorMath.blob(from: v))
        XCTAssertEqual(restored, v)
    }

    func testNormalizedIsUnitLength() {
        let v = VectorMath.normalized([3, 4])
        XCTAssertEqual(VectorMath.dot(v, v), 1.0, accuracy: 1e-5)
    }

    func testDotOfOrthogonalIsZero() {
        let a = VectorMath.normalized([1, 0])
        let b = VectorMath.normalized([0, 1])
        XCTAssertEqual(VectorMath.dot(a, b), 0.0, accuracy: 1e-6)
    }

    func testZeroVectorNormalizeIsSafe() {
        XCTAssertEqual(VectorMath.normalized([0, 0, 0]), [0, 0, 0])
    }
}

final class SemanticSearchFusionTests: XCTestCase {
    private func meetingGroup(_ filename: String, snippetText: String = "x") -> MeetingSearchGroup {
        MeetingSearchGroup(
            meetingTitle: filename, meetingDate: "2026-03-29", meetingDateTime: "2026-03-29T10:00:00-0500",
            filename: filename,
            snippets: [SearchSnippet(speaker: "You", speakerId: nil, timestamp: "0:00", text: snippetText)]
        )
    }

    func testFusionPreservesLexicalAndAppendsSemanticOnly() {
        let lexical = GroupedSearchResult(results: [meetingGroup("A"), meetingGroup("B")], totalMeetingsMatched: 2, truncated: false)
        let semantic = GroupedSearchResult(results: [meetingGroup("B"), meetingGroup("C")], totalMeetingsMatched: 2, truncated: false)

        let fused = SemanticSearchFusion.fuseGrouped(lexical: lexical, semantic: semantic, maxMeetings: 10, snippetsPerMeeting: 3)
        let names = fused.results.map(\.filename)
        XCTAssertEqual(Set(names), ["A", "B", "C"])
        // B ranks in both lists, so it should fuse to the top.
        XCTAssertEqual(names.first, "B")
        XCTAssertEqual(fused.totalMeetingsMatched, 3)
    }

    func testFusionMergesSnippetsAndDedupes() {
        let lexical = GroupedSearchResult(results: [meetingGroup("A", snippetText: "shared")], totalMeetingsMatched: 1, truncated: false)
        let semantic = GroupedSearchResult(results: [
            MeetingSearchGroup(
                meetingTitle: "A", meetingDate: "2026-03-29", meetingDateTime: "2026-03-29T10:00:00-0500",
                filename: "A",
                snippets: [
                    SearchSnippet(speaker: "You", speakerId: nil, timestamp: "0:00", text: "shared"),
                    SearchSnippet(speaker: "You", speakerId: nil, timestamp: "1:00", text: "unique"),
                ]
            )
        ], totalMeetingsMatched: 1, truncated: false)

        let fused = SemanticSearchFusion.fuseGrouped(lexical: lexical, semantic: semantic, maxMeetings: 10, snippetsPerMeeting: 3)
        XCTAssertEqual(fused.results.count, 1)
        let texts = fused.results[0].snippets.map(\.text)
        XCTAssertEqual(texts, ["shared", "unique"]) // dedup on (timestamp,text), lexical first
    }

    func testFusionRespectsSnippetCap() {
        let many = (0..<5).map { SearchSnippet(speaker: "You", speakerId: nil, timestamp: "\($0):00", text: "s\($0)") }
        let lexical = GroupedSearchResult(results: [
            MeetingSearchGroup(meetingTitle: "A", meetingDate: "d", meetingDateTime: "dt", filename: "A", snippets: many)
        ], totalMeetingsMatched: 1, truncated: false)
        let fused = SemanticSearchFusion.fuseGrouped(lexical: lexical, semantic: GroupedSearchResult(results: [], totalMeetingsMatched: 0, truncated: false), maxMeetings: 10, snippetsPerMeeting: 2)
        XCTAssertEqual(fused.results[0].snippets.count, 2)
    }

    func testContextFusionUnionsByEntry() {
        func group(_ file: String, _ entry: String) -> ContextSearchGroup {
            ContextSearchGroup(kind: .dictation, title: entry, filename: file, entryId: entry, date: "2026-04-07", datetime: "2026-04-07T09:00:00-0500", snippets: [])
        }
        let lexical = [group("D", "e1")]
        let semantic = [group("D", "e1"), group("D", "e2")]
        let fused = SemanticSearchFusion.fuseContextGroups(lexical: lexical, semantic: semantic, maxItems: 10)
        XCTAssertEqual(fused.count, 2)
        XCTAssertEqual(fused.first?.entryId, "e1") // appears in both -> top
    }
}
