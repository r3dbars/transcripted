import Foundation

/// Observation, not installation history. Dates stay local; only coarse elapsed
/// buckets leave the device. Existing installs and opt-in gaps have unknown timing.
enum RetentionTelemetry {
    static let onboardingStartedKey = "retentionOnboardingObservedAt"
    static let onboardingCompletedKey = "retentionOnboardingCompletedAt"
    private static let firstValuePrefix = "retentionFirstValueObserved."
    private static let lock = NSLock()

    static func observeOnboarding(
        previouslyCompleted: Bool,
        now: Date = Date(),
        userDefaults: UserDefaults = .standard,
        isAutomatedLaunch: Bool = AutomatedLaunchEnvironment.isActive()
    ) {
        guard !isAutomatedLaunch, AnalyticsPreferences.isEnabled(userDefaults: userDefaults), !previouslyCompleted else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !userDefaults.bool(forKey: ActivationTelemetry.firstArtifactSavedTrackedKey),
              userDefaults.object(forKey: onboardingStartedKey) == nil else { return }
        userDefaults.set(now, forKey: onboardingStartedKey)
    }

    static func completeOnboarding(now: Date = Date(), userDefaults: UserDefaults = .standard,
                                   isAutomatedLaunch: Bool = AutomatedLaunchEnvironment.isActive()) {
        guard !isAutomatedLaunch, AnalyticsPreferences.isEnabled(userDefaults: userDefaults) else { return }
        lock.lock()
        defer { lock.unlock() }
        guard userDefaults.object(forKey: onboardingStartedKey) is Date,
              userDefaults.object(forKey: onboardingCompletedKey) == nil else { return }
        userDefaults.set(now, forKey: onboardingCompletedKey)
    }

    /// The UI mutation clears synchronously, before a rapid re-enable can hide
    /// the disabled transition from the reporter's asynchronous observer.
    static func setAnalyticsEnabled(_ enabled: Bool, userDefaults: UserDefaults = .standard) {
        if !enabled { clearObservation(userDefaults: userDefaults) }
        AnalyticsPreferences.setEnabled(enabled, userDefaults: userDefaults)
    }

    static func clearObservation(userDefaults: UserDefaults) {
        lock.lock()
        defer { lock.unlock() }
        // Defaults notifications can queue another disabled-state clear.
        // Do not mutate absent keys, or the observer can keep scheduling itself.
        for key in [onboardingStartedKey, onboardingCompletedKey] where userDefaults.object(forKey: key) != nil {
            userDefaults.removeObject(forKey: key)
        }
        // Keep already-observed milestone flags: toggling diagnostics must not
        // manufacture a new first value. Never backfill activity during opt-out.
    }

    static func firstValueProperties(
        artifactKind: ActivationTelemetry.ArtifactKind,
        now: Date = Date(),
        userDefaults: UserDefaults = .standard,
        isAutomatedLaunch: Bool = AutomatedLaunchEnvironment.isActive()
    ) -> [String: String]? {
        guard !isAutomatedLaunch, AnalyticsPreferences.isEnabled(userDefaults: userDefaults), artifactKind != .unknown else { return nil }
        lock.lock()
        defer { lock.unlock() }
        let key = firstValuePrefix + artifactKind.rawValue
        guard !userDefaults.bool(forKey: key) else { return nil }
        userDefaults.set(true, forKey: key)
        let started = userDefaults.object(forKey: onboardingStartedKey) as? Date
        let completed = userDefaults.object(forKey: onboardingCompletedKey) as? Date
        return [
            "artifact_kind": artifactKind.rawValue,
            "measurement_basis": started == nil ? "existing_or_unobserved" : "observed_onboarding",
            "onboarding_to_value_bucket": elapsedBucket(since: started, now: now),
            "setup_to_value_bucket": elapsedBucket(since: completed, now: now),
        ]
    }

    static func elapsedBucket(since start: Date?, now: Date) -> String {
        guard let start, now >= start else { return "unknown" }
        switch now.timeIntervalSince(start) {
        case ..<60: return "lt_1m"
        case ..<300: return "1_5m"
        case ..<1_800: return "5_30m"
        case ..<3_600: return "30_60m"
        case ..<86_400: return "1_24h"
        case ..<604_800: return "1_7d"
        default: return "7d_plus"
        }
    }
}
