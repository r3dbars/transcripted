import Foundation
import Sparkle

@MainActor
final class SparkleUpdaterController: NSObject {
    private let updaterController: SPUStandardUpdaterController
    private var hasPerformedStartupCheck = false

    override init() {
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
    }

    func performStartupUpdateCheckIfNeeded() {
        guard !hasPerformedStartupCheck else { return }
        hasPerformedStartupCheck = true

        guard hasConfiguredFeedURL else { return }
        guard updaterController.updater.automaticallyChecksForUpdates else { return }

        // Sparkle recommends forcing launch-time background checks, if desired,
        // immediately after the updater has started and only when automatic
        // checks are enabled.
        updaterController.updater.checkForUpdatesInBackground()
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    private var hasConfiguredFeedURL: Bool {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String else {
            return false
        }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
