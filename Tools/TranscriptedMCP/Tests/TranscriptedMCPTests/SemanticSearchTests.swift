import XCTest
@testable import transcripted_mcp

/// Retrieval mechanics for semantic search: chunking, index round-trip, cosine
/// ranking, kind/date filters, reindex cleanup, and model-unavailable fallback.
/// Uses a deterministic bag-of-words embedding so tests never depend on the
/// Apple NLEmbedding asset being present on the runner.
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

    private func makeIndex(embedding: SemanticTextEmbedding = WordHashEmbedding()) throws -> TranscriptIndex {
        try TranscriptIndex(indexDir: tempDir, embedding: embedding)
    }

    func testIndexesAndRanksMeetingChunksByCosineSimilarity() throws {
        let index = try makeIndex()
        try writeFixture(
            makeFixtureJSON(
                title: "Pricing Sync",
                date: "2026-04-10T10:00:00-0500",
                utterances: [
                    ("mic_0", 0.0, 5.0, "The customer pushed back hard on pricing during the call"),
                ]
            ),
            filename: "Call_2026-04-10_10-00-00",
            to: tempDir
        )
        try writeFixture(
            makeFixtureJSON(
                title: "Office Chat",
                date: "2026-04-11T10:00:00-0500",
                utterances: [
                    ("mic_0", 0.0, 5.0, "Unrelated chatter about the office coffee machine"),
                ]
            ),
            filename: "Call_2026-04-11_10-00-00",
            to: tempDir
        )
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let hits = try XCTUnwrap(try index.semanticSearch(
            query: "pricing pushback from the customer",
            kind: "meeting",
            dateFrom: nil,
            dateTo: nil
        ))
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits.first?.filename, "Call_2026-04-10_10-00-00")
        XCTAssertTrue(hits.first?.text.contains("pushed back") ?? false)
        XCTAssertGreaterThan(hits[0].score, hits[1].score)
    }

    func testKindAndDateFiltersApply() throws {
        let index = try makeIndex()
        try writeFixture(
            makeFixtureJSON(
                date: "2026-04-10T10:00:00-0500",
                utterances: [("mic_0", 0.0, 5.0, "We reviewed the quarterly budget numbers")]
            ),
            filename: "Call_2026-04-10_10-00-00",
            to: tempDir
        )
        try writeFixture(
            makeDictationDayJSON(
                date: "2026-05-01",
                markdownFilename: "Dictations_2026-05-01.md",
                entries: [
                    (id: "dictation-20260501-091500-000", createdAt: "2026-05-01T09:15:00-0500", title: "Note", text: "Remember the budget follow-up email", sourceAppName: "Mail", delivery: "pasted"),
                ]
            ),
            filename: "Dictations_2026-05-01",
            to: tempDir
        )
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let meetingsOnly = try XCTUnwrap(try index.semanticSearch(
            query: "budget", kind: "meeting", dateFrom: nil, dateTo: nil
        ))
        XCTAssertTrue(meetingsOnly.allSatisfy { $0.kind == "meeting" })
        XCTAssertFalse(meetingsOnly.isEmpty)

        let dictationsOnly = try XCTUnwrap(try index.semanticSearch(
            query: "budget", kind: "dictation", dateFrom: nil, dateTo: nil
        ))
        XCTAssertTrue(dictationsOnly.allSatisfy { $0.kind == "dictation" })
        XCTAssertFalse(dictationsOnly.isEmpty)

        let windowed = try XCTUnwrap(try index.semanticSearch(
            query: "budget", kind: nil, dateFrom: "2026-04-01", dateTo: "2026-04-30"
        ))
        XCTAssertTrue(windowed.allSatisfy { $0.date.hasPrefix("2026-04") })
    }

    func testReindexReplacesSemanticChunks() throws {
        let index = try makeIndex()
        let filename = "Call_2026-04-10_10-00-00"
        try writeFixture(
            makeFixtureJSON(
                date: "2026-04-10T10:00:00-0500",
                utterances: [("mic_0", 0.0, 5.0, "Original topic about kubernetes migration")]
            ),
            filename: filename,
            to: tempDir
        )
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        try writeFixture(
            makeFixtureJSON(
                date: "2026-04-10T10:00:00-0500",
                utterances: [("mic_0", 0.0, 5.0, "Replaced topic about hiring plans")]
            ),
            filename: filename,
            to: tempDir
        )
        let url = tempDir.appendingPathComponent("\(filename).md")
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)],
            ofItemAtPath: url.path
        )
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let stale = try XCTUnwrap(try index.semanticSearch(
            query: "kubernetes migration", kind: nil, dateFrom: nil, dateTo: nil
        ))
        XCTAssertFalse(
            stale.contains { $0.text.contains("kubernetes") },
            "reindex must replace, not accumulate, semantic chunks"
        )
    }

    func testUnavailableEmbeddingReturnsNilNotEmpty() throws {
        let index = try makeIndex(embedding: UnavailableEmbedding())
        try writeFixture(makeFixtureJSON(), filename: "Call_2026-03-29_10-00-00", to: tempDir)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        XCTAssertNil(
            try index.semanticSearch(query: "anything", kind: nil, dateFrom: nil, dateTo: nil),
            "an unavailable model must be distinguishable from zero matches"
        )
    }

    func testChunkerGroupsAndCaps() {
        let chunks = SemanticChunker.chunks(
            from: ["short one", "short two", String(repeating: "x", count: 900)],
            maxCharacters: 40
        )
        XCTAssertFalse(chunks.isEmpty)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 40 })
        XCTAssertEqual(chunks.first, "short one short two")
    }

    func testVectorCodecRoundTrip() {
        let vector: [Float] = [0.6, 0.8, 0.0]
        let decoded = SemanticVectorCodec.decode(SemanticVectorCodec.encode(vector))
        XCTAssertEqual(decoded, vector)
        XCTAssertEqual(SemanticVectorCodec.cosine(vector, vector), 1.0, accuracy: 0.0001)
    }
}

// MARK: - Test embeddings

/// Deterministic bag-of-words embedding: each word hashes (FNV-1a, stable
/// across processes) to one of `dimension` axes. Shared words → higher cosine.
struct WordHashEmbedding: SemanticTextEmbedding {
    let isAvailable = true
    let dimension = 32

    func normalizedVector(for text: String) -> [Float]? {
        var counts = [Float](repeating: 0, count: dimension)
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        guard !words.isEmpty else { return nil }
        for word in words {
            counts[Int(fnv1a(String(word)) % UInt64(dimension))] += 1
        }
        return SemanticVectorCodec.normalize(counts)
    }

    private func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}

struct UnavailableEmbedding: SemanticTextEmbedding {
    let isAvailable = false
    let dimension = 0
    func normalizedVector(for text: String) -> [Float]? { nil }
}
