import XCTest
@testable import TranscriptedCaptureKit

/// Contract test for W3-A (audit 2026-07-08 wave 3): CaptureMarkdownParser is
/// one of three independent parsers of the same Markdown frontmatter shape
/// (see Tests/Fixtures/frontmatter-corpus/README.md at the repo root for the
/// other two and the scope of the equivalence contract). This suite pins
/// CaptureMarkdownParser's behavior against the shared fixture corpus so any
/// future edit that quietly changes fence detection or flat-value parsing
/// here — without a matching change to TranscriptFrontmatter and
/// TranscriptedMCP's frontmatterBlock — fails CI instead of drifting
/// silently.
final class FrontmatterCorpusParityTests: XCTestCase {
    private struct Golden: Decodable {
        let hasFrontmatter: Bool
        let body: String?
        let values: [String: String]?
    }

    private static var corpusDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // FrontmatterCorpusParityTests.swift
            .deletingLastPathComponent() // TranscriptedCaptureKitTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // TranscriptedCaptureKit
            .deletingLastPathComponent() // Tools
            .appendingPathComponent("Tests/Fixtures/frontmatter-corpus")
    }

    private static var fixtureNames: [String] {
        let fixturesDir = corpusDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: fixturesDir.path)) ?? []
        return names
            .filter { $0.hasSuffix(".md") }
            .map { String($0.dropLast(3)) }
            .sorted()
    }

    func testCorpusIsNonEmpty() {
        XCTAssertGreaterThanOrEqual(
            Self.fixtureNames.count, 15,
            "expected the shared frontmatter corpus to have at least 15 fixtures — see Tests/Fixtures/frontmatter-corpus/"
        )
    }

    func testEveryFixtureMatchesGoldenOutput() throws {
        let fixtureNames = Self.fixtureNames
        XCTAssertFalse(fixtureNames.isEmpty, "no fixtures found under \(Self.corpusDirectory.path)")

        for name in fixtureNames {
            let raw = try String(contentsOf: Self.corpusDirectory.appendingPathComponent("\(name).md"), encoding: .utf8)
            let goldenData = try Data(contentsOf: Self.corpusDirectory.appendingPathComponent("expected/\(name).json"))
            let golden = try JSONDecoder().decode(Golden.self, from: goldenData)

            let document = CaptureMarkdownParser.parseFrontmatter(from: raw)

            if !golden.hasFrontmatter {
                XCTAssertNil(document, "\(name): CaptureMarkdownParser should not find a frontmatter document")
                continue
            }

            guard let document else {
                XCTFail("\(name): CaptureMarkdownParser failed to parse a fixture the corpus expects to have frontmatter")
                continue
            }

            if let expectedBody = golden.body {
                XCTAssertEqual(document.body, expectedBody, "\(name): body must match exactly — this is the shared fence-detection contract")
            }

            for (key, expectedValue) in golden.values ?? [:] {
                XCTAssertEqual(document.values[key], expectedValue, "\(name): values[\"\(key)\"] diverged from the corpus contract")
            }
        }
    }

    /// CaptureMarkdownParser is deliberately the richer implementation — it
    /// flattens `- item` blocks and `[a, b]` inline lists where
    /// TranscriptFrontmatter leaves the key as an empty or raw-bracket
    /// scalar. These assertions document that gap against the exact corpus
    /// fixtures built to exercise it, so the gap is a decision on record,
    /// not silent behavior.
    func testKnownDivergenceListKeysAreFlattened() throws {
        let blockListRaw = try String(
            contentsOf: Self.corpusDirectory.appendingPathComponent("07-list-block-scalars.md"),
            encoding: .utf8
        )
        let blockListDocument = try XCTUnwrap(CaptureMarkdownParser.parseFrontmatter(from: blockListRaw))
        XCTAssertEqual(blockListDocument.values["tags"], "transcripted, release", "block-list keys flatten to a comma-joined list — TranscriptFrontmatter leaves them as an empty scalar")

        let inlineListRaw = try String(
            contentsOf: Self.corpusDirectory.appendingPathComponent("08-list-inline-brackets.md"),
            encoding: .utf8
        )
        let inlineListDocument = try XCTUnwrap(CaptureMarkdownParser.parseFrontmatter(from: inlineListRaw))
        XCTAssertEqual(inlineListDocument.values["tags"], "release, qa", "inline-bracket keys normalize to a comma-joined list — TranscriptFrontmatter keeps the raw bracket text")
    }

    /// `#`-prefixed comment lines are skipped outright here, even when they
    /// contain a colon. TranscriptFrontmatter has no comment skip, so a
    /// colon-bearing comment would be misread as a key/value pair there —
    /// a narrower, pre-existing gap this suite documents rather than papers
    /// over, since fixing it is out of scope for the parity contract.
    func testCommentLineWithColonIsIgnored() throws {
        let raw = """
        ---
        capture_type: meeting
        # a note: this line has a colon and must still be skipped
        title: "Comment With Colon"
        ---

        Body.
        """
        let document = try XCTUnwrap(CaptureMarkdownParser.parseFrontmatter(from: raw))
        XCTAssertEqual(document.values["capture_type"], "meeting")
        XCTAssertEqual(document.values["title"], "Comment With Colon")
        XCTAssertNil(document.values["# a note"])
    }
}
