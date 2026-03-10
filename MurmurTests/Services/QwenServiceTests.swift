import XCTest
@testable import Transcripted

@available(macOS 14.0, *)
final class QwenServiceTests: XCTestCase {

    // MARK: - parseResponse: Valid JSON

    func testParseResponseValidJSON() {
        let response = """
        {"0": "Sarah", "1": "Jack"}
        """
        let result = QwenService.parseResponse(response)
        XCTAssertEqual(result["0"], "Sarah")
        XCTAssertEqual(result["1"], "Jack")
    }

    func testParseResponseWithUnknownSpeakers() {
        let response = """
        {"0": "Sarah", "1": "Unknown", "2": "Mike"}
        """
        let result = QwenService.parseResponse(response)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result["1"], "Unknown")
    }

    // MARK: - parseResponse: Markdown fences

    func testParseResponseStripsMarkdownJsonFence() {
        let response = """
        ```json
        {"0": "Alice", "1": "Bob"}
        ```
        """
        let result = QwenService.parseResponse(response)
        XCTAssertEqual(result["0"], "Alice")
        XCTAssertEqual(result["1"], "Bob")
    }

    func testParseResponseStripsPlainMarkdownFence() {
        let response = """
        ```
        {"0": "Alice"}
        ```
        """
        let result = QwenService.parseResponse(response)
        XCTAssertEqual(result["0"], "Alice")
    }

    // MARK: - parseResponse: Trailing text

    func testParseResponseIgnoresTrailingText() {
        let response = """
        {"0": "Sarah", "1": "Jack"}

        I identified Speaker 0 as Sarah because she said "I'm Sarah."
        """
        let result = QwenService.parseResponse(response)
        XCTAssertEqual(result["0"], "Sarah")
        XCTAssertEqual(result["1"], "Jack")
    }

    func testParseResponseIgnoresLeadingText() {
        let response = """
        Based on the transcript:
        {"0": "Sarah"}
        """
        let result = QwenService.parseResponse(response)
        XCTAssertEqual(result["0"], "Sarah")
    }

    // MARK: - parseResponse: Error cases

    func testParseResponseEmptyString() {
        let result = QwenService.parseResponse("")
        XCTAssertTrue(result.isEmpty)
    }

    func testParseResponseNoJSON() {
        let result = QwenService.parseResponse("I couldn't identify any speakers.")
        XCTAssertTrue(result.isEmpty)
    }

    func testParseResponseMalformedJSON() {
        let result = QwenService.parseResponse("{0: Sarah, 1: Jack}")
        XCTAssertTrue(result.isEmpty)
    }

    func testParseResponseSingleSpeaker() {
        let result = QwenService.parseResponse("""
        {"0": "Jenny"}
        """)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result["0"], "Jenny")
    }
}
