// What onboarding does when its window's lifecycle moves, and what a finished
// system-audio check puts on screen. These replaced source-text pins on
// PermissionsOnboardingView.swift in UIAutomationSurfaceContractTests.swift.
// That the view never polls is checked by scripts/dev/check-banned-calls.py.

import Foundation

func testOnboardingPermissionLifecyclePolicy() {
    typealias Policy = OnboardingPermissionLifecyclePolicy
    typealias Access = TranscriptedPermissionAccess

    runSuite("Onboarding refreshes permissions when the app comes back or a permission changes") {
        let back = Policy.effects(for: .appBecameActive)
        assertTrue(back.contains(.refreshPermissions), "coming back from System Settings should re-read permissions")
        assertTrue(back.contains(.clearSystemSettingsHandoff), "coming back should end the System Settings handoff")
        assertTrue(
            Policy.effects(for: .permissionsChanged).contains(.refreshPermissions),
            "a permission change elsewhere in the app should re-read permissions"
        )
    }

    runSuite("Leaving onboarding cancels the audio check and reports abandonment") {
        let gone = Policy.effects(for: .windowDisappeared)
        assertTrue(gone.contains(.cancelSystemAudioCheck), "closing the window should cancel an in-flight audio check")
        assertTrue(gone.contains(.trackAbandonment), "closing the window should report abandonment")
        assertTrue(
            Policy.effects(for: .appWillTerminate).contains(.trackAbandonment),
            "quitting with onboarding open should report abandonment, since onDisappear won't fire"
        )
    }

    runSuite("Only leaving cancels the audio check, and nothing but its button starts one") {
        for event in Policy.Event.allCases where event != .windowDisappeared {
            assertFalse(
                Policy.effects(for: event).contains(.cancelSystemAudioCheck),
                "\(event) should not cancel a check the user started"
            )
        }
        assertFalse(
            Policy.effects(for: .appBecameActive).contains(.trackAbandonment),
            "coming back to the app is not abandoning onboarding"
        )
    }

    runSuite("A cancelled audio check's late result never reaches the screen") {
        let granted = Access.SystemAudioPermissionAccessDecision(canProceed: true, state: .granted, probeResult: .granted)
        assertNil(
            Policy.systemAudioCheckResult(granted, checkWasCancelled: true),
            "a check finishing after onboarding was left should change nothing"
        )
        assertEqual(
            Policy.systemAudioCheckResult(granted, checkWasCancelled: false),
            Policy.SystemAudioCheckResult(state: .granted, probeResult: .granted, isGranted: true),
            "a finished check should show its grant"
        )
    }

    runSuite("Onboarding keeps the typed audio check result instead of collapsing unknown into not granted") {
        let unsure = Access.SystemAudioPermissionAccessDecision(
            canProceed: false,
            state: .unknown,
            probeResult: .indeterminate(.timedOut)
        )
        let shown = Policy.systemAudioCheckResult(unsure, checkWasCancelled: false)
        assertEqual(shown?.probeResult, .indeterminate(.timedOut), "the probe class should reach the row so it can say the check was unsure")
        assertEqual(shown?.state, .unknown, "an unsure check should stay unknown, not become denied")
        assertEqual(shown?.isGranted, false, "an unsure check is not a grant")

        let denied = Access.SystemAudioPermissionAccessDecision(canProceed: false, state: .denied, probeResult: .explicitlyDenied)
        assertEqual(
            Policy.systemAudioCheckResult(denied, checkWasCancelled: false),
            Policy.SystemAudioCheckResult(state: .denied, probeResult: .explicitlyDenied, isGranted: false),
            "an explicit denial should show as denied"
        )
    }
}
