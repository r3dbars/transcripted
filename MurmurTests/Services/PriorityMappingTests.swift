import XCTest
@testable import Transcripted

final class PriorityMappingTests: XCTestCase {

    // MARK: - EventKit priority (1=high, 5=medium, 9=low, 0=none)

    func testEventKitHighPriority() {
        XCTAssertEqual(ActionItem.mock(priority: "High").eventKitPriority, 1)
    }

    func testEventKitMediumPriority() {
        XCTAssertEqual(ActionItem.mock(priority: "Medium").eventKitPriority, 5)
    }

    func testEventKitLowPriority() {
        XCTAssertEqual(ActionItem.mock(priority: "Low").eventKitPriority, 9)
    }

    func testEventKitNoPriority() {
        XCTAssertEqual(ActionItem.mock(priority: "").eventKitPriority, 0)
    }

    func testEventKitCaseInsensitive() {
        XCTAssertEqual(ActionItem.mock(priority: "HIGH").eventKitPriority, 1)
        XCTAssertEqual(ActionItem.mock(priority: "medium").eventKitPriority, 5)
    }

    // MARK: - Todoist priority (4=urgent/high, 3=medium, 2=low, 1=normal)

    func testTodoistHighPriority() {
        XCTAssertEqual(ActionItem.mock(priority: "High").todoistPriority, 4)
    }

    func testTodoistMediumPriority() {
        XCTAssertEqual(ActionItem.mock(priority: "Medium").todoistPriority, 3)
    }

    func testTodoistLowPriority() {
        XCTAssertEqual(ActionItem.mock(priority: "Low").todoistPriority, 2)
    }

    func testTodoistNoPriority() {
        XCTAssertEqual(ActionItem.mock(priority: "").todoistPriority, 1)
    }
}
