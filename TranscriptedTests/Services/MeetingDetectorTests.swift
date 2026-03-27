import XCTest
@testable import Transcripted

@available(macOS 14.0, *)
final class MeetingDetectorTests: XCTestCase {

    // MARK: - SpeakerNameUpdate Action Cases

    func testNamingActionNamedCase() {
        let update = SpeakerNameUpdate(
            persistentSpeakerId: UUID(),
            sortformerSpeakerId: "0",
            newName: "Alice",
            action: .named
        )
        if case .named = update.action {
            XCTAssertEqual(update.newName, "Alice")
        } else {
            XCTFail("Expected .named action")
        }
    }

    func testNamingActionConfirmedCase() {
        let update = SpeakerNameUpdate(
            persistentSpeakerId: UUID(),
            sortformerSpeakerId: "1",
            newName: "Bob",
            action: .confirmed
        )
        if case .confirmed = update.action {} else {
            XCTFail("Expected .confirmed action")
        }
    }

    func testNamingActionCorrectedCase() {
        let update = SpeakerNameUpdate(
            persistentSpeakerId: UUID(),
            sortformerSpeakerId: "2",
            newName: "Charlie",
            action: .corrected
        )
        if case .corrected = update.action {} else {
            XCTFail("Expected .corrected action")
        }
    }

    func testNamingActionMergedCase() {
        let targetId = UUID()
        let update = SpeakerNameUpdate(
            persistentSpeakerId: UUID(),
            sortformerSpeakerId: "0",
            newName: "Alice",
            action: .merged(targetProfileId: targetId)
        )
        if case .merged(let id) = update.action {
            XCTAssertEqual(id, targetId)
        } else {
            XCTFail("Expected .merged action")
        }
    }
}
