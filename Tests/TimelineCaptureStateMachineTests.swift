import Foundation

func testTimelineCaptureStateMachine() {
    runSuite("Timeline capture blocklist normalization dedups and ignores case folding") {
        assertEqual(
            TimelineCaptureBlocklist.normalizedBundleIdentifiers([]),
            [],
            "empty input should normalize to an empty set"
        )
        assertEqual(
            TimelineCaptureBlocklist.normalizedBundleIdentifiers([
                "com.example.App",
                " com.example.App ",
                "com.example.App"
            ]),
            ["com.example.App"],
            "exact and whitespace-padded duplicates should collapse to a single entry"
        )
        assertEqual(
            TimelineCaptureBlocklist.normalizedBundleIdentifiers(["com.example.App", "com.EXAMPLE.app"]),
            ["com.example.App", "com.EXAMPLE.app"],
            "normalization only trims whitespace, it does not case-fold, so differently-cased identifiers stay distinct"
        )
    }

    runSuite("Timeline capture state machine start/stop/resume cover every branch") {
        var machine = TimelineCaptureStateMachine()

        machine.start(permissionGranted: true)
        assertEqual(machine.state, .starting, "granted permission should move idle straight to starting")

        machine.stop()
        assertEqual(machine.state, .idle, "stop should always return to idle")

        machine.resume(permissionGranted: true)
        assertEqual(machine.state, .idle, "resume should be a no-op unless the machine is currently paused")

        machine.start(permissionGranted: true)
        machine.markCapturing()
        machine.resume(permissionGranted: false)
        assertEqual(machine.state, .capturing, "resume should not interrupt an active capturing state")

        machine.pause(.sleep)
        assertEqual(machine.state, .paused(.sleep), "pause should record the given reason")
        machine.resume(permissionGranted: false)
        assertEqual(
            machine.state,
            .paused(.permissionDenied),
            "resuming a pause without permission should land on permissionDenied rather than restarting"
        )

        machine.resume(permissionGranted: true)
        assertEqual(machine.state, .starting, "resuming a pause with permission granted should move back to starting")
        machine.markCapturing()
        machine.stop()
        assertEqual(machine.state, .idle, "stop should override an active capture back to idle")
    }

    runSuite("Timeline capture state machine pause reasons round-trip through state") {
        let reasons: [ScreenCapturePauseReason] = [
            .sleep, .screenLock, .screensaver, .permissionDenied, .permissionRevoked, .userPause
        ]
        for reason in reasons {
            var machine = TimelineCaptureStateMachine()
            machine.start(permissionGranted: true)
            machine.markCapturing()
            machine.pause(reason)
            assertEqual(machine.state, .paused(reason), "pausing with \(reason) should yield paused(\(reason))")
        }
    }

    runSuite("Timeline capture resume delay is defined for every pause reason") {
        assertEqual(
            TimelineCaptureStateMachine.resumeDelay(after: .permissionDenied),
            nil,
            "denied permission should never auto-resume; the caller must re-probe instead"
        )
    }
}
