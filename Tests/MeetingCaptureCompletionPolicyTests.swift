import Foundation

func testMeetingCaptureCompletionPolicy() {
    runSuite("MeetingCaptureCompletionPolicy accepts the current explicit stop") {
        assertEqual(
            MeetingCaptureCompletionPolicy.disposition(
                completionGeneration: 12,
                expectedStopGeneration: 12,
                currentAudioGeneration: 12
            ),
            .expectedStop,
            "the completion for the current stop should resume its own continuation"
        )
    }

    runSuite("MeetingCaptureCompletionPolicy identifies an unexpected current stop") {
        assertEqual(
            MeetingCaptureCompletionPolicy.disposition(
                completionGeneration: 12,
                expectedStopGeneration: nil,
                currentAudioGeneration: 12
            ),
            .unexpectedCurrentStop,
            "a current-session completion without a pending stop should use recovery"
        )
    }

    runSuite("MeetingCaptureCompletionPolicy ignores a completion from an older recording") {
        assertEqual(
            MeetingCaptureCompletionPolicy.disposition(
                completionGeneration: 12,
                expectedStopGeneration: 14,
                currentAudioGeneration: 14
            ),
            .stale,
            "an older completion must not satisfy a newer recording stop"
        )
    }

}
