import XCTest
@testable import TranscriptedCore

/// Contract test for W3-A (audit 2026-07-08 wave 3): TranscriptFrontmatter is
/// one of three independent parsers of the same Markdown frontmatter shape
/// (see Tests/Fixtures/frontmatter-corpus/README.md for the other two and the
/// scope of the equivalence contract). This suite pins TranscriptFrontmatter's
/// behavior against the shared fixture corpus so any future edit that quietly
/// changes fence detection or flat-value parsing here — without a matching
/// change to CaptureMarkdownParser and TranscriptedMCP's frontmatterBlock —
/// fails CI instead of drifting silently.
final class FrontmatterCorpusParityTests: XCTestCase {
    private struct Golden: Decodable {
        let hasFrontmatter: Bool
        let body: String?
        let values: [String: String]?
    }

    private static var corpusDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // FrontmatterCorpusParityTests.swift
            .deletingLastPathComponent() // StorageTests
            .deletingLastPathComponent() // TranscriptedCoreTests
            .appendingPathComponent("Fixtures/frontmatter-corpus")
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

            let document = TranscriptFrontmatter.document(in: raw)

            if !golden.hasFrontmatter {
                XCTAssertNil(document, "\(name): TranscriptFrontmatter should not find a frontmatter document")
                continue
            }

            guard let document else {
                XCTFail("\(name): TranscriptFrontmatter failed to parse a fixture the corpus expects to have frontmatter")
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

    /// TranscriptFrontmatter is deliberately narrower than CaptureMarkdownParser
    /// — it does not flatten `- item` blocks or `[a, b]` inline lists. These
    /// assertions document that gap against the exact corpus fixtures built to
    /// exercise it, so the gap is a decision on record, not silent behavior.
    func testKnownDivergenceListKeysAreNotFlattened() throws {
        let blockListRaw = try String(
            contentsOf: Self.corpusDirectory.appendingPathComponent("07-list-block-scalars.md"),
            encoding: .utf8
        )
        let blockListValues = try XCTUnwrap(TranscriptFrontmatter.values(in: blockListRaw))
        // "tags:" splits on ":" with omittingEmptySubsequences (the default),
        // which drops the empty trailing component entirely — parts.count
        // is 1, not 2, so the key never enters the dictionary at all.
        XCTAssertNil(blockListValues["tags"], "block-list keys are dropped outright (empty value after \":\" splits to zero parts) — CaptureMarkdownParser flattens to \"transcripted, release\"")

        let inlineListRaw = try String(
            contentsOf: Self.corpusDirectory.appendingPathComponent("08-list-inline-brackets.md"),
            encoding: .utf8
        )
        let inlineListValues = try XCTUnwrap(TranscriptFrontmatter.values(in: inlineListRaw))
        XCTAssertEqual(inlineListValues["tags"], "[release, qa]", "inline-bracket keys keep their raw bracket text — CaptureMarkdownParser normalizes to \"release, qa\"")
    }
}
