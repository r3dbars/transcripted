import XCTest
@testable import Transcripted

final class DateFormattingHelperTests: XCTestCase {

    // MARK: - formatDuration (MM:SS with leading zeros)

    func testFormatDurationZero() {
        XCTAssertEqual(DateFormattingHelper.formatDuration(0), "00:00")
    }

    func testFormatDurationOneMinuteFiveSeconds() {
        XCTAssertEqual(DateFormattingHelper.formatDuration(65), "01:05")
    }

    func testFormatDurationOneHourOneMinuteOneSecond() {
        XCTAssertEqual(DateFormattingHelper.formatDuration(3661), "61:01")
    }

    func testFormatDurationLargeValue() {
        // 24 hours = 86400 seconds = 1440 minutes
        XCTAssertEqual(DateFormattingHelper.formatDuration(86400), "1440:00")
    }

    func testFormatDurationFractionalTruncates() {
        // 65.9 should still be 01:05 (Int truncation)
        XCTAssertEqual(DateFormattingHelper.formatDuration(65.9), "01:05")
    }

    // MARK: - formatDurationCompact (M:SS, no leading zero on minutes)

    func testFormatDurationCompactZero() {
        XCTAssertEqual(DateFormattingHelper.formatDurationCompact(0), "0:00")
    }

    func testFormatDurationCompactFiveSeconds() {
        XCTAssertEqual(DateFormattingHelper.formatDurationCompact(5), "0:05")
    }

    func testFormatDurationCompactOneMinuteFiveSeconds() {
        XCTAssertEqual(DateFormattingHelper.formatDurationCompact(65), "1:05")
    }

    func testFormatDurationCompactTenMinutes() {
        XCTAssertEqual(DateFormattingHelper.formatDurationCompact(600), "10:00")
    }

    // MARK: - formatFilename / formatFilenamePrecise patterns

    func testFormatFilenamePattern() {
        let date = makeDate(year: 2024, month: 1, day: 15, hour: 14, minute: 30, second: 45)
        let result = DateFormattingHelper.formatFilename(date)
        XCTAssertEqual(result, "2024-01-15_14-30-45")
    }

    func testFormatFilenamePreciseContainsMilliseconds() {
        let date = makeDate(year: 2024, month: 1, day: 15, hour: 14, minute: 30, second: 45)
        let result = DateFormattingHelper.formatFilenamePrecise(date)
        // Should match pattern: "2024-01-15_14-30-45-XXX"
        XCTAssertTrue(result.hasPrefix("2024-01-15_14-30-45-"), "Expected prefix '2024-01-15_14-30-45-', got '\(result)'")
    }

    // MARK: - formatTimeOnly / formatISODate patterns

    func testFormatTimeOnly() {
        let date = makeDate(year: 2024, month: 1, day: 15, hour: 14, minute: 30, second: 45)
        XCTAssertEqual(DateFormattingHelper.formatTimeOnly(date), "14:30:45")
    }

    func testFormatISODate() {
        let date = makeDate(year: 2024, month: 1, day: 15, hour: 14, minute: 30, second: 45)
        XCTAssertEqual(DateFormattingHelper.formatISODate(date), "2024-01-15")
    }

    // MARK: - Helpers

    private func makeDate(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0, second: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        components.timeZone = TimeZone.current
        return Calendar.current.date(from: components)!
    }
}
