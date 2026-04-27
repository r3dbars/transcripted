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
}
