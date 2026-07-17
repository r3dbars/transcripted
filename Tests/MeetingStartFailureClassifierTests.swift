import Foundation

func testMeetingStartFailureClassifier() {
    runSuite("MeetingStartFailureClassifier classifies missing permission") {
        assertEqual(
            MeetingStartFailureClassifier.kind(from: "Microphone permission was not granted."),
            "permission_missing",
            "permission wording should win over the later microphone branch"
        )
    }

    runSuite("MeetingStartFailureClassifier classifies start timeouts") {
        assertEqual(
            MeetingStartFailureClassifier.kind(from: "Recording start timeout was exceeded."),
            "start_timeout",
            "timeout wording should map to start_timeout"
        )
        assertEqual(
            MeetingStartFailureClassifier.kind(from: "The recording timed out before it could start."),
            "start_timeout",
            "'timed out' wording should also map to start_timeout"
        )
    }

    runSuite("MeetingStartFailureClassifier classifies unavailable system stream") {
        assertEqual(
            MeetingStartFailureClassifier.kind(from: "System audio capture could not start."),
            "system_stream_unavailable",
            "system audio failures should keep their own analytics bucket"
        )
    }

    runSuite("MeetingStartFailureClassifier classifies unavailable microphone") {
        assertEqual(
            MeetingStartFailureClassifier.kind(from: "The microphone could not be opened."),
            "mic_unavailable",
            "microphone wording should map to mic_unavailable"
        )
        assertEqual(
            MeetingStartFailureClassifier.kind(from: "No mic device was found."),
            "mic_unavailable",
            "short 'mic' wording should also map to mic_unavailable"
        )
    }

    runSuite("MeetingStartFailureClassifier falls back to unexpected") {
        assertEqual(
            MeetingStartFailureClassifier.kind(from: "Something odd happened while starting the meeting."),
            "unexpected",
            "unknown start failures should keep the explicit unexpected bucket"
        )
    }

    runSuite("MeetingSystemAudioStatusCopy maps every status to stable copy") {
        assertEqual(
            MeetingSystemAudioStatusCopy.message(for: MeetingSystemAudioStatusCopy.Case.unknown),
            "System audio status reset",
            "unknown status copy is telemetry-visible and must not drift"
        )
        assertEqual(
            MeetingSystemAudioStatusCopy.message(for: MeetingSystemAudioStatusCopy.Case.healthy),
            "System audio capture is healthy",
            "healthy status copy is telemetry-visible and must not drift"
        )
        assertEqual(
            MeetingSystemAudioStatusCopy.message(for: MeetingSystemAudioStatusCopy.Case.reconnecting),
            "System audio capture is reconnecting",
            "reconnecting status copy is telemetry-visible and must not drift"
        )
        assertEqual(
            MeetingSystemAudioStatusCopy.message(for: MeetingSystemAudioStatusCopy.Case.silent),
            "System audio capture is silent",
            "silent status copy is telemetry-visible and must not drift"
        )
        assertEqual(
            MeetingSystemAudioStatusCopy.message(for: MeetingSystemAudioStatusCopy.Case.failed),
            "System audio capture failed",
            "failed status copy is telemetry-visible and must not drift"
        )
    }

    runSuite("Meeting system-audio degradation warning stays latched through recovery") {
        let recovering = MeetingSystemAudioDegradationPolicy.next(
            current: nil,
            status: .reconnecting,
            isRecording: true
        )
        assertEqual(
            recovering?.cause,
            MeetingSystemAudioDegradationWarning.Cause.interruption,
            "a hard stream interruption should raise the interruption warning"
        )
        assertEqual(
            recovering?.phase,
            MeetingSystemAudioDegradationWarning.Phase.recovering,
            "the first warning should say recovery is in progress"
        )
        assertTrue(recovering?.shouldPresentPrompt == true, "the interruption warning should present immediately")

        let recovered = MeetingSystemAudioDegradationPolicy.next(
            current: recovering,
            status: .healthy,
            isRecording: true
        )
        assertEqual(
            recovered?.phase,
            MeetingSystemAudioDegradationWarning.Phase.recovered,
            "a healthy status should retain the warning and label it recovered"
        )
        assertTrue(recovered?.shouldPresentPrompt == true, "recovery should not hide the warning before acknowledgement")

        let dismissed = recovered?.dismissingPrompt()
        assertTrue(dismissed?.shouldPresentPrompt == false, "acknowledgement should hide only the prompt")
        assertTrue(dismissed != nil, "acknowledgement must keep the recording-scoped warning latch")

        let terminalFailure = MeetingSystemAudioDegradationPolicy.next(
            current: dismissed,
            status: .failed,
            isRecording: true
        )
        assertTrue(terminalFailure?.shouldPresentPrompt == true, "a later terminal failure should alert again")
    }

    runSuite("Meeting system-audio silence uses a persistent nonmodal warning") {
        let silent = MeetingSystemAudioDegradationPolicy.next(
            current: nil,
            status: .silent,
            isRecording: true
        )
        assertEqual(
            silent?.cause,
            MeetingSystemAudioDegradationWarning.Cause.silence,
            "prolonged system silence should create a warning latch"
        )
        assertTrue(silent?.shouldPresentPrompt == false, "ordinary silence should not force a capture restart or modal prompt")

        let recovered = MeetingSystemAudioDegradationPolicy.next(
            current: silent,
            status: .healthy,
            isRecording: true
        )
        assertEqual(
            recovered?.phase,
            MeetingSystemAudioDegradationWarning.Phase.recovered,
            "audible system audio should mark the latched warning recovered"
        )
        assertEqual(
            MeetingSystemAudioDegradationPolicy.next(
                current: recovered,
                status: .healthy,
                isRecording: false
            ),
            nil,
            "the persistent warning should clear when recording ends"
        )
    }

    runSuite("Meeting system-audio warning survives unknown status only while recording") {
        let degraded = MeetingSystemAudioDegradationPolicy.next(
            current: nil,
            status: .failed,
            isRecording: true
        )
        assertEqual(
            MeetingSystemAudioDegradationPolicy.next(
                current: degraded,
                status: .unknown,
                isRecording: true
            ),
            degraded,
            "unknown status should not erase an observed recording degradation"
        )
        assertEqual(
            MeetingSystemAudioDegradationPolicy.next(
                current: degraded,
                status: .unknown,
                isRecording: false
            ),
            nil,
            "recording teardown should still clear the warning latch"
        )
    }

    runSuite("Meeting audio-inactivity warning has prompt precedence") {
        let warning = MeetingSystemAudioDegradationPolicy.next(
            current: nil,
            status: .failed,
            isRecording: true
        )
        assertTrue(
            !MeetingSystemAudioPromptPolicy.shouldPresentSystemAudioPrompt(
                warning: warning,
                hasAudioInactivityWarning: true
            ),
            "system degradation should stay latched without replacing an inactivity prompt"
        )
        assertTrue(
            MeetingSystemAudioPromptPolicy.shouldPresentSystemAudioPrompt(
                warning: warning,
                hasAudioInactivityWarning: false
            ),
            "the latched system warning should present after inactivity clears"
        )
        assertTrue(
            !MeetingSystemAudioPromptPolicy.shouldPresentSystemAudioPrompt(
                warning: warning?.dismissingPrompt(),
                hasAudioInactivityWarning: false
            ),
            "an acknowledged system warning should remain icon-only"
        )
    }

    runSuite("Mic-only finalized recordings still await the durable sidecar transcript") {
        assertTrue(
            MeetingRecordingFinalizationPolicy.shouldAwaitLiveCodexFinalTranscript(
                micFilePresent: true,
                systemFilePresent: false,
                stopTimedOut: false
            ),
            "a finalized mic file is enough for the supported mic-only transcript pipeline"
        )
        assertTrue(
            MeetingRecordingFinalizationPolicy.shouldAwaitLiveCodexFinalTranscript(
                micFilePresent: true,
                systemFilePresent: true,
                stopTimedOut: false
            ),
            "a normal two-track recording should still await its final transcript"
        )
        assertTrue(
            !MeetingRecordingFinalizationPolicy.shouldAwaitLiveCodexFinalTranscript(
                micFilePresent: false,
                systemFilePresent: true,
                stopTimedOut: false
            ),
            "a recording without finalized mic audio must fail the live sidecar"
        )
        assertTrue(
            !MeetingRecordingFinalizationPolicy.shouldAwaitLiveCodexFinalTranscript(
                micFilePresent: true,
                systemFilePresent: false,
                stopTimedOut: true
            ),
            "a timed-out WAV finalization must not attach an unsafe transcript"
        )
    }
}
