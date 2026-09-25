import Foundation

func testLaunchAtLoginPreferences() {
    runSuite("LaunchWindowPolicy opens Home on a manual launch only") {
        assertTrue(
            LaunchWindowPolicy.shouldOpenMainWindow(
                launchedAsLoginItem: false, onboardingCompleted: true, isAutomatedLaunch: false
            ),
            "opening the app yourself should show the main window"
        )
        assertFalse(
            LaunchWindowPolicy.shouldOpenMainWindow(
                launchedAsLoginItem: true, onboardingCompleted: true, isAutomatedLaunch: false
            ),
            "a start at login should stay quietly in the menu bar"
        )
        assertFalse(
            LaunchWindowPolicy.shouldOpenMainWindow(
                launchedAsLoginItem: false, onboardingCompleted: false, isAutomatedLaunch: false
            ),
            "unfinished setup shows the setup window instead"
        )
        assertFalse(
            LaunchWindowPolicy.shouldOpenMainWindow(
                launchedAsLoginItem: false, onboardingCompleted: true, isAutomatedLaunch: true
            ),
            "launch harnesses must not get a window"
        )
    }

    runSuite("LaunchAtLoginPreferences defaults to off until the user chooses otherwise") {
        let suiteName = "LaunchAtLoginPreferencesTests.default.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertFalse(
            LaunchAtLoginPreferences.hasExplicitChoice(userDefaults: defaults),
            "launch at login should start without an explicit saved choice"
        )
        assertFalse(
            LaunchAtLoginPreferences.isEnabled(userDefaults: defaults),
            "launch at login should default off before the user opts in"
        )
    }

    runSuite("LaunchAtLoginPreferences persists opt-in and opt-out choices") {
        let suiteName = "LaunchAtLoginPreferencesTests.persist.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        LaunchAtLoginPreferences.setEnabled(true, userDefaults: defaults)
        assertTrue(
            LaunchAtLoginPreferences.hasExplicitChoice(userDefaults: defaults),
            "turning launch at login on should record an explicit choice"
        )
        assertTrue(
            LaunchAtLoginPreferences.isEnabled(userDefaults: defaults),
            "turning launch at login on should persist true"
        )

        LaunchAtLoginPreferences.setEnabled(false, userDefaults: defaults)
        assertTrue(
            LaunchAtLoginPreferences.hasExplicitChoice(userDefaults: defaults),
            "turning launch at login off should keep an explicit choice"
        )
        assertFalse(
            LaunchAtLoginPreferences.isEnabled(userDefaults: defaults),
            "turning launch at login off should persist false"
        )
    }

    runSuite("LaunchAtLoginPreferences.shouldApplyDefaultEnable — one-time default after onboarding, never over a choice") {
        assertTrue(
            LaunchAtLoginPreferences.shouldApplyDefaultEnable(
                hasExplicitChoice: false, hasAppliedDefault: false, onboardingCompleted: true
            ),
            "an onboarded install with no choice and no prior default run should get the default"
        )
        assertFalse(
            LaunchAtLoginPreferences.shouldApplyDefaultEnable(
                hasExplicitChoice: false, hasAppliedDefault: false, onboardingCompleted: false
            ),
            "the default must wait for onboarding so the macOS login-item notice has context"
        )
        assertFalse(
            LaunchAtLoginPreferences.shouldApplyDefaultEnable(
                hasExplicitChoice: true, hasAppliedDefault: false, onboardingCompleted: true
            ),
            "an explicit user choice must never be overridden by the default"
        )
        assertFalse(
            LaunchAtLoginPreferences.shouldApplyDefaultEnable(
                hasExplicitChoice: false, hasAppliedDefault: true, onboardingCompleted: true
            ),
            "the default runs at most once, so a System Settings removal is not silently undone"
        )
    }

    runSuite("LaunchAtLoginPreferences default-enable marker persists without recording an explicit choice") {
        let suiteName = "LaunchAtLoginPreferencesTests.marker.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertFalse(
            LaunchAtLoginPreferences.hasAppliedDefaultEnable(userDefaults: defaults),
            "a fresh install should not claim the default already ran"
        )
        LaunchAtLoginPreferences.markDefaultEnableApplied(userDefaults: defaults)
        assertTrue(
            LaunchAtLoginPreferences.hasAppliedDefaultEnable(userDefaults: defaults),
            "the applied marker should persist"
        )
        assertFalse(
            LaunchAtLoginPreferences.hasExplicitChoice(userDefaults: defaults),
            "applying the default must not masquerade as an explicit user choice"
        )
    }

    runSuite("LaunchAtLoginNoticePolicy shows problems inline instead of in a tooltip") {
        assertNil(
            LaunchAtLoginNoticePolicy.notice(needsApproval: false, failureMessage: nil),
            "a working login item should show no inline line"
        )
        assertEqual(
            LaunchAtLoginNoticePolicy.notice(needsApproval: true, failureMessage: nil),
            LaunchAtLoginNoticePolicy.needsApprovalText,
            "a login item waiting on macOS approval should say so, since the switch still reads On"
        )
        assertTrue(
            LaunchAtLoginNoticePolicy.needsApprovalText.contains("Login Items"),
            "the approval line should name where to go"
        )
        assertEqual(
            LaunchAtLoginNoticePolicy.notice(needsApproval: true, failureMessage: "Couldn't change it."),
            "Couldn't change it.",
            "a failed change is the newer news and wins over the approval line"
        )
        assertNil(
            LaunchAtLoginNoticePolicy.notice(needsApproval: false, failureMessage: ""),
            "an empty failure message should not show an empty line"
        )
    }
}
