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
        // Rendered as sections of the single combined settings page.
        VStack(alignment: .leading, spacing: 0) {
            versionGroup
            supportGroup
        }
        .accessibilityIdentifier("transcripted.settings.page.about")
    }

    // MARK: Version

    private var versionGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsCardLabel(text: "About")

            SettingsCard {
                SettingsControlRow(
                    title: "Transcripted",
                    automationIdentifier: "transcripted.settings.about.version"
                ) {
                    HStack(spacing: 8) {
                        Text("\(TranscriptedSupportActions.appVersionDescription) · \(aboutUpdateStatusTitle)")
                            .font(.caption)
                            .foregroundStyle(aboutUpdateStatusInkColor)
                            .lineLimit(1)
                        SettingsInlineActionButton(title: aboutUpdateButtonTitle, tone: .accent) {
                            guard aboutUpdateButtonEnabled else { return }
                            onPerformUpdateAction()
                        }
                        .disabled(!aboutUpdateButtonEnabled)
                    }
                }

                SettingsControlRow(
                    title: "Automatic updates",
                    info: GeneralInfo(
                        title: "Automatic updates",
                        message: "Off only checks when you ask. Notify me checks in the background and shows a badge. Download installs in the background — you just restart."
                    ),
                    automationIdentifier: "transcripted.settings.about.automatic-updates",
                    showsDivider: false
                ) {
                    // One control for what was two coupled booleans: the
                    // controller already enforces the ladder (checks off forces
                    // downloads off; downloads on forces checks on). Writes
                    // route through the existing setters so
                    // update_setting_changed telemetry keeps firing unchanged.
                    Picker("Automatic updates", selection: automaticUpdatePolicyBinding) {
                        ForEach(availableAutomaticUpdatePolicies) { policy in
                            Text(policy.title).tag(policy)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }
            .accessibilityIdentifier("transcripted.settings.section.about")
        }
    }

    // MARK: Support

    private var supportGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsCardLabel(text: "Support")
                .padding(.top, 16)

            SettingsCard {
                SettingsControlRow(
                    title: "Something broken? Tell us.",
                    info: GeneralInfo(
                        title: "Support",
                        message: "Email opens a prefilled message to help@transcripted.app — estimated reply within a day. Send Diagnostics shares a privacy-safe event so we can investigate; it needs crash reports on."
                    ),
                    automationIdentifier: "transcripted.settings.about.support",
                    showsDivider: diagnosticsActionStatus != nil || diagnosticsDisabledReason != nil
                ) {
                    HStack(spacing: 8) {
                        SettingsInlineActionButton(title: "Send Diagnostics") {
                            onSendDiagnosticEvent()
                        }
                        .disabled(!(CrashReporter.isAvailable && crashReportingEnabled))

                        SettingsInlineActionButton(title: "Email Support…", tone: .accent) {
                            onSubmitFeedback()
                        }
                    }
                }

                if let footnote = diagnosticsActionStatus ?? diagnosticsDisabledReason {
                    Text(footnote)
                        .font(.caption)
                        .foregroundStyle(LibraryTokens.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }
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

    /// The three real states behind the two coupled Sparkle booleans.
    private enum AutomaticUpdatePolicy: String, CaseIterable, Identifiable {
        case off
        case notify
        case download

        var id: String { rawValue }

        var title: String {
            switch self {
            case .off: return "Off"
            case .notify: return "Notify me"
            case .download: return "Download automatically"
            }
        }
    }

    private var availableAutomaticUpdatePolicies: [AutomaticUpdatePolicy] {
        sparkleUpdater.automaticUpdateSettings.automaticDownloadsAllowed
            ? AutomaticUpdatePolicy.allCases
            : [.off, .notify]
    }

    private var currentAutomaticUpdatePolicy: AutomaticUpdatePolicy {
        let settings = sparkleUpdater.automaticUpdateSettings
        if settings.automaticDownloadsEnabled { return .download }
        if settings.automaticChecksEnabled { return .notify }
        return .off
    }

    private var automaticUpdatePolicyBinding: Binding<AutomaticUpdatePolicy> {
        Binding(
            get: { currentAutomaticUpdatePolicy },
            set: { newPolicy in
                let settings = sparkleUpdater.automaticUpdateSettings
                switch newPolicy {
                case .off:
                    if settings.automaticChecksEnabled {
                        onTrackSettingsToggle("automatic_update_checks", false, .general)
                    }
                    if settings.automaticDownloadsEnabled {
                        onTrackSettingsToggle("automatic_update_downloads", false, .general)
                    }
                    // The controller forces downloads off when checks go off.
                    sparkleUpdater.setAutomaticallyChecksForUpdates(false)
                case .notify:
                    if !settings.automaticChecksEnabled {
                        onTrackSettingsToggle("automatic_update_checks", true, .general)
                    }
                    if settings.automaticDownloadsEnabled {
                        onTrackSettingsToggle("automatic_update_downloads", false, .general)
                    }
                    sparkleUpdater.setAutomaticallyChecksForUpdates(true)
                    sparkleUpdater.setAutomaticallyDownloadsUpdates(false)
                case .download:
                    if !settings.automaticChecksEnabled {
                        onTrackSettingsToggle("automatic_update_checks", true, .general)
                    }
                    if !settings.automaticDownloadsEnabled {
                        onTrackSettingsToggle("automatic_update_downloads", true, .general)
                    }
                    // The controller forces checks on when downloads go on.
                    sparkleUpdater.setAutomaticallyDownloadsUpdates(true)
                }
            }
        )
    }

    private var diagnosticsDisabledReason: String? {
        if !CrashReporter.isAvailable {
            return "Not available in this build: crash reporting is not configured."
        }
        if !crashReportingEnabled {
            return "To enable this, turn on \"Send crash and error reports\" in General > Advanced > Privacy."
        }
        return nil
    }
}

/// Plain settings-style row: title + detail on the left, a right-aligned
/// value. No card, no icon badge.
/// Plain settings-style row for a support action: title + detail, a
/// trailing action button, and an optional inline status line.
/// The one divider in this page: a plain 1px hairline, no card stroke.
