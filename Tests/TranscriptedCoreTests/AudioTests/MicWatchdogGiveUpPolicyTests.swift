import XCTest
@testable import TranscriptedCore

/// A microphone that won't come back must not end a meeting whose system
/// audio is still recording (APPLE-MACOS-2D, `device_switches` stops).
final class MicWatchdogGiveUpPolicyTests: XCTestCase {

    func testRetriesOnTheNormalCooldownUnderTheLimit() {
        XCTAssertEqual(
            MicWatchdogGiveUpPolicy.decision(
                recoveryAttemptsUsed: 4,
                maxRecoveryAttempts: 5,
                normalCooldown: 5,
                recordingCapturesSystemAudio: true,
                systemAudioFailed: false
            ),
            .retry(cooldown: 5)
        )
    }

    func testLostMicKeepsTheMeetingWhileSystemAudioRecords() {
        XCTAssertEqual(
            MicWatchdogGiveUpPolicy.decision(
                recoveryAttemptsUsed: 5,
                maxRecoveryAttempts: 5,
                normalCooldown: 5,
                recordingCapturesSystemAudio: true,
                systemAudioFailed: false
            ),
            .keepRecordingWithoutMic(retryCooldown: MicWatchdogGiveUpPolicy.slowRetryCooldownSeconds),
            "the other side of the call is still being recorded, so the meeting goes on"
        )
    }

    func testKeepsRetryingSlowlyPastTheLimit() {
        XCTAssertEqual(
            MicWatchdogGiveUpPolicy.decision(
                recoveryAttemptsUsed: 9,
                maxRecoveryAttempts: 5,
                normalCooldown: 5,
                recordingCapturesSystemAudio: true,
                systemAudioFailed: false
            ),
            .keepRecordingWithoutMic(retryCooldown: MicWatchdogGiveUpPolicy.slowRetryCooldownSeconds),
            "a headset that reconnects later can still rejoin the recording"
        )
        XCTAssertGreaterThan(MicWatchdogGiveUpPolicy.slowRetryCooldownSeconds, 5)
    }

    func testStopsWhenSystemAudioHasFailedToo() {
        XCTAssertEqual(
            MicWatchdogGiveUpPolicy.decision(
                recoveryAttemptsUsed: 5,
                maxRecoveryAttempts: 5,
                normalCooldown: 5,
                recordingCapturesSystemAudio: true,
                systemAudioFailed: true
            ),
            .stopRecording
        )
    }

    func testStopsAMicOnlyRecording() {
        XCTAssertEqual(
            MicWatchdogGiveUpPolicy.decision(
                recoveryAttemptsUsed: 5,
                maxRecoveryAttempts: 5,
                normalCooldown: 5,
                recordingCapturesSystemAudio: false,
                systemAudioFailed: false
            ),
            .stopRecording,
            "with no system audio there is nothing left to record"
        )
    }
}
