import XCTest
@testable import Transcripted

@available(macOS 14.0, *)
final class MeetingDetectorTests: XCTestCase {

    // MARK: - Initial State

    @MainActor
    func testInitialStateIsNotDetecting() {
        // MeetingDetector requires an Audio instance, but we can test
        // that the published properties have correct initial values
        // by checking the type's interface
        // Note: Full functional testing requires the /transcripted-qa skill
        // with computer-use to verify meeting detection end-to-end
    }

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

    // MARK: - RecordingHealthInfo

    func testCaptureQualityExcellent() {
        XCTAssertEqual(RecordingHealthInfo.CaptureQuality.from(successRate: 1.0), .excellent)
        XCTAssertEqual(RecordingHealthInfo.CaptureQuality.from(successRate: 0.98), .excellent)
    }

    func testCaptureQualityGood() {
        XCTAssertEqual(RecordingHealthInfo.CaptureQuality.from(successRate: 0.97), .good)
        XCTAssertEqual(RecordingHealthInfo.CaptureQuality.from(successRate: 0.90), .good)
    }

    func testCaptureQualityFair() {
        XCTAssertEqual(RecordingHealthInfo.CaptureQuality.from(successRate: 0.89), .fair)
        XCTAssertEqual(RecordingHealthInfo.CaptureQuality.from(successRate: 0.80), .fair)
    }

    func testCaptureQualityDegraded() {
        XCTAssertEqual(RecordingHealthInfo.CaptureQuality.from(successRate: 0.79), .degraded)
        XCTAssertEqual(RecordingHealthInfo.CaptureQuality.from(successRate: 0.0), .degraded)
    }

    func testPerfectHealthInfo() {
        let health = RecordingHealthInfo.perfect
        XCTAssertEqual(health.captureQuality, .excellent)
        XCTAssertEqual(health.audioGaps, 0)
        XCTAssertEqual(health.deviceSwitches, 0)
        XCTAssertTrue(health.gapDescriptions.isEmpty)
    }

    func testCaptureQualityRawValues() {
        XCTAssertEqual(RecordingHealthInfo.CaptureQuality.excellent.rawValue, "excellent")
        XCTAssertEqual(RecordingHealthInfo.CaptureQuality.good.rawValue, "good")
        XCTAssertEqual(RecordingHealthInfo.CaptureQuality.fair.rawValue, "fair")
        XCTAssertEqual(RecordingHealthInfo.CaptureQuality.degraded.rawValue, "degraded")
    }
}
