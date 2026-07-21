import Foundation

func testMeetingCaptureCompletionPolicy() {
    runSuite("MeetingCaptureCompletionPolicy accepts the current explicit stop") {
        assertEqual(
            MeetingCaptureCompletionPolicy.disposition(
                completionGeneration: 12,
                expectedStopGeneration: 12,
                timedOutStopGenerations: [],
                currentAudioGeneration: 12
            ),
            .expectedStop,
            "the completion for the current stop should resume its own continuation"
        )
    }

    runSuite("MeetingCaptureCompletionPolicy routes a timed-out stop completion") {
        assertEqual(
            MeetingCaptureCompletionPolicy.disposition(
                completionGeneration: 12,
                expectedStopGeneration: 12,
                timedOutStopGenerations: [12],
                currentAudioGeneration: 12
            ),
            .lateTimedOutStop,
            "a completion after the stop timeout should use the late-completion handler"
        )
    }

    runSuite("MeetingCaptureCompletionPolicy identifies an unexpected current stop") {
        assertEqual(
            MeetingCaptureCompletionPolicy.disposition(
                completionGeneration: 12,
                expectedStopGeneration: nil,
                timedOutStopGenerations: [],
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
                timedOutStopGenerations: [],
                currentAudioGeneration: 14
            ),
            .stale,
            "an older completion must not satisfy a newer recording stop"
        )
    }

    runSuite("MeetingCaptureCompletionPolicy keeps timed-out A separate from B") {
        assertEqual(
            MeetingCaptureCompletionPolicy.disposition(
                completionGeneration: 12,
                expectedStopGeneration: 14,
                timedOutStopGenerations: [12],
                currentAudioGeneration: 14
            ),
            .lateTimedOutStop,
            "A's late completion should stay owned by A while B is stopping"
        )
        assertEqual(
            MeetingCaptureCompletionPolicy.disposition(
                completionGeneration: 14,
                expectedStopGeneration: 14,
                timedOutStopGenerations: [12],
                currentAudioGeneration: 14
            ),
            .expectedStop,
            "B's completion should still resolve B's stop"
        )
    }
}
