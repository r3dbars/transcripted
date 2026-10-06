import XCTest
@testable import TranscriptedCaptureKit

final class TranscriptTimestampCompatibilityTests: XCTestCase {
    func testRawAndStyledHourClocksPreserveOffsetsAlongsideLegacyMinutes() throws {
        let clocks: [(String, Double)] = [
            ("59:59", 3599), ("60:00", 3600), ("1:00:00", 3600),
            ("01:00:00", 3600), ("01:00:01", 3601),
            ("125:30", 7530), ("02:05:30", 7530),
            ("24:00:00", 86400), ("99:59:59", 359999),
            ("6000:00", 360000), ("100:00:00", 360000),
        ]
        for styled in [false, true] {
            let rows = clocks.enumerated().map { index, clock in
                styled
                    ? "**\(clock.0)**  [System/Speaker 0]\nBoundary row \(index)."
                    : "[\(clock.0)] [System/Speaker 0] Boundary row \(index)."
            }.joined(separator: "\n\n")
            let markdown = "---\ncapture_type: meeting\nduration: 100:00:01\n---\n\n## \(styled ? "Transcript" : "Full Transcript")\n\n\(rows)\n"
            let parsed = try XCTUnwrap(CaptureMarkdownParser.parseMeeting(from: markdown))
            XCTAssertEqual(parsed.utterances.map(\.start), clocks.map { $0.1 })
            XCTAssertEqual(parsed.durationSeconds, 360001)
            XCTAssertEqual(parsed.utterances.map(\.text), clocks.indices.map { "Boundary row \($0)." })
        }
    }
}
