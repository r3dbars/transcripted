import Foundation

func testPermissionsOnboardingPreferences() {
    runSuite("PermissionsOnboardingPreferences treats force-on as incomplete") {
        let suiteName = "PermissionsOnboardingPreferencesTests.force.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: PermissionsOnboardingPreferences.completionKey)
        assertTrue(
            PermissionsOnboardingPreferences.hasCompleted(userDefaults: defaults),
            "completed onboarding should stay completed when no force override exists"
        )

        defaults.set(true, forKey: PermissionsOnboardingPreferences.forceKey)
        assertFalse(
            PermissionsOnboardingPreferences.hasCompleted(userDefaults: defaults),
            "force-on should temporarily show onboarding even after completion"
        )
    }

    runSuite("PermissionsOnboardingPreferences clears stale force override on completion") {
        let suiteName = "PermissionsOnboardingPreferencesTests.complete.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: PermissionsOnboardingPreferences.forceKey)
        PermissionsOnboardingPreferences.markCompleted(userDefaults: defaults)

        assertTrue(
            defaults.bool(forKey: PermissionsOnboardingPreferences.completionKey),
            "completion should be persisted"
        )
        assertNil(
            defaults.object(forKey: PermissionsOnboardingPreferences.forceKey),
            "completion should clear force-on so onboarding does not loop forever"
        )
        assertTrue(
            PermissionsOnboardingPreferences.hasCompleted(userDefaults: defaults),
            "completion should win after clearing the stale force override"
        )
    }

    runSuite("PermissionsOnboardingPreferences tracks first saved dictation once") {
        let suiteName = "PermissionsOnboardingPreferencesTests.first-dictation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertTrue(
            PermissionsOnboardingPreferences.markFirstDictationSavedTrackedIfNeeded(userDefaults: defaults),
            "first saved dictation should be tracked while onboarding is incomplete"
        )
        assertFalse(
            PermissionsOnboardingPreferences.markFirstDictationSavedTrackedIfNeeded(userDefaults: defaults),
            "first saved dictation should not be tracked more than once"
        )
        assertTrue(
            defaults.bool(forKey: PermissionsOnboardingPreferences.firstDictationSavedTrackedKey),
            "first saved dictation tracking should persist"
        )
        assertTrue(
            PermissionsOnboardingPreferences.hasTrackedFirstDictationSaved(userDefaults: defaults),
            "first saved dictation readback should reflect the persisted tracking bit"
        )
    }

    runSuite("PermissionsOnboardingPreferences skips first saved dictation after completion") {
        let suiteName = "PermissionsOnboardingPreferencesTests.first-dictation-complete.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        PermissionsOnboardingPreferences.markCompleted(userDefaults: defaults)

        assertFalse(
            PermissionsOnboardingPreferences.markFirstDictationSavedTrackedIfNeeded(userDefaults: defaults),
            "completed onboarding should not emit first saved dictation telemetry"
        )
        assertNil(
            defaults.object(forKey: PermissionsOnboardingPreferences.firstDictationSavedTrackedKey),
            "skipped tracking should not mark the first saved dictation key"
        )
    }

    runSuite("PermissionsOnboardingPreferences resumes setup at permissions, never past it") {
        let suiteName = "PermissionsOnboardingPreferencesTests.resume.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertEqual(
            PermissionsOnboardingPreferences.resumeStepIndex(userDefaults: defaults),
            0,
            "a fresh install starts on the welcome screen"
        )

        PermissionsOnboardingPreferences.recordStepReached(1, userDefaults: defaults)
        assertEqual(
            PermissionsOnboardingPreferences.resumeStepIndex(userDefaults: defaults),
            1,
            "a relaunch mid-setup reopens on the permissions step"
        )

        PermissionsOnboardingPreferences.recordStepReached(2, userDefaults: defaults)
        assertEqual(
            PermissionsOnboardingPreferences.resumeStepIndex(userDefaults: defaults),
            1,
            "reaching Done still resumes on permissions so the mic check runs again"
        )

        defaults.set(7, forKey: PermissionsOnboardingPreferences.resumeStepIndexKey)
        assertEqual(
            PermissionsOnboardingPreferences.resumeStepIndex(userDefaults: defaults),
            1,
            "an out-of-range stored step is clamped"
        )

        PermissionsOnboardingPreferences.recordStepReached(0, userDefaults: defaults)
        assertEqual(
            PermissionsOnboardingPreferences.resumeStepIndex(userDefaults: defaults),
            0,
            "going back to welcome and quitting reopens on welcome"
        )
    }

    runSuite("PermissionsOnboardingPreferences forgets the resume step once setup is done") {
        let suiteName = "PermissionsOnboardingPreferencesTests.resume-complete.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        PermissionsOnboardingPreferences.recordStepReached(1, userDefaults: defaults)
        PermissionsOnboardingPreferences.markCompleted(userDefaults: defaults)
        assertNil(
            defaults.object(forKey: PermissionsOnboardingPreferences.resumeStepIndexKey),
            "completion clears the resume step"
        )

        PermissionsOnboardingPreferences.recordStepReached(1, userDefaults: defaults)
        assertNil(
            defaults.object(forKey: PermissionsOnboardingPreferences.resumeStepIndexKey),
            "a completed setup does not record a new resume step"
        )

        defaults.set(true, forKey: PermissionsOnboardingPreferences.forceKey)
        assertEqual(
            PermissionsOnboardingPreferences.resumeStepIndex(userDefaults: defaults),
            0,
            "a forced setup rerun starts on the welcome screen"
        )
    }

    runSuite("PermissionsOnboardingPreferences ignores the resume step on automated launches") {
        let suiteName = "PermissionsOnboardingPreferencesTests.resume-automated.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        PermissionsOnboardingPreferences.recordStepReached(1, userDefaults: defaults, isAutomatedLaunch: true)
        assertNil(
            defaults.object(forKey: PermissionsOnboardingPreferences.resumeStepIndexKey),
            "a smoke that stops on Permissions leaves nothing behind for the next run"
        )

        PermissionsOnboardingPreferences.recordStepReached(1, userDefaults: defaults, isAutomatedLaunch: false)
        assertEqual(
            PermissionsOnboardingPreferences.resumeStepIndex(userDefaults: defaults, isAutomatedLaunch: true),
            0,
            "a smoke always starts on the welcome screen, even with a stale resume step"
        )
    }

    runSuite("Closing setup after the microphone was answered stops setup coming back") {
        let suiteName = "PermissionsOnboardingPreferencesTests.close-answered.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        PermissionsOnboardingPreferences.recordStepReached(1, userDefaults: defaults, isAutomatedLaunch: false)
        assertTrue(
            PermissionsOnboardingPreferences.closingWindowFinishesSetup(
                microphoneAnswered: true,
                userDefaults: defaults,
                isAutomatedLaunch: false
            ),
            "someone who answered the mic and declined the rest can close setup for good"
        )
    }

    runSuite("Closing setup before the microphone was asked keeps the resume point") {
        let suiteName = "PermissionsOnboardingPreferencesTests.close-unanswered.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        PermissionsOnboardingPreferences.recordStepReached(1, userDefaults: defaults, isAutomatedLaunch: false)
        assertFalse(
            PermissionsOnboardingPreferences.closingWindowFinishesSetup(
                microphoneAnswered: false,
                userDefaults: defaults,
                isAutomatedLaunch: false
            ),
            "macOS hasn't asked for the mic yet, so setup should come back to ask"
        )
        assertEqual(
            PermissionsOnboardingPreferences.resumeStepIndex(userDefaults: defaults, isAutomatedLaunch: false),
            1,
            "an unfinished setup still resumes on Permissions"
        )
    }

    runSuite("Closing setup before reaching Permissions keeps setup even when the Mac already answered the mic") {
        let suiteName = "PermissionsOnboardingPreferencesTests.close-welcome.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertFalse(
            PermissionsOnboardingPreferences.closingWindowFinishesSetup(
                microphoneAnswered: true,
                userDefaults: defaults,
                isAutomatedLaunch: false
            ),
            "a reinstall keeps the Mac's mic answer; closing on Welcome must not skip the Permissions step"
        )

        defaults.set(true, forKey: PermissionsOnboardingPreferences.forceKey)
        assertFalse(
            PermissionsOnboardingPreferences.closingWindowFinishesSetup(
                microphoneAnswered: true,
                userDefaults: defaults,
                isAutomatedLaunch: false
            ),
            "closing a forced rerun on Welcome keeps the rerun forced"
        )
        assertTrue(
            defaults.bool(forKey: PermissionsOnboardingPreferences.forceKey),
            "the forced rerun flag survives the close"
        )
    }

    runSuite("Closing setup never finishes it on automated launches or twice") {
        let suiteName = "PermissionsOnboardingPreferencesTests.close-guards.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertFalse(
            PermissionsOnboardingPreferences.closingWindowFinishesSetup(
                microphoneAnswered: true,
                userDefaults: defaults,
                isAutomatedLaunch: true
            ),
            "a smoke closing the window must not mark the real account's setup done"
        )

        PermissionsOnboardingPreferences.markCompleted(userDefaults: defaults)
        assertFalse(
            PermissionsOnboardingPreferences.closingWindowFinishesSetup(
                microphoneAnswered: true,
                userDefaults: defaults,
                isAutomatedLaunch: false
            ),
            "Done already finished setup; its own window close must not finish it again"
        )
    }
}
