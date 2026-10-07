import Foundation

extension SparkleUpdaterController {
    struct AutomaticUpdateSettings: Equatable {
        var automaticChecksEnabled: Bool
        var automaticDownloadsAllowed: Bool
        var automaticDownloadsEnabled: Bool
    }

    struct UpdateStatus: Equatable {
        enum State: Equatable {
            case unknown
            case readyToCheck
            case checking
            case noUpdateAvailable
            case updateAvailable(version: String)
            case downloading(version: String)
            case readyToInstall(version: String)
        }

        var state: State
        var canCheckForUpdates: Bool
        /// Sparkle will not fetch this available update on its own: a
        /// background download failed, or Sparkle handed the update back as a
        /// quiet reminder. The person has to start the install, so the update
        /// must read as actionable even when automatic downloads are on.
        var requiresUserInstall = false

        var availableUpdateVersion: String? {
            switch state {
            case .updateAvailable(let version), .downloading(let version), .readyToInstall(let version):
                return version
            case .unknown, .readyToCheck, .checking, .noUpdateAvailable:
                return nil
            }
        }

        var readyToInstallVersion: String? {
            guard case .readyToInstall(let version) = state else { return nil }
            return version
        }

        var actionSafetyState: UpdateActionSafetyState {
            switch state {
            case .unknown:
                return .unknown
            case .readyToCheck:
                return .readyToCheck
            case .checking:
                return .checking
            case .noUpdateAvailable:
                return .noUpdateAvailable
            case .updateAvailable:
                return .updateAvailable
            case .downloading:
                return .downloading
            case .readyToInstall:
                return .readyToInstall
            }
        }

        var canRunUserUpdateAction: Bool {
            switch state {
            case .checking, .downloading:
                return false
            case .readyToInstall:
                return true
            case .unknown, .readyToCheck, .noUpdateAvailable, .updateAvailable:
                return canCheckForUpdates
            }
        }
    }
}
