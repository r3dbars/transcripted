import AppKit
import Foundation
import Sparkle

extension SparkleUpdaterController: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        cancelObservedUpdateCheckTimeout()
        let version = versionString(for: item)
        if case .readyToInstall(let heldVersion) = updateStatus.state, heldVersion == version {
            // A probe resumes an update Sparkle already downloaded and still
            // holds. It is still ready to install; keep "Restart to Update".
            syncReadiness(from: updater)
            return
        }
        let state = UpdateStatus.State.updateAvailable(version: version)
        // A probe only reads the feed; nothing downloads after it, so the
        // update needs a click even with automatic downloads on.
        setUpdateStatus(
            state,
            canCheckForUpdates: updater.canCheckForUpdates,
            requiresUserInstall: currentUpdateCheck == .updateInformation ? true : nil
        )
        trackUpdateCheckFinished(result: "available", state: state, version: version)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        if UpdateFailureKind.isNoUpdate(error) {
            markNoUpdateAvailable(from: updater)
            return
        }

        markUpdateCheckFailed(from: updater, error: error)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        markNoUpdateAvailable(from: updater)
    }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        let version = versionString(for: item)
        let state = UpdateStatus.State.downloading(version: version)
        // The download itself answers an Install click made during the
        // feed read; the menu now shows it preparing.
        hasPendingUserUpdateAction = false
        cancelPendingUserUpdateActionTimeout()
        setUpdateStatus(state, canCheckForUpdates: updater.canCheckForUpdates)
        trackUpdateLifecycleEvent("update_download_started", state: state, version: version)
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        let version = versionString(for: item)
        let state = UpdateStatus.State.downloading(version: version)
        setUpdateStatus(state, canCheckForUpdates: updater.canCheckForUpdates)
        trackUpdateLifecycleEvent("update_download_finished", state: state, version: version)
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: any Error) {
        let version = versionString(for: item)
        let state = UpdateStatus.State.updateAvailable(version: version)
        let failureKind = UpdateFailureKind.classify(error, fallback: .downloadFailed).rawValue
        let failureCode = UpdateFailureKind.diagnosticCode(error)
        // Sparkle will not retry until its next scheduled check, hours away.
        // Hand the update to the person instead of showing "Preparing Update"
        // with a disabled button until then.
        setUpdateStatus(state, canCheckForUpdates: updater.canCheckForUpdates, requiresUserInstall: true)
        // This cycle's failure is counted here; the cycle-finished callback
        // that follows must not count it again as a check error.
        didTrackCurrentUpdateCycleFailure = true
        trackUpdateLifecycleEvent(
            "update_download_finished",
            state: state,
            version: version,
            failureKind: failureKind
        )
        trackUpdateCheckFinished(
            result: "download_failed",
            state: state,
            version: version,
            failureKind: failureKind,
            failureCode: failureCode
        )
    }

    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        let version = versionString(for: item)
        pendingImmediateInstallHandler = immediateInstallHandler
        pendingImmediateInstallVersion = version
        // Sparkle installs a staged update whenever the app quits. Record it
        // now so the next launch can count that install; a relaunch through
        // "Restart to Update" overwrites the kind with `restart`.
        rememberPendingInstalledUpdate(version: version, kind: .quit)
        markUpdateReadyToInstall(from: updater, version: version)
        return true
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        let isBackgroundCheck = updateCheck == .updatesInBackground
        let reason = BackgroundUpdateDeferralPolicy.deferralReason(
            isBackgroundCheck: isBackgroundCheck,
            automaticDownloadsEnabled: updater.automaticallyDownloadsUpdates,
            isBusy: isBackgroundCheck && shouldDeferBackgroundUpdateCheck(),
            isOnCostlyNetwork: isOnCostlyNetwork || !hasReportedNetworkPath
        )
        guard let reason else {
            currentUpdateCheck = updateCheck
            return
        }

        currentUpdateCheck = nil
        // Sparkle ends this cycle with the error, shows nothing, and keeps its
        // normal schedule, so the next background check runs an interval later.
        // Sparkle cannot pause a download that already started; this only
        // stops new ones.
        throw NSError(
            domain: Self.deferredBackgroundCheckErrorDomain,
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Background update download deferred (\(reason.rawValue))."]
        )
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        cancelObservedUpdateCheckTimeout()
        // Each cycle dedupes its own failure. Reset when it ends so the next
        // scheduled check (which never passes through the observed-check
        // entry point) can report its own failure.
        let hadPendingUserUpdateAction = hasPendingUserUpdateAction
        defer {
            didTrackCurrentUpdateCycleFailure = false
            currentUpdateCheck = nil
            isSparkleHoldingUpdate = false
            hasPendingUserUpdateAction = false
            if hadPendingUserUpdateAction {
                // The Install click came in while Sparkle was reading the
                // feed. Run it now that the session is over, after this
                // callback returns so Sparkle keeps its schedule.
                Task { @MainActor [weak self] in
                    self?.performPendingUserUpdateAction()
                }
            }
        }

        if let error, (error as NSError).domain == Self.deferredBackgroundCheckErrorDomain {
            if case .checking = updateStatus.state {
                markUpdaterIdle(from: updater)
            } else {
                cancelObservedUpdateCheckTimeout()
                syncReadiness(from: updater)
            }
            // A downloaded update is already on screen as "Restart to
            // Update"; a probe would only resume it.
            if case .readyToInstall = updateStatus.state { return }
            // Still read the feed (a few KB) so a waiting update shows up with
            // an Install button; only the automatic download waits. Run it
            // after this callback returns: starting a session inside it would
            // stop Sparkle from scheduling its next check.
            Task { @MainActor [weak self] in
                self?.refreshUpdateStatus()
            }
            return
        }

        // A cycle never ends mid-download when things go well: a staged update
        // stalls the cycle (install on quit), and a dismissed downloaded update
        // is already `.readyToInstall`. Still `.downloading` here means the
        // download or the install prep after it failed or was canceled
        // (unarchive, signature, disk space). Hand it back as an Install
        // action instead of a disabled "Preparing Update" for hours.
        if case .downloading(let version) = updateStatus.state {
            setUpdateStatus(
                .updateAvailable(version: version),
                canCheckForUpdates: updater.canCheckForUpdates,
                requiresUserInstall: true
            )
        }

        if let error {
            if UpdateFailureKind.isNoUpdate(error) {
                guard !didTrackCurrentUpdateCycleFailure else { return }
                // `updaterDidNotFindUpdate` already handled this result unless
                // the observed check is still waiting on it.
                if case .checking = updateStatus.state {
                    markNoUpdateAvailable(from: updater)
                }
                return
            }

            guard !didTrackCurrentUpdateCycleFailure else { return }
            markUpdateCheckFailed(from: updater, error: error)
            return
        }

        let fallbackState: UpdateStatus.State
        switch updateStatus.state {
        case .checking, .unknown:
            fallbackState = updater.canCheckForUpdates ? .readyToCheck : .unknown
        default:
            fallbackState = updateStatus.state
        }

        setUpdateStatus(fallbackState, canCheckForUpdates: updater.canCheckForUpdates)
    }

    func updater(
        _ updater: SPUUpdater,
        userDidMake choice: SPUUserUpdateChoice,
        forUpdate updateItem: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        switch choice {
        case .skip:
            // Background checks never offer a skipped version again, so
            // nothing else would clear the badge for the rest of the session.
            setUpdateStatus(.readyToCheck, canCheckForUpdates: updater.canCheckForUpdates, requiresUserInstall: false)
        case .dismiss:
            switch state.stage {
            case .downloaded, .installing:
                // Sparkle keeps a dismissed downloaded update and installs it
                // on quit, so it reads as ready to restart, not "Preparing".
                markUpdateReadyToInstall(from: updater, version: versionString(for: updateItem))
            case .notDownloaded:
                // "Remind me later": the badge is that reminder.
                break
            @unknown default:
                break
            }
        case .install:
            break
        @unknown default:
            break
        }
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        // Sparkle's own install-and-relaunch (standard UI) never sets the
        // immediate-install version, so fall back to the update on screen.
        if let relaunchVersion = pendingImmediateInstallVersion ?? updateStatus.availableUpdateVersion {
            rememberPendingInstalledUpdate(version: relaunchVersion, kind: .restart)
            AnalyticsReporter.track(
                "update_relaunching",
                properties: ["version": relaunchVersion]
            )
        }
        pendingImmediateInstallHandler = nil
        pendingImmediateInstallVersion = nil
    }
}

