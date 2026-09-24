import Foundation

func testMeetingStopSnapshotEvidence() {
    typealias Status = MeetingSystemAudioStatusCopy.Case

    runSuite("MeetingCaptureHealthTelemetry — stop snapshot keeps a failure capture already reset") {
        assertEqual(
            MeetingCaptureHealthTelemetry.stopSnapshotSystemAudioStatus(
                live: Status.unknown, atCaptureStop: .failed, unknown: .unknown
            ),
            .failed,
            "an unexpected stop reports the status seen when capture stopped, not the reset"
        )
        assertEqual(
            MeetingCaptureHealthTelemetry.stopSnapshotSystemAudioStatus(
                live: Status.healthy, atCaptureStop: .failed, unknown: .unknown
            ),
            .healthy,
            "a live status still wins when capture has not reset it yet"
        )
        assertEqual(
            MeetingCaptureHealthTelemetry.stopSnapshotSystemAudioStatus(
                live: Status.unknown, atCaptureStop: nil, unknown: .unknown
            ),
            .unknown,
            "a normal stop with no captured evidence is unchanged"
        )
    }

    runSuite("MeetingCaptureHealthTelemetry — stop snapshot keeps the warning cleared at capture stop") {
        let interruption = MeetingSystemAudioDegradationWarning(
            cause: .interruption, phase: .degraded, isPromptDismissed: false
        )
        let silence = MeetingSystemAudioDegradationWarning(
            cause: .silence, phase: .degraded, isPromptDismissed: false
        )
        let phantomUnverified = MeetingSystemAudioDegradationWarning(
            cause: .unverified, phase: .degraded, isPromptDismissed: false
        )
        let restored = MeetingCaptureHealthTelemetry.stopSnapshotDegradationWarning(
            live: nil, atCaptureStop: interruption
        )
        assertEqual(restored, interruption, "the cleared warning comes back for the snapshot")
        assertTrue(restored?.degradesSavedCapture == true, "so the saved capture is still marked degraded")
        assertEqual(
            MeetingCaptureHealthTelemetry.stopSnapshotDegradationWarning(
                live: phantomUnverified, atCaptureStop: interruption
            ),
            interruption,
            "a fresh unverified warning raised by the status reset cannot hide the interruption"
        )
        assertEqual(
            MeetingCaptureHealthTelemetry.stopSnapshotDegradationWarning(live: interruption, atCaptureStop: silence),
            interruption,
            "a live warning wins over a non-degrading one from capture stop"
        )
        assertEqual(
            MeetingCaptureHealthTelemetry.stopSnapshotDegradationWarning(live: interruption, atCaptureStop: nil),
            interruption,
            "a normal stop with no captured evidence is unchanged"
        )
        assertNil(
            MeetingCaptureHealthTelemetry.stopSnapshotDegradationWarning(live: nil, atCaptureStop: nil),
            "no warning either way stays nil"
        )
    }

    runSuite("MeetingSessionController — unexpected stop evidence is captured before the warning clears") {
        let source = readSourceFixture(
            "Sources/Meeting/MeetingSessionController.swift",
            description: "MeetingSessionController.swift"
        )
        guard let stash = source.range(of: "self.unexpectedCaptureStopEvidence = ("),
              let clear = source.range(
                of: "self.systemAudioDegradationWarning = nil",
                range: stash.upperBound..<source.endIndex
              ) else {
            assertTrue(false, "the capture-stop sink must stash evidence and then clear the warning")
            return
        }
        assertTrue(stash.lowerBound < clear.lowerBound, "evidence must be stashed before the warning is cleared")
        assertTrue(
            source.contains("atCaptureStop: atCaptureStop?.systemAudioStatus")
                && source.contains("atCaptureStop: atCaptureStop?.degradationWarning"),
            "the stop snapshot must read the stashed evidence"
        )
    }
}
