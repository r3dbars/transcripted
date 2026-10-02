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

    runSuite("Capture stop — evidence is stashed before the live warnings are torn down") {
        // A fake capture that resets its status and clears the warning when
        // torn down, the way the real stop does.
        let interruption = MeetingSystemAudioDegradationWarning(
            cause: .interruption, phase: .degraded, isPromptDismissed: false
        )
        var liveStatus = Status.failed
        var liveWarning: MeetingSystemAudioDegradationWarning? = interruption
        var unheardStartedAt: Date? = Date(timeIntervalSince1970: 1_000)
        let stopAt = Date(timeIntervalSince1970: 1_045)
        var events: [String] = []
        var stashed: MeetingCaptureStopEvidence<Status>?

        let tornDown = MeetingCaptureHealthTelemetry.captureStopped(
            whileRecording: true,
            readEvidence: { () -> MeetingCaptureStopEvidence<Status> in
                events.append("read")
                return MeetingCaptureStopEvidence(
                    systemAudioStatus: liveStatus,
                    degradationWarning: liveWarning,
                    unheardWarningStartedAt: unheardStartedAt,
                    now: stopAt
                )
            },
            stashEvidence: { evidence in
                events.append("stash")
                stashed = evidence
            },
            tearDown: { () -> String in
                events.append("tear_down")
                liveStatus = .unknown
                liveWarning = nil
                unheardStartedAt = nil
                return "inactivity_stopped"
            }
        )

        assertEqual(events, ["read", "stash", "tear_down"], "evidence must be read and stashed before the warning clears")
        assertEqual(tornDown, "inactivity_stopped", "the teardown result still comes back to the caller")
        assertEqual(stashed?.systemAudioStatus, .failed, "the stash keeps the status seen before the reset")
        assertEqual(stashed?.degradationWarning, interruption, "the stash keeps the warning seen before it cleared")
        assertEqual(stashed?.unheardSeconds, 45, "how long call audio went unheard is stashed with the rest")

        // The snapshot taken after the reset reads the stash.
        let snapshot = MeetingCaptureHealthTelemetry.stopSnapshotEvidence(
            liveStatus: liveStatus,
            unknown: .unknown,
            liveWarning: liveWarning,
            liveUnheardWarningStartedAt: unheardStartedAt,
            atCaptureStop: stashed,
            now: Date(timeIntervalSince1970: 1_100)
        )
        assertEqual(snapshot.systemAudioStatus, .failed, "the stop snapshot reads the stashed status")
        assertEqual(snapshot.degradationWarning, interruption, "the stop snapshot reads the stashed warning")
        assertEqual(snapshot.unheardSeconds, 45, "the stop snapshot prefers the stashed unheard time")
    }

    runSuite("Capture stop — an expected stop stashes nothing and the snapshot reads live values") {
        var events: [String] = []
        _ = MeetingCaptureHealthTelemetry.captureStopped(
            whileRecording: false,
            readEvidence: { () -> MeetingCaptureStopEvidence<Status> in
                events.append("read")
                return MeetingCaptureStopEvidence(
                    systemAudioStatus: .healthy, degradationWarning: nil, unheardWarningStartedAt: nil, now: Date()
                )
            },
            stashEvidence: { _ in events.append("stash") },
            tearDown: { events.append("tear_down") }
        )
        assertEqual(events, ["tear_down"], "a stop the controller asked for has no evidence to keep")

        let snapshot = MeetingCaptureHealthTelemetry.stopSnapshotEvidence(
            liveStatus: Status.healthy,
            unknown: .unknown,
            liveWarning: nil,
            liveUnheardWarningStartedAt: Date(timeIntervalSince1970: 2_000),
            atCaptureStop: nil,
            now: Date(timeIntervalSince1970: 2_030)
        )
        assertEqual(snapshot.systemAudioStatus, .healthy)
        assertNil(snapshot.degradationWarning)
        assertEqual(snapshot.unheardSeconds, 30, "with no stash the live unheard timer counts")

        let nothingOpen = MeetingCaptureHealthTelemetry.stopSnapshotEvidence(
            liveStatus: Status.healthy,
            unknown: .unknown,
            liveWarning: nil,
            liveUnheardWarningStartedAt: nil,
            atCaptureStop: nil,
            now: Date()
        )
        assertEqual(nothingOpen.unheardSeconds, 0, "no unheard warning means zero unheard time")
    }
}
