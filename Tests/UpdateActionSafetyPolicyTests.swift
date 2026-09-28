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

    runSuite("UpdateActionSafetyPolicy says what a blocked update is waiting on") {
        assertEqual(
            UpdateBlockedReason.current(isRecording: true, isTranscribing: true, isSpeakerReviewPending: true),
            .recording,
            "a live recording is the most important thing to name"
        )
        assertEqual(
            UpdateBlockedReason.current(isRecording: false, isTranscribing: true, isSpeakerReviewPending: true),
            .transcribing,
            "transcribing wins over a waiting speaker review"
        )
        assertEqual(
            UpdateBlockedReason.current(isRecording: false, isTranscribing: false, isSpeakerReviewPending: true),
            .speakerReview,
            "a waiting speaker review blocks updates and has to be named, or the row looks broken"
        )
        assertNil(
            UpdateBlockedReason.current(isRecording: false, isTranscribing: false, isSpeakerReviewPending: false),
            "nothing blocks an idle app"
        )
        assertEqual(
            UpdateActionSafetyPolicy.blockedDetail(state: .readyToInstall, reason: .recording),
            "After this recording finishes",
            "the recording line"
        )
        assertEqual(
            UpdateActionSafetyPolicy.blockedDetail(state: .updateAvailable, reason: .transcribing),
            "After transcribing finishes",
            "the transcribing line"
        )
        assertEqual(
            UpdateActionSafetyPolicy.blockedDetail(state: .readyToCheck, reason: .speakerReview),
            "Finish naming speakers first",
            "the speaker review line"
        )
        assertNil(
            UpdateActionSafetyPolicy.blockedDetail(state: .downloading, reason: .recording),
            "passive download progress is not blocked, so it keeps its own detail"
        )
        assertNil(
            UpdateActionSafetyPolicy.blockedDetail(state: .readyToInstall, reason: nil),
            "no reason, no override"
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

    runSuite("BackgroundUpdateDeferralPolicy holds big background downloads, never checks the person starts") {
        assertEqual(
            BackgroundUpdateDeferralPolicy.deferralReason(isBackgroundCheck: true, automaticDownloadsEnabled: true, isBusy: true, isOnCostlyNetwork: false),
            .busy,
            "a background download must not start during a meeting, dictation or transcription"
        )
        assertEqual(
            BackgroundUpdateDeferralPolicy.deferralReason(isBackgroundCheck: true, automaticDownloadsEnabled: true, isBusy: false, isOnCostlyNetwork: true),
            .costlyNetwork,
            "a ~500 MB download must not start on a hotspot or in Low Data Mode"
        )
        assertEqual(
            BackgroundUpdateDeferralPolicy.deferralReason(isBackgroundCheck: true, automaticDownloadsEnabled: true, isBusy: true, isOnCostlyNetwork: true),
            .busy,
            "busy wins so the reason reads the same whatever the network"
        )
        assertNil(
            BackgroundUpdateDeferralPolicy.deferralReason(isBackgroundCheck: true, automaticDownloadsEnabled: false, isBusy: true, isOnCostlyNetwork: true),
            "without automatic downloads the check only fetches the feed, so it should run"
        )
        assertNil(
            BackgroundUpdateDeferralPolicy.deferralReason(isBackgroundCheck: false, automaticDownloadsEnabled: true, isBusy: true, isOnCostlyNetwork: true),
            "a check the person starts is never deferred"
        )
        assertNil(
            BackgroundUpdateDeferralPolicy.deferralReason(isBackgroundCheck: true, automaticDownloadsEnabled: true, isBusy: false, isOnCostlyNetwork: false),
            "an idle Mac on a normal network downloads in the background"
        )
    }
}
