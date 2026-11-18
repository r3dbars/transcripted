import Foundation

extension UpdateStatusWords.Phase {
    init(_ state: SparkleUpdaterController.UpdateStatus.State) {
        switch state {
        case .unknown, .readyToCheck, .noUpdateAvailable:
            self = .idle
        case .checking:
            self = .checking
        case .updateAvailable(let version):
            self = .available(version: version)
        case .downloading(let version):
            self = .downloading(version: version)
        case .readyToInstall(let version):
            self = .readyToInstall(version: version)
        }
    }
}
