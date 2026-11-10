import Foundation
import XCTest
@testable import TranscriptedCaptureKit

final class CaptureKindMetadataTests: XCTestCase {
    func testDictationMetadataIdentifiesRenamedDayFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Renamed.md")
        for scalar in ["dictation_day", "\"dictation_day\""] {
            try "---\ncapture_type: \(scalar)\ndate: 2026-11-09\n---\nBody.\n".write(to: url, atomically: true, encoding: .utf8)
            XCTAssertEqual(CaptureMarkdown.captureKind(of: url), .dictationDay)
        }
    }

    func testFilenameFallbackAndOtherCaptureKindsKeepTheirContracts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("Dictations_2026-11-09.md")
        try "Legacy body without frontmatter.".write(to: legacy, atomically: true, encoding: .utf8)
        XCTAssertEqual(CaptureMarkdown.captureKind(of: legacy), .dictationDay)
        let url = root.appendingPathComponent("Renamed.md")
        for (scalar, expected) in [("writing_day", CaptureMarkdownKind.writingDay), ("meeting", .meeting)] {
            try "---\ncapture_type: \(scalar)\n---\nBody.\n".write(to: url, atomically: true, encoding: .utf8)
            XCTAssertEqual(CaptureMarkdown.captureKind(of: url), expected)
        }
    }
}
