import SwiftUI

/// The Settings > About page. Extracted from `TranscriptedSettingsView`
/// (codebase audit 2026-07-08 wave 2, spec W2-A). `updateActionEnabled`
/// bundles the update-safety policy (capture-in-progress guard) that the
/// parent's sidebar footer also consumes, so it stays owned by the parent
/// and is passed in as a closure.
///
/// The Support tab dissolved into this page (settings redesign phase 1): its
/// two rows (email support, send diagnostics) now live here under their own
/// "Support" section.
struct AboutSettingsPage: View {
    @ObservedObject var sparkleUpdater: SparkleUpdaterController
    let onTrackSettingsToggle: (String, Bool, TranscriptedSettingsPage?) -> Void
    let updateActionEnabled: (SparkleUpdaterController.UpdateStatus) -> Bool
    let onPerformUpdateAction: () -> Void

    let diagnosticsActionStatus: String?
    let crashReportingEnabled: Bool
    let onSubmitFeedback: () -> Void
    let onSendDiagnosticEvent: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsPageIntro(
                title: "About",
                summary: "Version and updates."
            )

            versionGroup
            supportGroup
        }
        .accessibilityIdentifier("transcripted.settings.page.about")
    }

    // MARK: Version

    private var versionGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            LibrarySectionLabel(text: "Version")

            VStack(alignment: .leading, spacing: 0) {
                AboutInfoRow(
                    title: "Transcripted",
                    detail: "Local-first dictation and meeting notes.",
                    value: TranscriptedSupportActions.appVersionDescription
                )

                AboutHairline()

                AboutInfoRow(
                    title: "Updates",
                    detail: aboutUpdateStatusDetail,
                    value: aboutUpdateStatusTitle,
                    valueColor: aboutUpdateStatusInkColor
                )

                AboutHairline()

                SettingsToggleRow(
                    title: "Check automatically",
                    detail: sparkleUpdater.automaticUpdateSettings.automaticChecksEnabled
                        ? "Transcripted checks for updates in the background."
                        : "Transcripted only checks when you ask.",
                    isOn: Binding(
                        get: { sparkleUpdater.automaticUpdateSettings.automaticChecksEnabled },
                        set: { newValue in
                            onTrackSettingsToggle("automatic_update_checks", newValue, .about)
                            sparkleUpdater.setAutomaticallyChecksForUpdates(newValue)
                        }
                    )
                )
                .padding(.vertical, 10)

                AboutHairline()

                SettingsToggleRow(
                    title: "Download automatically",
                    detail: sparkleUpdater.automaticUpdateSettings.automaticDownloadsEnabled
                        ? "Transcripted downloads available updates in the background."
                        : "Transcripted waits before downloading updates.",
                    isOn: Binding(
                        get: { sparkleUpdater.automaticUpdateSettings.automaticDownloadsEnabled },
                        set: { newValue in
                            onTrackSettingsToggle("automatic_update_downloads", newValue, .about)
                            sparkleUpdater.setAutomaticallyDownloadsUpdates(newValue)
                        }
                    )
                )
                .padding(.vertical, 10)
                .disabled(!sparkleUpdater.automaticUpdateSettings.automaticDownloadsAllowed)

                Text(automaticUpdatesDetail)
                    .font(.caption)
                    .foregroundStyle(LibraryTokens.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)

                HStack {
                    SettingsInlineActionButton(
                        title: aboutUpdateButtonTitle,
                        tone: .accent
                    ) {
                        guard aboutUpdateButtonEnabled else { return }
                        onPerformUpdateAction()
                    }
                    .disabled(!aboutUpdateButtonEnabled)
                }
                .padding(.top, 8)
            }
        }
    }

    // MARK: Support

    private var supportGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            LibrarySectionLabel(text: "Support")

            VStack(alignment: .leading, spacing: 12) {
                Text("Need help, found a bug, or want to send feedback? Email is the best way to reach the team building Transcripted.")
                    .font(.caption)
                    .foregroundStyle(LibraryTokens.ink2)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 0) {
                    AboutActionRow(
                        title: "Email support",
                        detail: "Send feedback, ask for help, or tell us what felt broken. This opens a prefilled email to help@transcripted.app.",
                        buttonTitle: "Email support",
                        tone: .accent,
                        isEnabled: true,
                        action: onSubmitFeedback
                    )

                    AboutHairline()

                    AboutActionRow(
                        title: "Send diagnostics",
                        detail: "Had an error or something felt broken? Send a privacy-safe diagnostic event so we can investigate and try to fix it.",
                        buttonTitle: "One-click send diagnostics",
                        tone: .neutral,
                        status: diagnosticsActionStatus,
                        isEnabled: CrashReporter.isAvailable && crashReportingEnabled,
                        action: onSendDiagnosticEvent
                    )
                }

                SupportPrivacyNote()
            }
        }
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

    /// A healthy update state stays silent (plain ink); only live progress
    /// (accent) or a waiting update (attention) earns color.
    private var aboutUpdateStatusInkColor: Color {
        switch sparkleUpdater.updateStatus.state {
        case .unknown, .readyToCheck, .noUpdateAvailable:
            return LibraryTokens.ink2
        case .checking:
            return LibraryTokens.accent
        case .updateAvailable where sparkleUpdater.automaticUpdateSettings.automaticDownloadsEnabled:
            return LibraryTokens.accent
        case .downloading:
            return LibraryTokens.accent
        case .updateAvailable, .readyToInstall:
            return LibraryTokens.attention
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
        updateActionEnabled(sparkleUpdater.updateStatus)
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

/// Plain settings-style row: title + detail on the left, a right-aligned
/// value. No card, no icon badge.
private struct AboutInfoRow: View {
    let title: String
    let detail: String
    let value: String
    var valueColor: Color = LibraryTokens.ink2

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(LibraryTokens.rowTitle)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(LibraryTokens.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(value)
                .font(LibraryTokens.meta)
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 10)
    }
}

/// Plain settings-style row for a support action: title + detail, a
/// trailing action button, and an optional inline status line.
private struct AboutActionRow: View {
    let title: String
    let detail: String
    let buttonTitle: String
    var tone: SettingsInteractionTone = .neutral
    var status: String? = nil
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(LibraryTokens.rowTitle)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(LibraryTokens.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                SettingsInlineActionButton(title: buttonTitle, tone: tone, action: action)
                    .disabled(!isEnabled)
            }

            if let status, !status.isEmpty {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(LibraryTokens.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 10)
    }
}

/// The one divider in this page: a plain 1px hairline, no card stroke.
private struct AboutHairline: View {
    var body: some View {
        Rectangle()
            .fill(LibraryTokens.hairline)
            .frame(height: 1)
    }
}
