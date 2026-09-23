import Foundation

func testUpdateActionSafetyPolicy() {
    runSuite("UpdateActionSafetyPolicy blocks update actions during active capture") {
        for state in [
            UpdateActionSafetyState.unknown,
            .readyToCheck,
            .noUpdateAvailable,
            .updateAvailable,
            .readyToInstall,
        ] {
            assertFalse(
                UpdateActionSafetyPolicy.canRunUserAction(
                    state: state,
                    sparkleCanRunUserAction: true,
                    availableUpdateDownloadsAutomatically: false,
                    isCaptureActive: true
                ),
                "state \(state) should wait until active capture finishes"
            )
            assertEqual(
                UpdateActionSafetyPolicy.captureSafetyHelp(
                    state: state,
                    isCaptureActive: true
                ),
                UpdateActionSafetyPolicy.activeCaptureHelp,
                "blocked update actions should explain the capture guard"
            )
        }
    }

    runSuite("UpdateActionSafetyPolicy leaves passive update progress states disabled by Sparkle") {
        assertFalse(
            UpdateActionSafetyPolicy.canRunUserAction(
                state: .checking,
                sparkleCanRunUserAction: false,
                availableUpdateDownloadsAutomatically: false,
                isCaptureActive: true
            ),
            "checking state should stay controlled by Sparkle readiness"
        )
        assertFalse(
            UpdateActionSafetyPolicy.canRunUserAction(
                state: .downloading,
                sparkleCanRunUserAction: false,
                availableUpdateDownloadsAutomatically: false,
                isCaptureActive: true
            ),
            "downloading state should stay controlled by Sparkle readiness"
        )
        assertNil(
            UpdateActionSafetyPolicy.captureSafetyHelp(
                state: .downloading,
                isCaptureActive: true
            ),
            "passive download progress should not show the active-capture block copy"
        )
    }

    runSuite("UpdateActionSafetyPolicy allows normal checks after capture ends") {
        assertTrue(
            UpdateActionSafetyPolicy.canRunUserAction(
                state: .readyToCheck,
                sparkleCanRunUserAction: true,
                availableUpdateDownloadsAutomatically: false,
                isCaptureActive: false
            ),
            "idle users should still be able to check for updates"
        )
        assertTrue(
            UpdateActionSafetyPolicy.canRunUserAction(
                state: .readyToInstall,
                sparkleCanRunUserAction: true,
                availableUpdateDownloadsAutomatically: false,
                isCaptureActive: false
            ),
            "idle users should still be able to restart into a ready update"
        )
    }

    runSuite("UpdateActionSafetyPolicy keeps automatic-download install buttons passive") {
        assertFalse(
            UpdateActionSafetyPolicy.canRunUserAction(
                state: .updateAvailable,
                sparkleCanRunUserAction: true,
                availableUpdateDownloadsAutomatically: true,
                isCaptureActive: false
            ),
            "automatic downloads should keep the install button passive while Sparkle prepares the update"
        )
    }

    runSuite("ReadyUpdateActionRoutingPolicy preserves a usable downloaded-update action") {
        assertEqual(
            ReadyUpdateActionRoutingPolicy.route(hasImmediateInstallHandler: true),
            .installImmediately,
            "a staged automatic update should use Sparkle's immediate install callback"
        )
        assertEqual(
            ReadyUpdateActionRoutingPolicy.route(hasImmediateInstallHandler: false),
            .presentStandardUpdateUI,
            "a resumed or authorization-required update should open Sparkle's standard UI"
        )
    }

    runSuite("UpdateAttentionPolicy badges any update that needs a click") {
        assertTrue(
            UpdateAttentionPolicy.needsUserAction(state: .readyToInstall, availableUpdateDownloadsAutomatically: true),
            "a downloaded update waiting for a restart should always show the badge"
        )
        assertTrue(
            UpdateAttentionPolicy.needsUserAction(state: .updateAvailable, availableUpdateDownloadsAutomatically: false),
            "an update Sparkle will not download on its own should show the badge right away, not stay hidden in the menu"
        )
        assertFalse(
            UpdateAttentionPolicy.needsUserAction(state: .updateAvailable, availableUpdateDownloadsAutomatically: true),
            "an update Sparkle is about to download stays quiet until it is ready to restart"
        )
        for state in [
            UpdateActionSafetyState.unknown,
            .readyToCheck,
            .checking,
            .noUpdateAvailable,
            .downloading,
        ] {
            assertFalse(
                UpdateAttentionPolicy.needsUserAction(state: state, availableUpdateDownloadsAutomatically: false),
                "state \(state) has nothing for the person to do"
            )
        }
    }

    runSuite("UpdateActionSafetyPolicy re-enables install when Sparkle will not download on its own") {
        assertTrue(
            UpdateActionSafetyPolicy.canRunUserAction(
                state: .updateAvailable,
                sparkleCanRunUserAction: true,
                availableUpdateDownloadsAutomatically: false,
                isCaptureActive: false
            ),
            "after a failed background download the Install button must work instead of waiting hours for the next check"
        )
    }
}
