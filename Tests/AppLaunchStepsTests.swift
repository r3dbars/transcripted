import Foundation

// Launch deletes dictation audio left by an earlier run and never asks about
// it. The app delegate runs AppLaunchSteps after the overlay is set up; this
// drives the same list on a fake dictation host. What the cleanup deletes is
// tested in DictationStoppedAudioRecoveryTests.

@MainActor
private final class FakeLaunchDictationHost: AppLaunchDictationHost {
    var leftoverCleanups = 0

    func purgeLeftoverStoppedAudio() {
        leftoverCleanups += 1
    }
}

@MainActor
func testAppLaunchSteps() async {
    runSuite("Launch cleans up leftover dictation audio once") {
        assertEqual(
            AppLaunchSteps.afterOverlaySetup,
            [.leftoverStoppedAudioCleanup],
            "launch's only dictation step is the leftover-audio cleanup, with no saved-recording prompt"
        )

        let host = FakeLaunchDictationHost()
        let ran = AppLaunchSteps.runAfterOverlaySetup(dictation: host)

        assertEqual(ran, AppLaunchSteps.afterOverlaySetup, "every listed launch step should run")
        assertEqual(host.leftoverCleanups, 1, "launch should clean up leftover dictation audio exactly once")
    }
}
