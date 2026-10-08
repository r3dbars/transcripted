import Foundation
import ServiceManagement

@MainActor
enum LaunchAtLoginController {
    /// One read of the login item's status. Each `SMAppService.status` read is
    /// a synchronous XPC round trip, so callers that need several fields should
    /// take one state instead of reading `isEnabled`, `needsApproval` and
    /// `statusDescription` separately.
    static var currentState: LaunchAtLoginState {
        LaunchAtLoginState(status: SMAppService.mainApp.status)
    }

    /// One serial queue for status reads. The read is a blocking XPC call, so
    /// it stays off the Swift concurrency pool: if the daemon is slow, reads
    /// queue up behind one waiting thread instead of tying up the pool.
    private nonisolated static let statusQueue = DispatchQueue(
        label: "com.transcripted.launch-at-login-status",
        qos: .userInitiated
    )

    /// Reads the status off the main thread. A slow `SMAppService.status` reply
    /// once froze the app on the Settings window, so refreshes that run on
    /// every app activation use this.
    nonisolated static func readState() async -> LaunchAtLoginState {
        await withCheckedContinuation { continuation in
            statusQueue.async {
                continuation.resume(returning: LaunchAtLoginState(status: SMAppService.mainApp.status))
            }
        }
    }

    static var isEnabled: Bool {
        currentState.isEnabled
    }

    /// Registered, but macOS won't launch it until the user allows it in
    /// System Settings > General > Login Items.
    static var needsApproval: Bool {
        currentState.needsApproval
    }

    /// macOS can't find the app to register (a DMG, Downloads, or a dev build).
    static var isUnavailable: Bool {
        currentState.isUnavailable
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    static var statusDescription: String {
        currentState.statusDescription
    }

    /// What the launch-time login-item sync failed at, as error messages.
    struct StartupSyncResult: Sendable {
        var optOutFailure: String?
        var defaultEnableFailure: String?
    }

    /// The launch-time sync: the saved opt-out, then the one-time default
    /// enable. The choice is made from saved preferences here; the
    /// `SMAppService` calls run on `statusQueue`, because `status` is a
    /// blocking XPC call that has frozen launch for 5 s+ on the main thread
    /// (Sentry APPLE-MACOS-3W).
    static func applyStartupState(onboardingCompleted: Bool) async -> StartupSyncResult {
        let hasExplicitChoice = LaunchAtLoginPreferences.hasExplicitChoice()
        let optOut = hasExplicitChoice && !LaunchAtLoginPreferences.isEnabled()
        let defaultEnable = LaunchAtLoginPreferences.shouldApplyDefaultEnable(
            hasExplicitChoice: hasExplicitChoice,
            hasAppliedDefault: LaunchAtLoginPreferences.hasAppliedDefaultEnable(),
            onboardingCompleted: onboardingCompleted
        )
        if defaultEnable {
            LaunchAtLoginPreferences.markDefaultEnableApplied()
        }
        guard optOut || defaultEnable else { return StartupSyncResult() }
        return await runStartupSync(optOut: optOut, defaultEnable: defaultEnable)
    }

    private nonisolated static func runStartupSync(optOut: Bool, defaultEnable: Bool) async -> StartupSyncResult {
        await withCheckedContinuation { continuation in
            statusQueue.async {
                var result = StartupSyncResult()
                if optOut {
                    do {
                        try unregisterIfNeeded()
                    } catch {
                        result.optOutFailure = error.localizedDescription
                    }
                }
                if defaultEnable {
                    do {
                        try registerIfNeeded()
                    } catch {
                        result.defaultEnableFailure = error.localizedDescription
                    }
                }
                continuation.resume(returning: result)
            }
        }
    }

    /// One-time default-enable: the meeting-detection stack is dead while the
    /// app is not running, so once onboarding is complete the login item is
    /// registered by default. The applied-marker guarantees this runs at most
    /// once per install, so removing the login item in System Settings sticks,
    /// and an explicit Settings-toggle choice always wins. Registration surfaces
    /// the standard macOS "added to Login Items" notice, and the Settings toggle
    /// reflects (and can revert) the state. Returns the register failure, if any.
    /// `register` is a test seam; production registers the main app.
    static func applyDefaultEnableIfNeeded(
        onboardingCompleted: Bool,
        userDefaults: UserDefaults = .standard,
        register: (@Sendable () throws -> Void)? = nil
    ) async -> String? {
        guard LaunchAtLoginPreferences.shouldApplyDefaultEnable(
            hasExplicitChoice: LaunchAtLoginPreferences.hasExplicitChoice(userDefaults: userDefaults),
            hasAppliedDefault: LaunchAtLoginPreferences.hasAppliedDefaultEnable(userDefaults: userDefaults),
            onboardingCompleted: onboardingCompleted
        ) else {
            return nil
        }

        LaunchAtLoginPreferences.markDefaultEnableApplied(userDefaults: userDefaults)
        return await registerOnStatusQueue(register ?? { try registerIfNeeded() })
    }

    /// Same queue as the launch-time sync: `status` and `register()` are
    /// blocking XPC calls that must stay off the main thread.
    private nonisolated static func registerOnStatusQueue(
        _ register: @escaping @Sendable () throws -> Void
    ) async -> String? {
        await withCheckedContinuation { continuation in
            statusQueue.async {
                do {
                    try register()
                    continuation.resume(returning: nil)
                } catch {
                    continuation.resume(returning: error.localizedDescription)
                }
            }
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try registerIfNeeded()
        } else {
            try unregisterIfNeeded()
        }

        LaunchAtLoginPreferences.setEnabled(enabled)
    }

    nonisolated private static func registerIfNeeded() throws {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval:
            return
        case .notRegistered, .notFound:
            try SMAppService.mainApp.register()
        @unknown default:
            try SMAppService.mainApp.register()
        }
    }

    nonisolated private static func unregisterIfNeeded() throws {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval:
            try SMAppService.mainApp.unregister()
        case .notRegistered, .notFound:
            return
        @unknown default:
            try SMAppService.mainApp.unregister()
        }
    }
}

struct LaunchAtLoginState: Equatable, Sendable {
    var isEnabled: Bool
    var needsApproval: Bool
    var isUnavailable: Bool
    var statusDescription: String

    init(status: SMAppService.Status) {
        switch status {
        case .enabled:
            isEnabled = true
            statusDescription = "On. Transcripted will open automatically when you log in."
        case .requiresApproval:
            isEnabled = true
            statusDescription = "Waiting for approval in System Settings."
        case .notRegistered:
            isEnabled = false
            statusDescription = "Off. Transcripted will stay closed until you open it."
        case .notFound:
            isEnabled = false
            statusDescription = "Launch at login is unavailable in this build."
        @unknown default:
            isEnabled = false
            statusDescription = "Launch at login status is unavailable right now."
        }
        needsApproval = status == .requiresApproval
        isUnavailable = status == .notFound
    }
}
