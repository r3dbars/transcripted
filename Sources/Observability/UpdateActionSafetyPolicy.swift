import Foundation

enum UpdateActionSafetyState: Equatable {
    case unknown
    case readyToCheck
    case checking
    case noUpdateAvailable
    case updateAvailable
    case downloading
    case readyToInstall
}

enum UpdateActionSafetyPolicy {
    static let activeCaptureHelp = "Finish the current recording or processing work before checking for updates."

    static func canRunUserAction(
        state: UpdateActionSafetyState,
        sparkleCanRunUserAction: Bool,
        automaticDownloadsEnabled: Bool,
        isCaptureActive: Bool
    ) -> Bool {
        guard sparkleCanRunUserAction else { return false }
        if state == .updateAvailable && automaticDownloadsEnabled {
            return false
        }
        if isCaptureActive && requiresIdleCapture(for: state) {
            return false
        }
        return true
    }

    static func captureSafetyHelp(
        state: UpdateActionSafetyState,
        isCaptureActive: Bool
    ) -> String? {
        guard isCaptureActive && requiresIdleCapture(for: state) else { return nil }
        return activeCaptureHelp
    }

    static func requiresIdleCapture(for state: UpdateActionSafetyState) -> Bool {
        switch state {
        case .unknown, .readyToCheck, .noUpdateAvailable, .updateAvailable, .readyToInstall:
            return true
        case .checking, .downloading:
            return false
        }
    }
}
