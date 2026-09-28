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

    static func applySavedOptOutAtStartup() throws {
        guard LaunchAtLoginPreferences.hasExplicitChoice(),
              !LaunchAtLoginPreferences.isEnabled()
        else {
            return
        }

        try unregisterIfNeeded()
    }

    /// One-time default-enable: the meeting-detection stack is dead while the
    /// app is not running, so once onboarding is complete the login item is
    /// registered by default. The applied-marker guarantees this runs at most
    /// once per install, so removing the login item in System Settings sticks,
    /// and an explicit Settings-toggle choice always wins. Registration surfaces
    /// the standard macOS "added to Login Items" notice, and the Settings toggle
    /// reflects (and can revert) the state.
    static func applyDefaultEnableIfNeeded(onboardingCompleted: Bool) throws {
        guard LaunchAtLoginPreferences.shouldApplyDefaultEnable(
            hasExplicitChoice: LaunchAtLoginPreferences.hasExplicitChoice(),
            hasAppliedDefault: LaunchAtLoginPreferences.hasAppliedDefaultEnable(),
            onboardingCompleted: onboardingCompleted
        ) else {
            return
        }

        LaunchAtLoginPreferences.markDefaultEnableApplied()
        try registerIfNeeded()
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try registerIfNeeded()
        } else {
            try unregisterIfNeeded()
        }

        LaunchAtLoginPreferences.setEnabled(enabled)
    }

    private static func registerIfNeeded() throws {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval:
            return
        case .notRegistered, .notFound:
            try SMAppService.mainApp.register()
        @unknown default:
            try SMAppService.mainApp.register()
        }
    }

    private static func unregisterIfNeeded() throws {
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
