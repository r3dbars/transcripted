import XCTest
@testable import TranscriptedCore

/// `stop_cause` reaches PostHog and Sentry only if every value is a short
/// category the sanitizers keep (see Sources/Observability/AGENTS.md).
final class InternalCaptureStopCauseTests: XCTestCase {

    func testEveryStopCauseIsATelemetrySafeCategory() throws {
        let category = try NSRegularExpression(pattern: "^[a-z0-9][a-z0-9_]*$")
        let dropped = ["audio", "error", "file", "name", "path", "text", "title", "token", "url", "speaker"]
        for cause in InternalCaptureStopCause.allCases {
            let value = cause.rawValue
            XCTAssertLessThanOrEqual(value.count, 80, value)
            XCTAssertNotNil(
                category.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
                "\(value) must be a lowercase category"
            )
            for fragment in dropped {
                XCTAssertFalse(value.contains(fragment), "\(value) contains \(fragment)")
            }
        }
    }

    func testEachStopPathHasItsOwnCause() {
        let values = InternalCaptureStopCause.allCases.map(\.rawValue)
        XCTAssertEqual(Set(values).count, values.count)
        XCTAssertFalse(values.contains("unrecorded"), "reserved for stops with no Core cause")
    }
}
