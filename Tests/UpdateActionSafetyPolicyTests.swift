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
                    automaticDownloadsEnabled: false,
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
                automaticDownloadsEnabled: false,
                isCaptureActive: true
            ),
            "checking state should stay controlled by Sparkle readiness"
        )
        assertFalse(
            UpdateActionSafetyPolicy.canRunUserAction(
                state: .downloading,
                sparkleCanRunUserAction: false,
                automaticDownloadsEnabled: false,
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
                automaticDownloadsEnabled: false,
                isCaptureActive: false
            ),
            "idle users should still be able to check for updates"
        )
        assertTrue(
            UpdateActionSafetyPolicy.canRunUserAction(
                state: .readyToInstall,
                sparkleCanRunUserAction: true,
                automaticDownloadsEnabled: false,
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
                automaticDownloadsEnabled: true,
                isCaptureActive: false
            ),
            "automatic downloads should keep the install button passive while Sparkle prepares the update"
        )
    }
}
