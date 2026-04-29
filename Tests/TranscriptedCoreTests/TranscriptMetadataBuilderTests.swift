import XCTest
import AVFoundation
import Combine
@testable import TranscriptedCore

@available(macOS 14.0, *)
final class RecordingHealthInfoTests: XCTestCase {
    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        super.tearDown()
    }

    func testHealthInfoMarksFailedSystemAudioAsDegraded() {
        let audio = Audio(paths: makePaths())
        audio.systemAudioFailed = true
        audio.systemAudioStatus = .failed

        let health = RecordingHealthInfo.from(audio: audio, systemCapture: nil)

        XCTAssertEqual(health.captureQuality, .degraded)
    }

    func testHealthInfoDowngradesForGapsAndDeviceSwitches() {
        let audio = Audio(paths: makePaths())
        audio.deviceSwitchCount = 1
        audio.appendRecordingGap(.init(start: Date(), duration: 1.5, reason: "sleep_wake"))

        let health = RecordingHealthInfo.from(audio: audio, systemCapture: nil)

        XCTAssertEqual(health.captureQuality, .good)
        XCTAssertEqual(health.audioGaps, 1)
        XCTAssertEqual(health.deviceSwitches, 1)
        XCTAssertEqual(health.gapDescriptions, ["sleep_wake: 1.5s"])
    }

    func testHealthInfoTreatsZeroSystemBuffersAsDegraded() {
        let audio = Audio(paths: makePaths())
        let capture = StubSystemAudioCapture(successRate: 0.0)

        let health = RecordingHealthInfo.from(audio: audio, systemCapture: capture)

        XCTAssertEqual(health.captureQuality, .degraded)
    }

    private func makePaths() -> CoreStoragePaths {
        CoreStoragePaths(
            transcripts: tempRoot.appendingPathComponent("transcripts", isDirectory: true),
            speakerDB: tempRoot.appendingPathComponent("state/speakers.sqlite"),
            statsDB: tempRoot.appendingPathComponent("state/stats.sqlite"),
            failedQueue: tempRoot.appendingPathComponent("state/failed.json"),
            speakerClips: tempRoot.appendingPathComponent("clips", isDirectory: true),
            audioCaptures: tempRoot.appendingPathComponent("audio", isDirectory: true),
            logs: tempRoot.appendingPathComponent("logs", isDirectory: true)
        )
    }
}

private final class StubSystemAudioCapture: SystemAudioCaptureEngine {
    let diagnosticBackendName = "stub"
    let audioFormat: AVAudioFormat? = nil
    let bufferSuccessRate: Double
    let deliversOwnedAudioBuffers = true
    let errorMessagePublisher = Just<String?>(nil).eraseToAnyPublisher()

    init(successRate: Double) {
        self.bufferSuccessRate = successRate
    }

    func prepare() throws {}
    func start(bufferCallback: @escaping (AVAudioPCMBuffer) -> Void) throws {}
    func stop() {}
    func stopSync() {}
}
