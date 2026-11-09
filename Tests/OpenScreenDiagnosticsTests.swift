import Foundation

func testOpenScreenDiagnostics() {
    runSuite("open_screen names the front-most Transcripted screen") {
        assertEqual(
            OpenScreenDiagnostics.resolve(onboardingVisible: true, menuBarShown: true, settingsPage: "people"),
            "onboarding",
            "onboarding sits above everything else"
        )
        assertEqual(
            OpenScreenDiagnostics.resolve(onboardingVisible: false, menuBarShown: true, settingsPage: "people"),
            "menubar",
            "the menu bar popover sits above the Settings window"
        )
        assertEqual(
            OpenScreenDiagnostics.resolve(onboardingVisible: false, menuBarShown: false, settingsPage: "dictations"),
            "dictations",
            "an open Settings window reports its page"
        )
        assertEqual(
            OpenScreenDiagnostics.resolve(onboardingVisible: false, menuBarShown: false, settingsPage: nil),
            "none",
            "with nothing open the app is just in the menu bar"
        )
    }

    runSuite("open_screen never carries a value outside its reviewed list") {
        assertEqual(
            OpenScreenDiagnostics.resolve(onboardingVisible: false, menuBarShown: false, settingsPage: "Weekly roadmap call"),
            "unknown",
            "free text becomes unknown"
        )
        assertEqual(OpenScreenDiagnostics.normalized(nil), "none", "no screen is none")
        assertEqual(OpenScreenDiagnostics.normalized("home"), "home", "a reviewed page passes")
    }

    runSuite("every Settings page has a reviewed open_screen value") {
        for page in TranscriptedSettingsPage.allCases {
            assertTrue(
                OpenScreenDiagnostics.settingsPages.contains(page.analyticsValue),
                "\(page.analyticsValue) should be a reviewed open_screen value, or hangs on it report unknown"
            )
        }
    }

    runSuite("open_screen becomes a hang-report tag only with a reviewed value") {
        let tags = SentryPayloadSanitizer.sanitizeCrashRuntimeTags([
            "open_screen": "people",
            "session_stage": "idle",
        ])
        assertEqual(tags["open_screen"], "people", "hangs can be filtered by the open screen")
        assertNil(tags["session_stage"], "other runtime keys stay context-only")

        let unreviewed = SentryPayloadSanitizer.sanitizeCrashRuntimeTags([
            "open_screen": "Customer call with Dana",
        ])
        assertNil(unreviewed["open_screen"], "an unreviewed value never becomes a tag")
    }
}
