import Combine
import Foundation
import Sparkle

@MainActor
final class SparkleUpdaterController: NSObject, ObservableObject {
    struct UpdateStatus: Equatable {
        enum State: Equatable {
            case unknown
            case readyToCheck
            case checking
            case noUpdateAvailable
            case updateAvailable(version: String)
        }

        var state: State
        var canCheckForUpdates: Bool

        var availableUpdateVersion: String? {
            if case .updateAvailable(let version) = state {
                return version
            }
            return nil
        }
    }

    @Published private(set) var updateStatus = UpdateStatus(
        state: .unknown,
        canCheckForUpdates: false
    )

    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: self,
        userDriverDelegate: self
    )
    private var canCheckObservation: NSKeyValueObservation?
    private var hasPerformedStartupCheck = false

    override init() {
        super.init()
        observeUpdaterReadiness()
    }

    func performStartupUpdateCheckIfNeeded() {
        guard !hasPerformedStartupCheck else { return }
        hasPerformedStartupCheck = true

        guard hasConfiguredFeedURL else {
            setUpdateStatus(.unknown, canCheckForUpdates: false)
            return
        }

        if updaterController.updater.automaticallyChecksForUpdates {
            beginObservedUpdateCheck()

            // Sparkle recommends forcing launch-time background checks, if
            // desired, immediately after the updater has started and only when
            // automatic checks are enabled.
            updaterController.updater.checkForUpdatesInBackground()
        } else {
            refreshUpdateStatus()
        }
    }

    func checkForUpdates() {
        guard hasConfiguredFeedURL else {
            setUpdateStatus(.unknown, canCheckForUpdates: false)
            return
        }

        beginObservedUpdateCheck()
        updaterController.checkForUpdates(nil)
    }

    func refreshUpdateStatus() {
        guard hasConfiguredFeedURL else {
            setUpdateStatus(.unknown, canCheckForUpdates: false)
            return
        }
        guard updaterController.updater.canCheckForUpdates else { return }

        beginObservedUpdateCheck()
        updaterController.updater.checkForUpdateInformation()
    }

    private func observeUpdaterReadiness() {
        canCheckObservation = updaterController.updater.observe(
            \.canCheckForUpdates,
            options: [.initial, .new]
        ) { [weak self] updater, _ in
            Task { @MainActor [weak self] in
                self?.syncReadiness(from: updater)
            }
        }
    }

    private func beginObservedUpdateCheck() {
        switch updateStatus.state {
        case .updateAvailable:
            syncReadiness(from: updaterController.updater)
        default:
            setUpdateStatus(.checking, canCheckForUpdates: updaterController.updater.canCheckForUpdates)
        }
    }

    private func syncReadiness(from updater: SPUUpdater) {
        let canCheckForUpdates = updater.canCheckForUpdates
        let nextState: UpdateStatus.State

        switch updateStatus.state {
        case .unknown where canCheckForUpdates:
            nextState = .readyToCheck
        default:
            nextState = updateStatus.state
        }

        setUpdateStatus(nextState, canCheckForUpdates: canCheckForUpdates)
    }

    private func setUpdateStatus(_ state: UpdateStatus.State, canCheckForUpdates: Bool) {
        let nextStatus = UpdateStatus(state: state, canCheckForUpdates: canCheckForUpdates)
        guard nextStatus != updateStatus else { return }
        updateStatus = nextStatus
    }

    private func versionString(for item: SUAppcastItem) -> String {
        Self.displayVersionString(for: item)
    }

    nonisolated private static func displayVersionString(for item: SUAppcastItem) -> String {
        let displayVersion = item.displayVersionString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !displayVersion.isEmpty {
            return displayVersion
        }

        let buildVersion = item.versionString.trimmingCharacters(in: .whitespacesAndNewlines)
        return buildVersion.isEmpty ? "unknown" : buildVersion
    }

    private var hasConfiguredFeedURL: Bool {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String else {
            return false
        }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

extension SparkleUpdaterController: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        setUpdateStatus(.updateAvailable(version: versionString(for: item)), canCheckForUpdates: updater.canCheckForUpdates)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        setUpdateStatus(.noUpdateAvailable, canCheckForUpdates: updater.canCheckForUpdates)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        setUpdateStatus(.noUpdateAvailable, canCheckForUpdates: updater.canCheckForUpdates)
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        let fallbackState: UpdateStatus.State
        switch updateStatus.state {
        case .checking, .unknown:
            fallbackState = updater.canCheckForUpdates ? .readyToCheck : .unknown
        default:
            fallbackState = updateStatus.state
        }

        setUpdateStatus(fallbackState, canCheckForUpdates: updater.canCheckForUpdates)
    }
}

extension SparkleUpdaterController: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        let version = Self.displayVersionString(for: update)
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.setUpdateStatus(
                .updateAvailable(version: version),
                canCheckForUpdates: self.updaterController.updater.canCheckForUpdates
            )
        }
    }
}
