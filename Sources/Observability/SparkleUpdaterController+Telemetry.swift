import AppKit
import Foundation
import Sparkle

extension SparkleUpdaterController {
    func trackUpdateActionClicked(surface: String, state: UpdateStatus.State, version: String?) {
        var properties = baseUpdateTelemetryProperties(state: state, version: version)
        properties["surface"] = surface
        properties["action_id"] = updateActionID(for: state)
        AnalyticsReporter.track("update_action_clicked", properties: properties)
    }

    func trackUpdateSettingChanged(settingID: String, enabled: Bool) {
        AnalyticsReporter.track(
            "update_setting_changed",
            properties: [
                "enabled": enabled ? "true" : "false",
                "setting_id": settingID,
            ]
        )
    }

    func trackUpdateCheckFinished(
        result: String,
        state: UpdateStatus.State,
        version: String?,
        failureKind: String? = nil,
        failureCode: String? = nil
    ) {
        var properties = baseUpdateTelemetryProperties(state: state, version: version)
        properties["result"] = result
        if let failureKind {
            properties["failure_kind"] = failureKind
        }
        if let failureCode {
            properties["failure_code"] = failureCode
        }
        AnalyticsReporter.track("update_check_finished", properties: properties)
    }

    func trackUpdateLifecycleEvent(
        _ event: String,
        state: UpdateStatus.State,
        version: String,
        failureKind: String? = nil
    ) {
        var properties = baseUpdateTelemetryProperties(state: state, version: version)
        if let failureKind {
            properties["failure_kind"] = failureKind
        }
        AnalyticsReporter.track(event, properties: properties)

        switch event {
        case "update_download_started":
            ProductFrictionTelemetry.track(
                surface: .update,
                stage: "update_download",
                result: .started
            )
        case "update_download_finished":
            ProductFrictionTelemetry.track(
                surface: .update,
                stage: "update_download",
                result: failureKind == nil ? .completed : .failed,
                failureKind: failureKind
            )
        default:
            break
        }
    }

    private func currentAppVersion() -> String {
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return version.isEmpty ? "unknown" : version
    }

    func rememberPendingInstalledUpdate(version: String, kind: UpdateInstallKind) {
        let trimmedVersion = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedVersion.isEmpty else { return }

        let defaults = UserDefaults.standard
        defaults.set(trimmedVersion, forKey: Self.pendingInstalledUpdateVersionKey)
        defaults.set(currentAppVersion(), forKey: Self.pendingInstalledUpdatePreviousVersionKey)
        defaults.set(kind.rawValue, forKey: Self.pendingInstalledUpdateKindKey)
    }

    /// Counts every install path once, on the first launch of a newer version:
    /// the in-app restart, Sparkle's silent install on quit, and installs from
    /// a DMG or Homebrew (`unattributed`). Before this, only the in-app
    /// restart was counted, so `update_installed` undercounted real installs.
    func trackInstalledUpdateIfNeeded() {
        let defaults = UserDefaults.standard
        let currentVersion = currentAppVersion()
        let outcome = UpdateInstallDetection.detect(
            currentVersion: currentVersion,
            lastLaunchedVersion: defaults.string(forKey: Self.lastLaunchedAppVersionKey),
            pendingVersion: defaults.string(forKey: Self.pendingInstalledUpdateVersionKey),
            pendingPreviousVersion: defaults.string(forKey: Self.pendingInstalledUpdatePreviousVersionKey),
            pendingKind: defaults.string(forKey: Self.pendingInstalledUpdateKindKey)
        )

        if let record = outcome.record {
            var properties = [
                "install_kind": record.kind.rawValue,
                "version": record.version,
            ]
            if let previousVersion = record.previousVersion {
                properties["previous_version"] = previousVersion
            }
            AnalyticsReporter.track("update_installed", properties: properties)
        }

        if outcome.clearPendingMarkers {
            defaults.removeObject(forKey: Self.pendingInstalledUpdateVersionKey)
            defaults.removeObject(forKey: Self.pendingInstalledUpdatePreviousVersionKey)
            defaults.removeObject(forKey: Self.pendingInstalledUpdateKindKey)
        }

        if let versionToRemember = outcome.versionToRemember {
            defaults.set(versionToRemember, forKey: Self.lastLaunchedAppVersionKey)
        }
    }

    func markUpdateReadyToInstall(from updater: SPUUpdater, version: String) {
        let state = UpdateStatus.State.readyToInstall(version: version)
        setUpdateStatus(state, canCheckForUpdates: updater.canCheckForUpdates)

        guard lastTrackedReadyToInstallVersion != version else { return }
        lastTrackedReadyToInstallVersion = version
        trackUpdateLifecycleEvent("update_ready_to_install", state: state, version: version)
    }

    private func baseUpdateTelemetryProperties(state: UpdateStatus.State, version: String?) -> [String: String] {
        var properties = [
            "automatic_downloads_enabled": automaticUpdateSettings.automaticDownloadsEnabled ? "true" : "false",
            "state": analyticsValue(for: state),
        ]
        if let version {
            properties["version"] = version
        }
        return properties
    }

    private func analyticsValue(for state: UpdateStatus.State) -> String {
        switch state {
        case .unknown:
            return "unknown"
        case .readyToCheck:
            return "ready"
        case .checking:
            return "checking"
        case .noUpdateAvailable:
            return "up_to_date"
        case .updateAvailable:
            return "available"
        case .downloading:
            return "downloading"
        case .readyToInstall:
            return "ready_to_install"
        }
    }

    private func updateActionID(for state: UpdateStatus.State) -> String {
        switch state {
        case .updateAvailable:
            return "install_update"
        case .readyToInstall:
            return "restart_to_update"
        case .checking, .downloading:
            return "view_update_progress"
        case .unknown, .readyToCheck, .noUpdateAvailable:
            return "check_updates"
        }
    }
}
