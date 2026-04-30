import AVFoundation
import Combine
import XCTest
@testable import TranscriptedCore

@available(macOS 14.0, *)
final class RecordingHealthInfoOverrideTests: XCTestCase {

    private func makePaths() -> CoreStoragePaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingHealthInfoOverrideTests-\(UUID().uuidString)", isDirectory: true)
        return CoreStoragePaths(
            transcripts: root.appendingPathComponent("captures/meetings", isDirectory: true),
            speakerDB: root.appendingPathComponent("state/speakers.sqlite"),
            statsDB: root.appendingPathComponent("state/stats.sqlite"),
            failedQueue: root.appendingPathComponent("state/failed_transcriptions.json"),
            speakerClips: root.appendingPathComponent("tmp/recordings/speaker_clips", isDirectory: true),
            audioCaptures: root.appendingPathComponent("tmp/recordings", isDirectory: true),
            logs: root.appendingPathComponent("logs", isDirectory: true)
        )
    }

    func testHealthInfoUsesLiveStatusWhenOverrideAbsent() {
        let audio = Audio(paths: makePaths())
        audio.systemAudioStatus = .failed

        let info = RecordingHealthInfo.from(audio: audio, systemCapture: nil)

        XCTAssertEqual(info.captureQuality, .degraded,
                       "live .failed status should yield degraded quality (success rate 0)")
    }

    func testHealthInfoOverrideWinsOverLiveStatus() {
        // Simulates the post-stop snapshot path: the live status has been
        // reset to .unknown by Audio.stop(), but the meeting controller
        // captured the real outcome (.failed) before stop. The override
        // must take precedence so the saved transcript reflects reality.
        let audio = Audio(paths: makePaths())
        audio.systemAudioStatus = .unknown    // live state has been reset
        audio.systemAudioFailed = false

        let info = RecordingHealthInfo.from(
            audio: audio,
            systemCapture: nil,
            overrideSystemAudioStatus: .failed
        )

        XCTAssertEqual(info.captureQuality, .degraded,
                       "overrideSystemAudioStatus = .failed must drive the success rate to 0")
    }

    func testHealthInfoOverrideFallsBackWhenNotFailed() {
        // A healthy override should not override the success rate; default
        // path returns 1.0 when systemCapture is nil and status is healthy.
        let audio = Audio(paths: makePaths())
        audio.systemAudioStatus = .unknown    // live state already reset

        let info = RecordingHealthInfo.from(
            audio: audio,
            systemCapture: nil,
            overrideSystemAudioStatus: .healthy
        )

        XCTAssertEqual(info.captureQuality, .excellent,
                       "healthy override + no recovery events should produce excellent")
    }

    func testHealthInfoSystemAudioFailedFlagDominatesOverride() {
        // If audio.systemAudioFailed is true, the persistent failure flag
        // must drive the result regardless of the override (the override
        // is only for the transient @Published status).
        let audio = Audio(paths: makePaths())
        audio.systemAudioFailed = true
        audio.systemAudioStatus = .healthy

        let info = RecordingHealthInfo.from(
            audio: audio,
            systemCapture: nil,
            overrideSystemAudioStatus: .healthy
        )

        XCTAssertEqual(info.captureQuality, .degraded,
                       "persistent systemAudioFailed should still degrade quality even with healthy override")
    }

    func testCreateHealthInfoForwardsOverrideToFactory() {
        // Audio.createHealthInfo(overrideSystemAudioStatus:) is the actual
        // surface MeetingSessionController calls. Confirm it forwards the
        // override correctly.
        let audio = Audio(paths: makePaths())
        audio.systemAudioStatus = .unknown    // simulates post-stop state

        let info = audio.createHealthInfo(overrideSystemAudioStatus: .failed)

        XCTAssertEqual(info.captureQuality, .degraded,
                       "createHealthInfo must forward the override into the factory")
    }

    func testHealthyOverrideCannotRecoverAfterCleanupResetsBufferCounters() {
        let audio = Audio(paths: makePaths())
        let capture = MutableStubSystemAudioCapture(successRate: 1.0)
        audio.systemAudioCapture = capture
        audio.systemAudioStatus = .healthy

        let preStopInfo = audio.createHealthInfo(overrideSystemAudioStatus: .healthy)
        XCTAssertEqual(preStopInfo.captureQuality, .excellent,
                       "healthy pre-stop buffers should report excellent capture quality")

        // Simulate the teardown path that triggered the 1.1.26 meeting-health
        // bug: stop/cleanup reset the live capture counters before the app read
        // them, so even a preserved healthy status could no longer recover the
        // real buffer success rate.
        capture.bufferSuccessRate = 0.0
        audio.systemAudioStatus = .unknown

        let postStopInfo = audio.createHealthInfo(overrideSystemAudioStatus: .healthy)

        XCTAssertEqual(postStopInfo.captureQuality, .degraded,
                       "health must be snapshotted before cleanup resets system buffer counters")
    }

    func testPipelineDiagnosticsSnapshotMustBeTakenBeforeCleanupResetsBuffers() {
        let audio = Audio(paths: makePaths())
        let capture = MutableStubSystemAudioCapture(successRate: 1.0)
        audio.systemAudioCapture = capture
        audio.systemAudioStatus = .healthy

        let preStopSnapshot = audio.createPipelineDiagnosticsSnapshot(
            overrideSystemAudioStatus: .healthy
        )
        XCTAssertEqual(preStopSnapshot.systemStatus, "healthy")
        XCTAssertEqual(preStopSnapshot.bufferSuccessBucket, "98_100",
                       "healthy pre-stop capture should keep its high buffer bucket")

        capture.bufferSuccessRate = 0.0
        audio.systemAudioStatus = .unknown

        let postStopSnapshot = audio.createPipelineDiagnosticsSnapshot(
            overrideSystemAudioStatus: .healthy
        )

        XCTAssertEqual(postStopSnapshot.systemStatus, "healthy",
                       "override should preserve the pre-stop status label")
        XCTAssertEqual(postStopSnapshot.bufferSuccessBucket, "lt_50",
                       "diagnostics must be captured before cleanup resets buffer-success counters")
    }
}

private final class MutableStubSystemAudioCapture: SystemAudioCaptureEngine, @unchecked Sendable {
    let diagnosticBackendName = "stub"
    let audioFormat: AVAudioFormat? = nil
    var bufferSuccessRate: Double
    let deliversOwnedAudioBuffers = true
    let errorMessagePublisher = CurrentValueSubject<String?, Never>(nil).eraseToAnyPublisher()

    init(successRate: Double) {
        self.bufferSuccessRate = successRate
    }

    func prepare() throws {}
    func start(bufferCallback: @escaping (AVAudioPCMBuffer) -> Void) throws {}
    func stop() {}
    func stopSync() {}
}
