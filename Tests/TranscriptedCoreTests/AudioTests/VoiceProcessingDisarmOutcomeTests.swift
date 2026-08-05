import XCTest
@testable import TranscriptedCore

/// Pins `Audio.voiceProcessingEnabledAfterDisarmAttempt(engineIsRunning:priorVoiceProcessingEnabled:)`,
/// the pure decision `armVoiceProcessing(on:)`'s preference-off branch uses
/// to compute the `VoiceProcessingBindResult` it returns.
///
/// `armVoiceProcessing`/`disarmVoiceProcessing` themselves need a live
/// `AVAudioInputNode` to exercise, which this test directory does not
/// construct (no precedent for `AVAudioEngine`/`.inputNode` anywhere under
/// `Tests/TranscriptedCoreTests/AudioTests/`) — matching that convention, we
/// pin the extracted pure decision instead of the arm/disarm branches
/// themselves. Residual gap: these tests do not exercise
/// `disarmVoiceProcessing`'s real CoreAudio calls or `armVoiceProcessing`'s
/// full branch dispatch end to end, only the value logic that branch relies
/// on; if `disarmVoiceProcessing`'s own branching on
/// `engine.isRunning`/`voiceProcessingEnabled` ever changes without updating
/// this mirror, these tests cannot detect the drift.
final class VoiceProcessingDisarmOutcomeTests: XCTestCase {
    /// Codex review regression case for PR #1641: preference toggled off
    /// mid-session while VPIO is still armed and the engine is running.
    /// `disarmVoiceProcessing` returns immediately in that state without
    /// touching `voiceProcessingEnabled` — the cache stays `true` — so the
    /// bind result `armVoiceProcessing` returns must also be `true`. A
    /// hard-coded `false` here would flip `recordingFormat`/`routeReadiness`
    /// in the exact path the 1.1.52 fix hardened.
    func testEngineRunningLeavesPriorCacheValueUnchanged() {
        XCTAssertTrue(
            Audio.voiceProcessingEnabledAfterDisarmAttempt(
                engineIsRunning: true,
                priorVoiceProcessingEnabled: true
            )
        )
        XCTAssertFalse(
            Audio.voiceProcessingEnabledAfterDisarmAttempt(
                engineIsRunning: true,
                priorVoiceProcessingEnabled: false
            )
        )
    }

    /// Every other path through `disarmVoiceProcessing` — engine stopped —
    /// unconditionally ends with `voiceProcessingEnabled = false`, whether
    /// or not VPIO was previously armed and regardless of whether the real
    /// `setVoiceProcessingEnabled(false)` call succeeds.
    func testEngineStoppedAlwaysClearsToFalseRegardlessOfPriorValue() {
        XCTAssertFalse(
            Audio.voiceProcessingEnabledAfterDisarmAttempt(
                engineIsRunning: false,
                priorVoiceProcessingEnabled: true
            )
        )
        XCTAssertFalse(
            Audio.voiceProcessingEnabledAfterDisarmAttempt(
                engineIsRunning: false,
                priorVoiceProcessingEnabled: false
            )
        )
    }
}
