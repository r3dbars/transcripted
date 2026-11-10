import Foundation
import XCTest
@testable import TranscriptedCaptureKit

final class LegacyEntryIdentityTests: XCTestCase {
    func testMissingIDsStayStableAcrossReadsAndUnrelatedInsertions() throws {
        for kind in ["dictation", "writing"] {
            let first = section(text: "First body.")
            let original = try entries(kind: kind, sections: [first])
            XCTAssertEqual(try entries(kind: kind, sections: [first]).map(\.id), original.map(\.id))
            let expanded = try entries(kind: kind, sections: [section(text: "Unrelated body."), first, section(text: "Another body.")])
            XCTAssertEqual(expanded.first(where: { $0.text == "First body." })?.id, original.first?.id)
            XCTAssertTrue(original.first?.id.hasPrefix("\(kind)-legacy-") == true)
        }
    }

    func testIdenticalLegacySectionsHaveDistinctStableIDs() throws {
        for kind in ["dictation", "writing"] {
            let duplicate = section(text: "Repeated body.")
            let first = try entries(kind: kind, sections: [duplicate, duplicate])
            XCTAssertEqual(first.count, 2)
            XCTAssertEqual(Set(first.map(\.id)).count, 2)
            XCTAssertEqual(try entries(kind: kind, sections: [duplicate, duplicate]).map(\.id), first.map(\.id))
        }
    }

    func testExplicitIDsAndIdentitiesAcrossFilesRemainDistinct() throws {
        for kind in ["dictation", "writing"] {
            let explicit = try entries(kind: kind, sections: [section(text: "Body.", id: "saved-entry-id")])
            XCTAssertEqual(explicit.map(\.id), ["saved-entry-id"])
            let first = try entries(kind: kind, sections: [section(text: "Body.")])
            let otherFile = try entries(kind: kind, sections: [section(text: "Body.")], day: "2026-11-10")
            XCTAssertNotEqual(first.first?.id, otherFile.first?.id)
        }
    }

    func testFallbackIDsMatchTheCrossProcessContract() throws {
        for (kind, expected) in [
            ("dictation", "dictation-legacy-38b9c6cf4296ca547b350bd15698263252241c1521c826701893743b2b116e70-0"),
            ("writing", "writing-legacy-d3d0f190b1702b5a7ea174d8d634c495c3070904007953853bab6d13e0e3b649-0"),
        ] {
            XCTAssertEqual(try entries(kind: kind, sections: [section(text: "First body.")]).map(\.id), [expected])
        }
    }

    private func section(text: String, id: String? = nil) -> String {
        """
        ## 9:00 AM - Fixture

        \(id.map { "Entry ID: `\($0)`\n" } ?? "")Captured: 2026-11-09T15:00:00Z
        Source app: Notes
        Words: 2

        \(text)
        """
    }

    private func entries(kind: String, sections: [String], day: String = "2026-11-09") throws -> [(id: String, text: String)] {
        let markdown = "---\ncapture_type: \(kind)_day\ndate: \(day)\n---\n\n" + sections.joined(separator: "\n\n")
        let prefix = kind == "writing" ? "Writing" : "Dictations"
        let url = URL(fileURLWithPath: "/fixtures/\(prefix)_\(day).md")
        if kind == "writing" {
            return try XCTUnwrap(CaptureMarkdownParser.parseWritingDay(from: markdown, markdownURL: url)).entries.map { ($0.id, $0.text) }
        }
        return try XCTUnwrap(CaptureMarkdownParser.parseDictationDay(from: markdown, markdownURL: url)).entries.map { ($0.id, $0.text) }
    }
}
