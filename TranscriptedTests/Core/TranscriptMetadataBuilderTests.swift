import XCTest
@testable import Transcripted

final class TranscriptMetadataBuilderTests: XCTestCase {

    // MARK: - CaptureQuality Boundary Values

    func testCaptureQualityAt100Percent() {
        XCTAssertEqual(RecordingHealthInfo.CaptureQuality.from(successRate: 1.0), .excellent)
    }

    func testCaptureQualityAt98Percent() {
        XCTAssertEqual(RecordingHealthInfo.CaptureQuality.from(successRate: 0.98), .excellent)
    }

    func testCaptureQualityAt97Percent() {
        XCTAssertEqual(RecordingHealthInfo.CaptureQuality.from(successRate: 0.97), .good)
    }

    func testCaptureQualityAt90Percent() {
        XCTAssertEqual(RecordingHealthInfo.CaptureQuality.from(successRate: 0.90), .good)
    }

    func testCaptureQualityAt89Percent() {
        XCTAssertEqual(RecordingHealthInfo.CaptureQuality.from(successRate: 0.89), .fair)
    }

    func testCaptureQualityAt80Percent() {
        XCTAssertEqual(RecordingHealthInfo.CaptureQuality.from(successRate: 0.80), .fair)
    }

    func testCaptureQualityAt79Percent() {
        XCTAssertEqual(RecordingHealthInfo.CaptureQuality.from(successRate: 0.79), .degraded)
    }

    func testCaptureQualityAt0Percent() {
        XCTAssertEqual(RecordingHealthInfo.CaptureQuality.from(successRate: 0.0), .degraded)
    }

    func testCaptureQualityNegativeRate() {
        XCTAssertEqual(RecordingHealthInfo.CaptureQuality.from(successRate: -0.1), .degraded)
    }

    // MARK: - CaptureQuality Raw Values

    func testExcellentRawValue() {
        XCTAssertEqual(RecordingHealthInfo.CaptureQuality.excellent.rawValue, "excellent")
    }

    func testGoodRawValue() {
        XCTAssertEqual(RecordingHealthInfo.CaptureQuality.good.rawValue, "good")
    }

    func testFairRawValue() {
        XCTAssertEqual(RecordingHealthInfo.CaptureQuality.fair.rawValue, "fair")
    }

    func testDegradedRawValue() {
        XCTAssertEqual(RecordingHealthInfo.CaptureQuality.degraded.rawValue, "degraded")
    }

    // MARK: - Perfect Factory

    func testPerfectHealthInfo() {
        let health = RecordingHealthInfo.perfect
        XCTAssertEqual(health.captureQuality, .excellent)
        XCTAssertEqual(health.audioGaps, 0)
        XCTAssertEqual(health.deviceSwitches, 0)
        XCTAssertTrue(health.gapDescriptions.isEmpty)
    }

    // MARK: - Custom Health Info

    func testHealthInfoWithGaps() {
        let health = RecordingHealthInfo(
            captureQuality: .fair,
            audioGaps: 3,
            deviceSwitches: 1,
            gapDescriptions: ["Sleep 2.5s", "Device switch 0.3s", "Recovery 1.2s"]
        )
        XCTAssertEqual(health.captureQuality, .fair)
        XCTAssertEqual(health.audioGaps, 3)
        XCTAssertEqual(health.deviceSwitches, 1)
        XCTAssertEqual(health.gapDescriptions.count, 3)
    }

    func testHealthInfoWithNoGaps() {
        let health = RecordingHealthInfo(
            captureQuality: .excellent,
            audioGaps: 0,
            deviceSwitches: 0,
            gapDescriptions: []
        )
        XCTAssertEqual(health.audioGaps, 0)
        XCTAssertTrue(health.gapDescriptions.isEmpty)
    }

    func testHealthInfoDegradedQuality() {
        let health = RecordingHealthInfo(
            captureQuality: .degraded,
            audioGaps: 10,
            deviceSwitches: 5,
            gapDescriptions: ["Multiple failures"]
        )
        XCTAssertEqual(health.captureQuality, .degraded)
        XCTAssertEqual(health.audioGaps, 10)
    }
}
