import XCTest
@testable import TranscriptedCore

/// Pins the bounded meeting-start fallback decision for the "Apple voice
/// processing was requested but did not become active" state (the Bentley
/// 2026-08-03 start failure: built-in mic, permissions granted, VPIO
/// requested/inactive, `recovery_attempt_count=0`, classified
/// `mic_unavailable`).
///
/// The real retry loop (`Audio.makeReadyMeetingInputGraph`) needs a live
/// `AVAudioEngine`, which this test target does not construct; the loop
/// consults exactly this pure policy, so these tests pin the recoverable
/// state, the one-attempt bound, and every non-engaging state.
final class VoiceProcessingStartFallbackPolicyTests: XCTestCase {

    func testRequestedButInactiveSelectsTheFallback() {
        XCTAssertTrue(
            VoiceProcessingStartFallbackPolicy.shouldRetryWithoutVoiceProcessing(
                voiceProcessingRequested: true,
                previousAttemptVoiceProcessingActive: false,
                fallbackAlreadyEngaged: false
            ),
            "VPIO requested but inactive on the failed attempt is the narrow recoverable state"
        )
    }

    func testFallbackIsBoundedToOneAttempt() {
        XCTAssertFalse(
            VoiceProcessingStartFallbackPolicy.shouldRetryWithoutVoiceProcessing(
                voiceProcessingRequested: true,
                previousAttemptVoiceProcessingActive: false,
                fallbackAlreadyEngaged: true
            ),
            "once engaged, the fallback must never re-arm another retry"
        )
    }

    func testVoiceProcessingOffNeverEngagesTheFallback() {
        XCTAssertFalse(
            VoiceProcessingStartFallbackPolicy.shouldRetryWithoutVoiceProcessing(
                voiceProcessingRequested: false,
                previousAttemptVoiceProcessingActive: false,
                fallbackAlreadyEngaged: false
            ),
            "software-AGC/raw users already run the non-VPIO path; their retry behavior must not change"
        )
    }

    func testActiveVoiceProcessingFailuresKeepTheNormalRetry() {
        XCTAssertFalse(
            VoiceProcessingStartFallbackPolicy.shouldRetryWithoutVoiceProcessing(
                voiceProcessingRequested: true,
                previousAttemptVoiceProcessingActive: true,
                fallbackAlreadyEngaged: false
            ),
            "when VPIO armed fine, the failure is elsewhere (route flap, format) and the retry should keep the user's requested mode"
        )
    }

    func testNoArmedAttemptYetKeepsTheNormalRetry() {
        XCTAssertFalse(
            VoiceProcessingStartFallbackPolicy.shouldRetryWithoutVoiceProcessing(
                voiceProcessingRequested: true,
                previousAttemptVoiceProcessingActive: nil,
                fallbackAlreadyEngaged: false
            ),
            "a failure before arming (selection abort, stale session) says nothing about VPIO"
        )
    }

    func testFallbackStateRawValuesAreStableForTelemetry() {
        XCTAssertEqual(VoiceProcessingStartFallbackState.none.rawValue, "none")
        XCTAssertEqual(VoiceProcessingStartFallbackState.attempted.rawValue, "attempted")
    }

    /// The fallback must not weaken start readiness: even with the fallback
    /// engaged, capture only reports ready once both taps stream. The fallback
    /// path feeds the same `meetingCaptureOutcome` latches, so a fallback that
    /// installs a tap but never delivers a mic frame still fails the deadline.
    func testFallbackPathStillRequiresBothStreamsForReadiness() {
        let micURL = URL(fileURLWithPath: "/tmp/mic.wav")
        let systemURL = URL(fileURLWithPath: "/tmp/system.wav")

        XCTAssertEqual(
            AudioCaptureStartState.meetingCaptureOutcome(
                isRecording: true,
                micAudioFileURL: micURL,
                micAudioStreaming: false,
                systemAudioFileURL: systemURL,
                systemAudioStreaming: true,
                errorMessage: nil
            ),
            .waiting,
            "a fallback graph with no mic frames must stay waiting, never ready"
        )
        XCTAssertEqual(
            AudioCaptureStartState.meetingCaptureOutcome(
                isRecording: true,
                micAudioFileURL: micURL,
                micAudioStreaming: true,
                systemAudioFileURL: systemURL,
                systemAudioStreaming: true,
                errorMessage: nil
            ),
            .ready,
            "a fallback graph that streams both sources reaches normal readiness"
        )
    }
}
