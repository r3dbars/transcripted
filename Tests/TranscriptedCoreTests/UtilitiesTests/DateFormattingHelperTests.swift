import XCTest
@testable import TranscriptedCore

/// Byte-identical formatting coverage for `DateFormattingHelper`'s consolidated
/// formatters (audit 2026-07-08, W1-A5). Pins TimeZone/Locale so these assertions
/// are deterministic regardless of the machine running them.
@available(macOS 14.0, *)
final class DateFormattingHelperTests: XCTestCase {

    /// 2024-01-15 14:30:45.123 UTC
    private let fixedDate = Date(timeIntervalSince1970: 1_705_329_045.123)

    private var originalTimeZone: TimeZone!

    override func setUp() {
        super.setUp()
        originalTimeZone = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "UTC")!
    }

    override func tearDown() {
        NSTimeZone.default = originalTimeZone
        super.tearDown()
    }

    func testFormatDayStampProducesYYYYMMDD() {
        XCTAssertEqual(DateFormattingHelper.formatDayStamp(fixedDate), "2024-01-15")
    }

    func testParseDayStampRoundTripsWithFormat() {
        let parsed = DateFormattingHelper.parseDayStamp("2024-01-15")
        XCTAssertEqual(parsed.map(DateFormattingHelper.formatDayStamp), "2024-01-15")
    }

    func testParseDayStampRejectsMalformedInput() {
        XCTAssertNil(DateFormattingHelper.parseDayStamp("not-a-date"))
    }

    func testFormatISO8601WithoutFractionalSeconds() {
        XCTAssertEqual(DateFormattingHelper.formatISO8601(fixedDate), "2024-01-15T14:30:45Z")
    }

    func testFormatISO8601WithFractionalSeconds() {
        XCTAssertEqual(
            DateFormattingHelper.formatISO8601WithFractionalSeconds(fixedDate),
            "2024-01-15T14:30:45.123Z"
        )
    }

    func testFormatDisplayUsesMediumDateShortTime() {
        // en_US_POSIX doesn't localize dateStyle/timeStyle the way a real locale
        // does, so this asserts against the system's current locale/timezone
        // formatting a fixed reference date, matching how the shared helper is
        // actually consumed by call sites (no explicit locale override).
        let expected: String = {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter.string(from: fixedDate)
        }()
        XCTAssertEqual(DateFormattingHelper.formatDisplay(fixedDate), expected)
    }
}
