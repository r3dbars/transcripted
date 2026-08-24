import XCTest
import TranscriptedCaptureKit
@testable import transcripted_mcp

/// Contract test for W3-A (audit 2026-07-08 wave 3): `frontmatterBlock(of:)`
/// is the third of three independent parsers of the same Markdown
/// frontmatter shape (see Tests/Fixtures/frontmatter-corpus/README.md at the
/// repo root for the other two and the scope of the equivalence contract).
///
/// Unlike the other two, `frontmatterBlock` returns the raw fenced text
/// (not parsed values), and by long-standing contract includes one extra
/// character past the closing fence (see its doc comment). Rather than
/// duplicate a body-string golden here, this suite ties `frontmatterBlock`
/// directly to `CaptureMarkdownParser.parseFrontmatter` — the package this
/// target already depends on — via a reconstruction invariant: the block
/// plus everything but the first character of CaptureMarkdownParser's body
/// must reassemble the original file exactly. If MCP's fence detection ever
/// diverges from CaptureKit's, this invariant breaks.
final class FrontmatterCorpusParityTests: XCTestCase {
    /// `frontmatterBlock` requires only `hasPrefix("---")` and searches for
    /// the closing fence starting at offset 3; `TranscriptFrontmatter` and
    /// `CaptureMarkdownParser` both require `hasPrefix("---\n")` and search
    /// from offset 4. For a frontmatter block that closes immediately
    /// (`"---\n---\n"`, zero key lines), the opening fence's own trailing
    /// newline is itself index 3 — inside frontmatterBlock's search range
    /// but outside the other two's — so frontmatterBlock finds a fence they
    /// don't. This is pre-existing production behavior (not introduced by
    /// this audit) and out of scope to change here; see
    /// testEmptyFrontmatterBlockDivergence below.
    private static let knownDivergentFixtures: Set<String> = ["05-empty-frontmatter-block"]

    private static var corpusDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // FrontmatterCorpusParityTests.swift
            .deletingLastPathComponent() // TranscriptedMCPTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // TranscriptedMCP
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

    func testFrontmatterBlockAgreesWithCaptureMarkdownParserOnEveryFixture() throws {
        let fixtureNames = Self.fixtureNames
        XCTAssertFalse(fixtureNames.isEmpty, "no fixtures found under \(Self.corpusDirectory.path)")

        for name in fixtureNames where !Self.knownDivergentFixtures.contains(name) {
            let raw = try String(contentsOf: Self.corpusDirectory.appendingPathComponent("\(name).md"), encoding: .utf8)

            let block = frontmatterBlock(of: raw)
            let parsedDocument = CaptureMarkdownParser.parseFrontmatter(from: raw)

            guard let parsedDocument else {
                XCTAssertNil(block, "\(name): frontmatterBlock found a fence CaptureMarkdownParser did not")
                continue
            }

            guard let block else {
                XCTFail("\(name): CaptureMarkdownParser found a fence frontmatterBlock did not")
                continue
            }

            // frontmatterBlock keeps one extra character past the closing
            // fence (see its doc comment); parsedDocument.body starts
            // exactly there. Dropping that duplicated boundary character
            // from the body and concatenating must reassemble the file.
            XCTAssertEqual(
                block + parsedDocument.body.dropFirst(),
                raw,
                "\(name): frontmatterBlock + CaptureMarkdownParser body must reassemble the original file"
            )
        }
    }

    /// Pins the same golden bodies the other two packages assert against,
    /// so the three-way contract is visible from every corner: frontmatterBlock's
    /// prefix (minus its one trailing overlap character) must equal the
    /// golden body's prefix through the fence boundary too.
    func testFrontmatterBlockMatchesGoldenBodyBoundary() throws {
        struct Golden: Decodable {
            let hasFrontmatter: Bool
            let body: String?
        }

        for name in Self.fixtureNames where !Self.knownDivergentFixtures.contains(name) {
            let raw = try String(contentsOf: Self.corpusDirectory.appendingPathComponent("\(name).md"), encoding: .utf8)
            let goldenData = try Data(contentsOf: Self.corpusDirectory.appendingPathComponent("expected/\(name).json"))
            let golden = try JSONDecoder().decode(Golden.self, from: goldenData)

            let block = frontmatterBlock(of: raw)

            guard golden.hasFrontmatter, let expectedBody = golden.body else {
                XCTAssertNil(block, "\(name): frontmatterBlock found a fence the corpus expects none for")
                continue
            }

            guard let block else {
                XCTFail("\(name): frontmatterBlock failed to parse a fixture the corpus expects to have frontmatter")
                continue
            }

            XCTAssertEqual(block + expectedBody.dropFirst(), raw, "\(name): frontmatterBlock does not agree with the golden body boundary")
        }
    }

    /// Documents the pre-existing frontmatterBlock/CaptureMarkdownParser
    /// divergence on an immediately-closing frontmatter block (see
    /// `knownDivergentFixtures` above). Not a regression from this audit —
    /// recorded so it stays a decision on record instead of a silent gap.
    func testEmptyFrontmatterBlockDivergence() throws {
        let raw = try String(
            contentsOf: Self.corpusDirectory.appendingPathComponent("05-empty-frontmatter-block.md"),
            encoding: .utf8
        )

        XCTAssertNil(CaptureMarkdownParser.parseFrontmatter(from: raw), "CaptureMarkdownParser requires \"---\\n\" and searches for the closing fence from offset 4, so it treats the opening fence's own newline as unavailable to start the close match")
        XCTAssertEqual(frontmatterBlock(of: raw), "---\n---\n\n", "frontmatterBlock requires only \"---\" and searches from offset 3, so it matches the closing fence one character earlier than CaptureMarkdownParser/TranscriptFrontmatter do")
    }

    /// A file whose closing fence is the last thing in it used to trap:
    /// `upperBound` is `endIndex`, and the old `...` slice asked for
    /// `index(after: endIndex)` — a release-checked precondition, not a
    /// throwable error, so `read_meeting {"section":"speakers"}` on a
    /// hand-edited or truncated note killed the whole server process.
    /// The block now simply ends at the fence; the body after it is empty,
    /// so the reconstruction invariant this suite pins still holds.
    func testFrontmatterBlockDoesNotTrapWhenClosingFenceEndsTheFile() {
        let raw = "---\ntitle: Fence At EOF\n---\n"

        let block = frontmatterBlock(of: raw)

        XCTAssertEqual(block, raw, "a file that ends at its closing fence has no character past the fence to include")

        let parsedDocument = CaptureMarkdownParser.parseFrontmatter(from: raw)
        XCTAssertNotNil(parsedDocument, "CaptureMarkdownParser should still find the fence")
        if let parsedDocument, let block {
            XCTAssertEqual(block + parsedDocument.body.dropFirst(), raw, "the reconstruction invariant must survive an empty body")
        }
    }
}
