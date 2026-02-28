import XCTest
@testable import Transcripted

@available(macOS 14.0, *)
final class TodoistSanitizeTests: XCTestCase {

    private var service: TodoistService!

    override func setUp() {
        super.setUp()
        service = TodoistService()
    }

    // MARK: - Null/none/empty → nil

    func testNullReturnsNil() {
        XCTAssertNil(service.sanitizeDueString("null"))
    }

    func testNoneReturnsNil() {
        XCTAssertNil(service.sanitizeDueString("none"))
    }

    func testNAReturnsNil() {
        XCTAssertNil(service.sanitizeDueString("n/a"))
    }

    func testEmptyReturnsNil() {
        XCTAssertNil(service.sanitizeDueString(""))
    }

    // MARK: - Pass-through values

    func testTodayPassesThrough() {
        XCTAssertEqual(service.sanitizeDueString("today"), "today")
    }

    func testTomorrowPassesThrough() {
        XCTAssertEqual(service.sanitizeDueString("tomorrow"), "tomorrow")
    }

    func testNextWeekPassesThrough() {
        XCTAssertEqual(service.sanitizeDueString("next week"), "next week")
    }

    func testNextMonthPassesThrough() {
        XCTAssertEqual(service.sanitizeDueString("next month"), "next month")
    }

    // MARK: - Conversions

    func testEOWConvertedToFriday() {
        XCTAssertEqual(service.sanitizeDueString("eow"), "Friday")
    }

    func testEndOfWeekConvertedToFriday() {
        XCTAssertEqual(service.sanitizeDueString("end of week"), "Friday")
    }

    func testASAPConvertedToToday() {
        XCTAssertEqual(service.sanitizeDueString("asap"), "today")
    }

    func testCoupleWeeksConverted() {
        XCTAssertEqual(service.sanitizeDueString("couple weeks"), "in 2 weeks")
    }

    func testFewDaysConverted() {
        XCTAssertEqual(service.sanitizeDueString("few days"), "in 3 days")
    }

    func testEODConverted() {
        XCTAssertEqual(service.sanitizeDueString("eod"), "today")
    }

    func testEOMConverted() {
        XCTAssertEqual(service.sanitizeDueString("eom"), "last day of month")
    }

    // MARK: - Day names

    func testDayNameExtracted() {
        XCTAssertEqual(service.sanitizeDueString("monday"), "Monday")
    }

    func testNextDayNameExtracted() {
        XCTAssertEqual(service.sanitizeDueString("next tuesday"), "next Tuesday")
    }

    // MARK: - Unparseable → nil

    func testGibberishReturnsNil() {
        XCTAssertNil(service.sanitizeDueString("whenever you get to it"))
    }
}
