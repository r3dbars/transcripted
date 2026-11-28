import Foundation

/// `app_first_launch`: one anonymous event, the first time a brand-new install launches.
///
/// Why: the site can count downloads, but until now nothing counted installs
/// that actually opened. `app_launched` fires on every launch, and the
/// `first_launch_at` person trait is only the first day the app *observed*
/// itself, so existing users show up as new on every upgrade. This event is the
/// top of the in-app funnel: download -> first launch -> `onboarding_shown`.
///
/// Fresh versus existing: an install that already has an anonymous ID, a
/// first-observed day, or a remembered launched version has run an older build,
/// so it never sends this event. Those keys are written early in launch (the
/// updater controller writes the last-launched version while the app delegate
/// is built), so `captureLaunchBaseline()` reads them from `TranscriptedApp.init`,
/// before anything else runs. If the baseline was never captured the app
/// assumes an existing install and sends nothing.
///
/// Properties: `install_method` only (`homebrew`, `dmg`). App version, OS major
/// and build channel already ride on every event. There is no way for the app
/// to know which web page or link led to the download.
enum FirstLaunchTelemetry {
    static let reportedKey = "analyticsFirstLaunchReported"

    /// Keys an install already has if an older build ever ran on this Mac.
    static let existingInstallKeys = [
        InstallIdentity.storageKey,
        InstallIdentity.firstLaunchKey,
        DictationShortcutUpgrade.lastLaunchedAppVersionKey,
    ]

    private static let lock = NSLock()
    private nonisolated(unsafe) static var baselineHadExistingInstall: Bool?

    static func hasExistingInstall(userDefaults: UserDefaults = .standard) -> Bool {
        existingInstallKeys.contains { userDefaults.object(forKey: $0) != nil }
    }

    /// Records, once per process, whether this Mac already ran an older build.
    /// Call before anything writes the install keys.
    static func captureLaunchBaseline(userDefaults: UserDefaults = .standard) {
        lock.lock()
        defer { lock.unlock() }
        guard baselineHadExistingInstall == nil else { return }
        baselineHadExistingInstall = hasExistingInstall(userDefaults: userDefaults)
    }

    /// True only when the baseline was captured and found no earlier install.
    static var launchBaselineIsFreshInstall: Bool {
        lock.lock()
        defer { lock.unlock() }
        return baselineHadExistingInstall == false
    }

    /// Test hook: forget the captured baseline.
    static func resetLaunchBaselineForTesting() {
        lock.lock()
        defer { lock.unlock() }
        baselineHadExistingInstall = nil
    }

    /// `homebrew` when a Homebrew Cask record for Transcripted exists, else `dmg`.
    /// Homebrew keeps one folder per installed cask; a copy dragged out of the
    /// DMG leaves none. Never reads anything outside those two folders.
    static func installMethod(
        caskroomDirectories: [String] = ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"],
        directoryExists: (String) -> Bool = { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    ) -> String {
        caskroomDirectories.contains { directoryExists($0 + "/transcripted") } ? "homebrew" : "dmg"
    }
}

extension AnalyticsReporter {
    /// Called once per launch. Sends `app_first_launch` the first time only, and
    /// only for a fresh install. The marker is set on the first launch that has
    /// analytics on, so a later opt-in on an old install cannot send it late.
    func trackFirstLaunchIfNeeded(
        isFreshInstall: Bool = FirstLaunchTelemetry.launchBaselineIsFreshInstall,
        installMethod: String = FirstLaunchTelemetry.installMethod()
    ) {
        syncOnDeliveryQueue {
            // No API key means an automated launch or an unconfigured build:
            // send nothing and leave the marker alone.
            guard analyticsEnabled(), apiKey != nil, captureHost != nil else { return }
            guard !userDefaults.bool(forKey: FirstLaunchTelemetry.reportedKey) else { return }
            userDefaults.set(true, forKey: FirstLaunchTelemetry.reportedKey)
            guard isFreshInstall else { return }
            trackEvent("app_first_launch", properties: ["install_method": installMethod])
        }
    }
}
