import Foundation

enum PermissionsOnboardingPreferences {
    static let completionKey = "permissionsOnboardingCompleted"
    static let forceKey = "forcePermissionsOnboarding"
    static let firstDictationSavedTrackedKey = "permissionsOnboardingFirstDictationSavedTracked"
    static let resumeStepIndexKey = "permissionsOnboardingResumeStepIndex"
    /// The permissions step. Setup never resumes past it, so the microphone
    /// check always runs again before the Done screen.
    static let maxResumeStepIndex = 1

    static func hasCompleted(userDefaults: UserDefaults = .standard) -> Bool {
        if userDefaults.bool(forKey: forceKey) {
            return false
        }
        return userDefaults.bool(forKey: completionKey)
    }

    static func markCompleted(userDefaults: UserDefaults = .standard) {
        userDefaults.set(true, forKey: completionKey)
        userDefaults.removeObject(forKey: forceKey)
        userDefaults.removeObject(forKey: resumeStepIndexKey)
    }

    /// Closing the setup window is an answer too. Once this setup has shown
    /// the Permissions step and macOS has asked for the microphone (either
    /// way), closing finishes setup like Done or Skip. Otherwise someone who
    /// declined the optional permissions got the Permissions step back on
    /// every launch and every menu bar click, with no way into dictation or
    /// imports. Closing earlier keeps the resume point, so a reinstall that
    /// kept the Mac's microphone answer, or a forced rerun, still shows the
    /// Permissions step.
    ///
    /// Automated launches never finish setup here: they share the real
    /// account's UserDefaults.
    static func closingWindowFinishesSetup(
        microphoneAnswered: Bool,
        userDefaults: UserDefaults = .standard,
        isAutomatedLaunch: Bool = AutomatedLaunchEnvironment.isActive()
    ) -> Bool {
        guard !isAutomatedLaunch, !hasCompleted(userDefaults: userDefaults) else { return false }
        let reachedPermissions = userDefaults.integer(forKey: resumeStepIndexKey) >= maxResumeStepIndex
        return reachedPermissions && microphoneAnswered
    }

    /// Where setup opens. macOS quits and reopens the app after some
    /// permission prompts, and people close the window mid-setup; both used to
    /// send them back to the welcome screen to click through again.
    ///
    /// Automated launches neither read nor write it: a temp HOME doesn't
    /// isolate UserDefaults, so a smoke that stops on Permissions would
    /// otherwise make the next smoke in that account skip the welcome step.
    static func resumeStepIndex(
        userDefaults: UserDefaults = .standard,
        isAutomatedLaunch: Bool = AutomatedLaunchEnvironment.isActive()
    ) -> Int {
        guard !isAutomatedLaunch, !hasCompleted(userDefaults: userDefaults) else { return 0 }
        return min(max(userDefaults.integer(forKey: resumeStepIndexKey), 0), maxResumeStepIndex)
    }

    static func recordStepReached(
        _ index: Int,
        userDefaults: UserDefaults = .standard,
        isAutomatedLaunch: Bool = AutomatedLaunchEnvironment.isActive()
    ) {
        guard !isAutomatedLaunch, !hasCompleted(userDefaults: userDefaults) else { return }
        userDefaults.set(min(max(index, 0), maxResumeStepIndex), forKey: resumeStepIndexKey)
    }

    static func hasTrackedFirstDictationSaved(userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.bool(forKey: firstDictationSavedTrackedKey)
    }

    static func markFirstDictationSavedTrackedIfNeeded(userDefaults: UserDefaults = .standard) -> Bool {
        guard !hasCompleted(userDefaults: userDefaults) else { return false }
        guard !userDefaults.bool(forKey: firstDictationSavedTrackedKey) else { return false }

        userDefaults.set(true, forKey: firstDictationSavedTrackedKey)
        return true
    }
}
