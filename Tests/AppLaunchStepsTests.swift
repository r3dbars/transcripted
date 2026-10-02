import Foundation

// Launch offers to finish a dictation whose audio was saved at Stop but never
// transcribed. The app delegate runs AppLaunchSteps after the overlay is set
// up; this drives the same list on a fake dictation host.

@MainActor
private final class FakeLaunchDictationHost: AppLaunchDictationHost {
    var stoppedAudioScans = 0

    func presentPendingStoppedAudioRecoveryIfNeeded() {
        stoppedAudioScans += 1
    }
}

@MainActor
func testAppLaunchSteps() async {
    runSuite("Launch scans once for pending stopped dictation audio") {
        assertTrue(
            AppLaunchSteps.afterOverlaySetup.contains(.pendingStoppedAudioRecovery),
            "launch should include the pending stopped-audio scan"
        )

        let host = FakeLaunchDictationHost()
        let ran = AppLaunchSteps.runAfterOverlaySetup(dictation: host)

        assertEqual(ran, AppLaunchSteps.afterOverlaySetup, "every listed launch step should run")
        assertEqual(host.stoppedAudioScans, 1, "launch should scan for pending stopped audio exactly once")
    }
}
