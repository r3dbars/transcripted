import Foundation
import Sparkle

@MainActor
final class SparkleUpdaterController: NSObject, ObservableObject, SPUUpdaterDelegate {
    enum UpdateState: Equatable {
        case idle
        case checking
        case available(version: String)
        case upToDate
        case error(String)

        var buttonTitle: String {
            switch self {
            case .idle, .upToDate:
                return "Check for updates"
            case .checking:
                return "Checking updates..."
            case .available:
                return "Update available"
            case .error:
                return "Try updates again"
            }
        }

        var detailText: String {
            switch self {
            case .idle:
                return "Sparkle is configured and ready."
            case .checking:
                return "Looking for a newer Transcripted build."
            case .available(let version):
                return "Transcripted \(version) is ready to install."
            case .upToDate:
                return "You already have the latest Transcripted build."
            case .error(let message):
                return message
            }
        }
    }

    @Published private(set) var updateState: UpdateState = .idle

    private var hasPerformedStartupCheck = false
    private lazy var updaterController: SPUStandardUpdaterController = {
        SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }()

    override init() {
        super.init()
        _ = updaterController
    }

    func performStartupUpdateCheckIfNeeded() {
        guard !hasPerformedStartupCheck else { return }
        hasPerformedStartupCheck = true

        guard hasConfiguredFeedURL else { return }
        guard updaterController.updater.automaticallyChecksForUpdates else { return }

        updateState = .checking
        updaterController.updater.checkForUpdatesInBackground()
    }

    func checkForUpdates() {
        updateState = .checking
        updaterController.checkForUpdates(nil)
    }

    private var hasConfiguredFeedURL: Bool {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String else {
            return false
        }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        updateState = .available(version: item.displayVersionString)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        updateState = .upToDate
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        updateState = .upToDate
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        updateState = .error(error.localizedDescription)
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        guard let error else { return }
        updateState = .error(error.localizedDescription)
    }
}