extension SparkleUpdaterController: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        update.isCriticalUpdate
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        let version = Self.displayVersionString(for: update)
        let updateState: UpdateStatus.State
        switch state.stage {
        case .downloaded, .installing:
            updateState = .readyToInstall(version: version)
        case .notDownloaded:
            updateState = .updateAvailable(version: version)
        @unknown default:
            updateState = .updateAvailable(version: version)
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isSparkleHoldingUpdate = true
            if self.hasPendingUserUpdateAction {
                self.hasPendingUserUpdateAction = false
                self.cancelPendingUserUpdateActionTimeout()
                if !handleShowingUpdate, self.canReplayParkedUserUpdateAction() {
                    // A quiet reminder: bring it forward for the Install
                    // click that arrived during the feed read.
                    self.activateForUpdateWindow()
                    self.updaterController.checkForUpdates(nil)
                }
            }
            switch updateState {
            case .readyToInstall(let version):
                self.markUpdateReadyToInstall(from: self.updaterController.updater, version: version)
            case .updateAvailable:
                // Sparkle hands an update to its user driver only when it will
                // not download it silently, so the person has to act on it.
                self.setUpdateStatus(
                    updateState,
                    canCheckForUpdates: self.updaterController.updater.canCheckForUpdates,
                    requiresUserInstall: true
                )
            case .unknown, .readyToCheck, .checking, .noUpdateAvailable, .downloading:
                self.setUpdateStatus(
                    updateState,
                    canCheckForUpdates: self.updaterController.updater.canCheckForUpdates
                )
            }
        }
    }
}
