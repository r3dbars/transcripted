import XCTest
@testable import Transcripted

final class DateParserTests: XCTestCase {

    // MARK: - Nil / empty / whitespace

    func testNilReturnsNil() {
        XCTAssertNil(DateParser.parseNaturalDate(nil))
    }

    func testEmptyStringReturnsNil() {
        XCTAssertNil(DateParser.parseNaturalDate(""))
    }

    func testWhitespaceReturnsNil() {
        XCTAssertNil(DateParser.parseNaturalDate("   "))
    }

    // MARK: - Relative keywords

    func testTodayReturnsToday() {
        let result = DateParser.parseNaturalDate("today")
        XCTAssertNotNil(result)
        // NSDataDetector handles "today" first — just verify it's the same day
        let calendar = Calendar.current
        XCTAssertEqual(calendar.component(.day, from: result!), calendar.component(.day, from: Date()))
        XCTAssertEqual(calendar.component(.month, from: result!), calendar.component(.month, from: Date()))
        XCTAssertEqual(calendar.component(.year, from: result!), calendar.component(.year, from: Date()))
    }

    func testTomorrowReturnsNextDay() {
        let result = DateParser.parseNaturalDate("tomorrow")
        XCTAssertNotNil(result)
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        // Compare day components (not exact time)
        let resultDay = Calendar.current.component(.day, from: result!)
        let expectedDay = Calendar.current.component(.day, from: tomorrow)
        XCTAssertEqual(resultDay, expectedDay)
    }

    func testEODReturnsTodayAt5PM() {
        let result = DateParser.parseNaturalDate("eod")
        XCTAssertNotNil(result)
        let hour = Calendar.current.component(.hour, from: result!)
        XCTAssertEqual(hour, 17)
    }

    func testEndOfDayReturnsTodayAt5PM() {
        let result = DateParser.parseNaturalDate("end of day")
        XCTAssertNotNil(result)
        let hour = Calendar.current.component(.hour, from: result!)
        XCTAssertEqual(hour, 17)
    }

    func testEOWReturnsFridayOrLater() {
        let result = DateParser.parseNaturalDate("eow")
        XCTAssertNotNil(result)
        // Should be in the future (or today if today is Friday and it wraps to next)
        let weekday = Calendar.current.component(.weekday, from: result!)
        XCTAssertEqual(weekday, 6, "EOW should resolve to Friday (weekday 6)")
    }

    func testEOMReturnsLastDayOfMonth() {
        let result = DateParser.parseNaturalDate("eom")
        XCTAssertNotNil(result)
        let calendar = Calendar.current
        // The result's day should be the last day of the current month
        let nextDay = calendar.date(byAdding: .day, value: 1, to: result!)!
        let nextDayOfMonth = calendar.component(.day, from: nextDay)
        XCTAssertEqual(nextDayOfMonth, 1, "Day after EOM should be the 1st of next month")
    }

    func testEOYReturnsDecember31() {
        let result = DateParser.parseNaturalDate("eoy")
        XCTAssertNotNil(result)
        let calendar = Calendar.current
        XCTAssertEqual(calendar.component(.month, from: result!), 12)
        XCTAssertEqual(calendar.component(.day, from: result!), 31)
    }

    func testNextWeekReturns7DaysLater() {
        let result = DateParser.parseNaturalDate("next week")
        XCTAssertNotNil(result)
        let expected = Calendar.current.date(byAdding: .weekOfYear, value: 1, to: Date())!
        let diff = abs(result!.timeIntervalSince(expected))
        XCTAssertLessThan(diff, 2, "next week should be ~7 days from now")
    }

    // MARK: - "in X days" pattern

    func testInFiveDays() {
        let result = DateParser.parseNaturalDate("in 5 days")
        XCTAssertNotNil(result)
        // NSDataDetector may handle this — verify result is ~5 days from now (within 1 day tolerance)
        let expected = Calendar.current.date(byAdding: .day, value: 5, to: Date())!
        let diff = abs(result!.timeIntervalSince(expected))
        XCTAssertLessThan(diff, 86400, "in 5 days should be ~5 days from now (within 1 day)")
    }

    func testInAbcDaysReturnsNil() {
        XCTAssertNil(DateParser.parseNaturalDate("in abc days"))
    }

    // MARK: - NSDataDetector fallback

    func testJanuary15Parses() {
        let result = DateParser.parseNaturalDate("January 15")
        XCTAssertNotNil(result, "NSDataDetector should parse 'January 15'")
        let month = Calendar.current.component(.month, from: result!)
        XCTAssertEqual(month, 1)
    }

    // MARK: - Unknown strings

    func testUnknownStringReturnsNil() {
        XCTAssertNil(DateParser.parseNaturalDate("banana"))
    }

    func testGibberishReturnsNil() {
        XCTAssertNil(DateParser.parseNaturalDate("xyzzy123"))
    }
}
