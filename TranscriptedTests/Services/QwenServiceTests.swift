import XCTest
@testable import Transcripted

@available(macOS 14.0, *)
final class QwenServiceTests: XCTestCase {

    // MARK: - parseResponse: Valid JSON (legacy flat format)

    func testParseResponseValidJSON() {
        let response = """
        {"0": "Sarah", "1": "Jack"}
        """
        let result = QwenService.parseResponse(response)
        XCTAssertEqual(result.speakers["0"], "Sarah")
        XCTAssertEqual(result.speakers["1"], "Jack")
        XCTAssertNil(result.meetingTitle)
    }

    func testParseResponseWithUnknownSpeakers() {
        let response = """
        {"0": "Sarah", "1": "Unknown", "2": "Mike"}
        """
        let result = QwenService.parseResponse(response)
        XCTAssertEqual(result.speakers.count, 3)
        XCTAssertEqual(result.speakers["1"], "Unknown")
    }

    // MARK: - parseResponse: New format with title

    func testParseResponseNewFormatWithTitle() {
        let response = """
        {"speakers": {"0": "Sarah", "1": "Mike"}, "title": "Sprint Planning Review"}
        """
        let result = QwenService.parseResponse(response)
        XCTAssertEqual(result.speakers["0"], "Sarah")
        XCTAssertEqual(result.speakers["1"], "Mike")
        XCTAssertEqual(result.meetingTitle, "Sprint Planning Review")
    }

    func testParseResponseNewFormatGenericTitleReturnsNil() {
        let response = """
        {"speakers": {"0": "Sarah"}, "title": "Meeting"}
        """
        let result = QwenService.parseResponse(response)
        XCTAssertEqual(result.speakers["0"], "Sarah")
        XCTAssertNil(result.meetingTitle, "Generic 'Meeting' title should be filtered out")
    }

    // MARK: - parseResponse: Markdown fences

    func testParseResponseStripsMarkdownJsonFence() {
        let response = """
        ```json
        {"0": "Alice", "1": "Bob"}
        ```
        """
        let result = QwenService.parseResponse(response)
        XCTAssertEqual(result.speakers["0"], "Alice")
        XCTAssertEqual(result.speakers["1"], "Bob")
    }

    func testParseResponseStripsPlainMarkdownFence() {
        let response = """
        ```
        {"0": "Alice"}
        ```
        """
        let result = QwenService.parseResponse(response)
        XCTAssertEqual(result.speakers["0"], "Alice")
    }

    // MARK: - parseResponse: Trailing text

    func testParseResponseIgnoresTrailingText() {
        let response = """
        {"0": "Sarah", "1": "Jack"}

        I identified Speaker 0 as Sarah because she said "I'm Sarah."
        """
        let result = QwenService.parseResponse(response)
        XCTAssertEqual(result.speakers["0"], "Sarah")
        XCTAssertEqual(result.speakers["1"], "Jack")
    }

    func testParseResponseIgnoresLeadingText() {
        let response = """
        Based on the transcript:
        {"0": "Sarah"}
        """
        let result = QwenService.parseResponse(response)
        XCTAssertEqual(result.speakers["0"], "Sarah")
    }

    // MARK: - parseResponse: Error cases

    func testParseResponseEmptyString() {
        let result = QwenService.parseResponse("")
        XCTAssertTrue(result.speakers.isEmpty)
    }

    func testParseResponseNoJSON() {
        let result = QwenService.parseResponse("I couldn't identify any speakers.")
        XCTAssertTrue(result.speakers.isEmpty)
    }

    func testParseResponseMalformedJSON() {
        let result = QwenService.parseResponse("{0: Sarah, 1: Jack}")
        XCTAssertTrue(result.speakers.isEmpty)
    }

    func testParseResponseSingleSpeaker() {
        let result = QwenService.parseResponse("""
        {"0": "Jenny"}
        """)
        XCTAssertEqual(result.speakers.count, 1)
        XCTAssertEqual(result.speakers["0"], "Jenny")
    }
}
