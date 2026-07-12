import XCTest
@testable import TranscriptedCore

@available(macOS 14.0, *)
final class AudioLevelMonitorSilenceTests: XCTestCase {

    private func makeAudio() -> Audio {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioLevelMonitorSilenceTests-\(UUID().uuidString)", isDirectory: true)
        let paths = CoreStoragePaths(
            transcripts: root.appendingPathComponent("captures/meetings", isDirectory: true),
            speakerDB: root.appendingPathComponent("state/speakers.sqlite"),
            statsDB: root.appendingPathComponent("state/stats.sqlite"),
            failedQueue: root.appendingPathComponent("state/failed_transcriptions.json"),
            speakerClips: root.appendingPathComponent("tmp/recordings/speaker_clips", isDirectory: true),
            audioCaptures: root.appendingPathComponent("tmp/recordings", isDirectory: true),
            logs: root.appendingPathComponent("logs", isDirectory: true)
        )
        return Audio(paths: paths)
    }

    private let base = Date(timeIntervalSinceReferenceDate: 0)
    private func at(_ seconds: TimeInterval) -> Date { base.addingTimeInterval(seconds) }

    func testLoudAudioKeepsNonSilentAndZeroDuration() {
        let audio = makeAudio()
        audio.resetSilenceTracking(now: at(0))

        // Above the 0.02 threshold — stays non-silent, duration pinned at 0.
        audio.updateSilenceTracking(currentLevel: 0.5, now: at(1))

        XCTAssertFalse(audio.isSilent)
        XCTAssertEqual(audio.silenceDuration, 0)
        XCTAssertEqual(audio.lastNonSilentTime, at(1))
    }

    func testSilenceDurationGrowsFromLastActiveTime() {
        let audio = makeAudio()
        audio.resetSilenceTracking(now: at(0))

        // Establish a recent active time, then drop into silence.
        audio.updateSilenceTracking(currentLevel: 0.5, now: at(2))   // active at t=2
        audio.updateSilenceTracking(currentLevel: 0.0, now: at(5))   // silent, 3s since active
        XCTAssertTrue(audio.isSilent)
        XCTAssertEqual(audio.silenceDuration, 3, accuracy: 0.000_1)

        // Continued silence — duration grows relative to the same active anchor.
        audio.updateSilenceTracking(currentLevel: 0.0, now: at(9))   // 7s since active
        XCTAssertTrue(audio.isSilent)
        XCTAssertEqual(audio.silenceDuration, 7, accuracy: 0.000_1)
    }

    func testAudioReturningClearsSilenceState() {
        let audio = makeAudio()
        audio.resetSilenceTracking(now: at(0))
        audio.updateSilenceTracking(currentLevel: 0.0, now: at(4))   // go silent
        XCTAssertTrue(audio.isSilent)

        audio.updateSilenceTracking(currentLevel: 0.3, now: at(6))   // audio returns
        XCTAssertFalse(audio.isSilent)
        XCTAssertEqual(audio.silenceDuration, 0)
        XCTAssertEqual(audio.lastNonSilentTime, at(6))
    }

    func testFirstSilenceWithoutPriorActiveStartsTracking() {
        // Fresh Audio has lastNonSilentTime == nil. The first below-threshold
        // sample starts the clock instead of computing a bogus duration.
        let audio = makeAudio()
        XCTAssertNil(audio.lastNonSilentTime)

        audio.updateSilenceTracking(currentLevel: 0.0, now: at(3))

        XCTAssertTrue(audio.isSilent)
        XCTAssertEqual(audio.silenceDuration, 0)
        XCTAssertEqual(audio.lastNonSilentTime, at(3))

        // The next silent sample now measures against that anchor.
        audio.updateSilenceTracking(currentLevel: 0.0, now: at(8))
        XCTAssertEqual(audio.silenceDuration, 5, accuracy: 0.000_1)
    }

    func testResetClearsState() {
        let audio = makeAudio()
        audio.updateSilenceTracking(currentLevel: 0.0, now: at(2))   // dirty the state
        audio.updateSilenceTracking(currentLevel: 0.0, now: at(10))
        XCTAssertTrue(audio.isSilent)
        XCTAssertGreaterThan(audio.silenceDuration, 0)

        audio.resetSilenceTracking(now: at(20))

        XCTAssertFalse(audio.isSilent)
        XCTAssertEqual(audio.silenceDuration, 0)
        XCTAssertEqual(audio.lastNonSilentTime, at(20))
    }

    func testThresholdBoundaryIsStrictlyGreaterThan() {
        // updateSilenceTracking treats level > silenceThreshold (0.02) as audio.
        // A level exactly at the threshold counts as silence.
        let audio = makeAudio()
        audio.resetSilenceTracking(now: at(0))

        audio.updateSilenceTracking(currentLevel: 0.02, now: at(1))
        XCTAssertTrue(audio.isSilent, "level == threshold is treated as silence")

        audio.updateSilenceTracking(currentLevel: 0.0201, now: at(2))
        XCTAssertFalse(audio.isSilent, "level just above threshold is treated as audio")
    }
}
