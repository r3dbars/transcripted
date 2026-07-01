import SwiftUI

extension TranscriptedSettingsView {
    var aboutPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsPageIntro(
                title: "About",
                summary: "Version and updates."
            )

            SettingsSection(
                title: "Version",
                detail: "Build info and update controls."
            ) {
                SettingsStatusCard(
                    title: "Transcripted",
                    status: TranscriptedSupportActions.appVersionDescription,
                    detail: "Local-first dictation and meeting notes.",
                    tone: .ready
                )

                SettingsStatusCard(
                    title: "Updates",
                    status: aboutUpdateStatusTitle,
                    detail: aboutUpdateStatusDetail,
                    tone: aboutUpdateStatusTone
                )

                VStack(alignment: .leading, spacing: 8) {
                    SettingsToggleRow(
                        title: "Check automatically",
                        detail: sparkleUpdater.automaticUpdateSettings.automaticChecksEnabled
                            ? "Transcripted checks for updates in the background."
                            : "Transcripted only checks when you ask.",
                        isOn: Binding(
                            get: { sparkleUpdater.automaticUpdateSettings.automaticChecksEnabled },
                            set: { newValue in
                                trackSettingsToggle("automatic_update_checks", enabled: newValue, page: .about)
                                sparkleUpdater.setAutomaticallyChecksForUpdates(newValue)
                            }
                        )
                    )

                    SettingsToggleRow(
                        title: "Download automatically",
                        detail: sparkleUpdater.automaticUpdateSettings.automaticDownloadsEnabled
                            ? "Transcripted downloads available updates in the background."
                            : "Transcripted waits before downloading updates.",
                        isOn: Binding(
                            get: { sparkleUpdater.automaticUpdateSettings.automaticDownloadsEnabled },
                            set: { newValue in
                                trackSettingsToggle("automatic_update_downloads", enabled: newValue, page: .about)
                                sparkleUpdater.setAutomaticallyDownloadsUpdates(newValue)
                            }
                        )
                    )
                        .disabled(!sparkleUpdater.automaticUpdateSettings.automaticDownloadsAllowed)

                    Text(automaticUpdatesDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    SettingsInlineActionButton(
                        title: aboutUpdateButtonTitle,
                        tone: .accent
                    ) {
                        guard aboutUpdateButtonEnabled else { return }
                        trackSettingsAction(settingsUpdateActionID, page: .about)
                        sparkleUpdater.performUserUpdateAction(surface: "settings_about")
                    }
                    .disabled(!aboutUpdateButtonEnabled)
                }
            }
        }
        .accessibilityIdentifier("transcripted.settings.page.about")
    }

    private var aboutUpdateStatusTitle: String {
        switch sparkleUpdater.updateStatus.state {
        case .unknown, .readyToCheck:
            return "Ready to check"
        case .checking:
            return "Checking for updates"
        case .noUpdateAvailable:
            return "Up to date"
        case .updateAvailable(let version):
            if sparkleUpdater.automaticUpdateSettings.automaticDownloadsEnabled {
                return "Preparing update (\(version))"
            }
            return "Update available (\(version))"
        case .downloading(let version):
            return "Downloading update (\(version))"
        case .readyToInstall(let version):
            return "Ready to restart (\(version))"
        }
    }

    private var aboutUpdateStatusDetail: String {
        switch sparkleUpdater.updateStatus.state {
        case .unknown, .readyToCheck:
            return "Check for a newer release."
        case .checking:
            return "Looking for updates now."
        case .noUpdateAvailable:
            return "This Mac is on the newest visible version."
        case .updateAvailable(let version):
            if sparkleUpdater.automaticUpdateSettings.automaticDownloadsEnabled {
                return "Transcripted is preparing version \(version). You only need to restart when it is ready."
            }
            return "Version \(version) is ready to install."
        case .downloading(let version):
            return "Version \(version) is downloading."
        case .readyToInstall(let version):
            return "Version \(version) is downloaded."
        }
    }

    private var aboutUpdateStatusTone: SettingsStatusCard.Tone {
        switch sparkleUpdater.updateStatus.state {
        case .unknown, .readyToCheck:
            return .working
        case .checking:
            return .working
        case .noUpdateAvailable:
            return .ready
        case .updateAvailable where sparkleUpdater.automaticUpdateSettings.automaticDownloadsEnabled:
            return .working
        case .downloading:
            return .working
        case .updateAvailable, .readyToInstall:
            return .caution
        }
    }

    private var aboutUpdateButtonTitle: String {
        switch sparkleUpdater.updateStatus.state {
        case .updateAvailable(let version):
            if sparkleUpdater.automaticUpdateSettings.automaticDownloadsEnabled {
                return "Preparing Update…"
            }
            return "Install \(version)"
        case .downloading:
            return "Downloading…"
        case .readyToInstall:
            return "Restart to Update"
        case .checking:
            return "Checking for Updates…"
        case .unknown, .readyToCheck, .noUpdateAvailable:
            return "Check for Updates"
        }
    }

    private var aboutUpdateButtonEnabled: Bool {
        updateActionEnabled(for: sparkleUpdater.updateStatus)
    }

    private var automaticUpdatesDetail: String {
        let settings = sparkleUpdater.automaticUpdateSettings
        if settings.automaticDownloadsEnabled {
            return "Transcripted will download updates in the background. When one is ready, you only need to restart."
        }
        if settings.automaticChecksEnabled {
            return "Transcripted will check in the background and show an update badge when one is ready."
        }
        return "Turn on automatic checks to see updates sooner."
    }
}
