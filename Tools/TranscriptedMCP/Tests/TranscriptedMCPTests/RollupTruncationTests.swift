import Foundation
import MCP
import XCTest
@testable import transcripted_mcp

final class RollupTruncationTests: XCTestCase {
    func testRecapAndDigestDistinguishCompleteWindowsFromCappedWindows() throws {
        for count in [49, 50, 51] {
            let root = makeTempDir()
            defer { removeTempDir(root) }
            for number in 0..<count {
                try writeFixture(makeMeetingWithInlineSummary(
                    date: "2026-04-18", time: String(format: "09:00:%02d", number),
                    decisions: ["Fixture decision"], actionItems: [], openQuestions: []
                ), filename: String(format: "Call_%02d", number), to: root)
            }
            let index = try TranscriptIndex(indexDir: root)
            try index.reconcile(meetingsDir: root, dictationsDir: root, updateEmbeddings: false)
            let arguments: [String: Value] = ["date_from": .string("2026-04-18"), "date_to": .string("2026-04-18")]
            let recap = try object(handleRecap(params: .init(name: "recap", arguments: arguments), index: index, meetingDirs: [root]))
            let digest = try object(handleDigest(params: .init(name: "digest", arguments: arguments), index: index, meetingDirs: [root]))
            for payload in [recap, digest] {
                XCTAssertEqual(payload["truncated"] as? Bool, count > 50, "exactly 50 must still report complete")
                XCTAssertEqual((payload["meetings"] as? [Any])?.count, min(count, 50))
            }
            XCTAssertEqual(digest["decision_count"] as? Int, min(count, 50), "the overflow sentinel must not contribute facts")
            XCTAssertEqual(try index.listMeetings(count: 100).count, min(count, 50), "the existing listing cap stays unchanged")
        }
    }

    func testDigestExplicitLimitAlsoReportsAnOverflow() throws {
        let root = makeTempDir()
        defer { removeTempDir(root) }
        for number in 0..<2 {
            try writeFixture(makeMeetingWithInlineSummary(), filename: "Call_\(number)", to: root)
        }
        let index = try TranscriptIndex(indexDir: root)
        try index.reconcile(meetingsDir: root, dictationsDir: root, updateEmbeddings: false)
        let encoded = try JSONEncoder().encode(index.digest(dateFrom: nil, dateTo: nil, maxMeetings: 1))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(payload["truncated"] as? Bool, true)
        XCTAssertEqual((payload["meetings"] as? [Any])?.count, 1)
    }

    private func object(_ result: CallTool.Result) throws -> [String: Any] {
        let first = try XCTUnwrap(result.content.first)
        guard case .text(let text, _, _) = first else {
            XCTFail("Rollup must return a JSON text payload")
            return [:]
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}
