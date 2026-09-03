import Foundation
import XCTest
@testable import TranscriptedCore

final class AudioCaptureStartStateTests: XCTestCase {
    private let micURL = URL(fileURLWithPath: "/tmp/mic.wav")
    private let systemURL = URL(fileURLWithPath: "/tmp/system.wav")

    func testSystemFramesWithoutMicFramesStayWaiting() {
        let outcome = AudioCaptureStartState.meetingCaptureOutcome(
            isRecording: true,
            micAudioFileURL: micURL,
            micAudioStreaming: false,
            systemAudioFileURL: systemURL,
            systemAudioStreaming: true,
            errorMessage: nil
        )

        XCTAssertEqual(
            outcome,
            .waiting,
            "A system stream must not make a header-only mic file look like a valid meeting recording."
        )
    }

    func testBothSourcesMustStreamBeforeCaptureIsReady() {
        let outcome = AudioCaptureStartState.meetingCaptureOutcome(
            isRecording: true,
            micAudioFileURL: micURL,
            micAudioStreaming: true,
            systemAudioFileURL: systemURL,
            systemAudioStreaming: true,
            errorMessage: nil
        )

        XCTAssertEqual(outcome, .ready)
    }

    func testMicReadinessTimeoutNamesTheMissingSource() {
        XCTAssertEqual(
            AudioCaptureStartState.timeoutFailureMessage(
                existingErrorMessage: nil,
                micAudioStreaming: false,
                systemAudioStreaming: true
            ),
            "Microphone capture did not become ready in time. Check your input device, then try again."
        )
    }

    func testReadinessTimeoutStageNamesTheMissingSource() {
        XCTAssertEqual(
            AudioCaptureStartState.timeoutFailureStage(
                micAudioStreaming: false,
                systemAudioStreaming: true
            ),
            .microphoneGraph
        )
        XCTAssertEqual(
            AudioCaptureStartState.timeoutFailureStage(
                micAudioStreaming: true,
                systemAudioStreaming: false
            ),
            .systemAudio
        )
        XCTAssertEqual(
            AudioCaptureStartState.timeoutFailureStage(
                micAudioStreaming: false,
                systemAudioStreaming: false
            ),
            .unknown
        )
    }
}
