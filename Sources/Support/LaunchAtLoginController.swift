import Foundation
import ServiceManagement

@MainActor
enum LaunchAtLoginController {
    static var isEnabled: Bool {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval:
            return true
        case .notRegistered, .notFound:
            return false
        @unknown default:
            return false
        }
    }

    static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled:
            return "On. Transcripted will open automatically when you log in."
        case .requiresApproval:
            return "Waiting for approval in System Settings."
        case .notRegistered:
            return "Off. Transcripted will stay closed until you open it."
        case .notFound:
            return "Launch at login is unavailable in this build."
        @unknown default:
            return "Launch at login status is unavailable right now."
        }
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
