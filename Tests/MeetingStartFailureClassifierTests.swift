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
}
