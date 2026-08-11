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
        // Rendered as sections of the single combined settings page — no
        // page intro of its own; the section labels carry the headings.
        VStack(alignment: .leading, spacing: 24) {
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
                    detail: "",
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

                // One control for what was two coupled booleans: the
                // controller already enforces the ladder (checks off forces
                // downloads off; downloads on forces checks on), so the UI
                // exposes it as the three states users actually choose
                // between. Writes route through the existing setters so
                // update_setting_changed telemetry keeps firing unchanged.
                VStack(alignment: .leading, spacing: 6) {
                    Picker("Automatic updates", selection: automaticUpdatePolicyBinding) {
                        ForEach(availableAutomaticUpdatePolicies) { policy in
                            Text(policy.title).tag(policy)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 420)

                    if !sparkleUpdater.automaticUpdateSettings.automaticDownloadsAllowed {
                        Text("Automatic downloads aren't available for this install.")
                            .font(.caption)
                            .foregroundStyle(LibraryTokens.ink3)
                    }
                }
                .padding(.vertical, 10)

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
                VStack(alignment: .leading, spacing: 0) {
                    AboutActionRow(
                        title: "Email support",
                        detail: "Opens a prefilled email to help@transcripted.app.",
                        buttonTitle: "Email support",
                        tone: .accent,
                        isEnabled: true,
                        action: onSubmitFeedback
                    )

                    AboutHairline()

                    AboutActionRow(
                        title: "Send diagnostics",
                        detail: "Sends a privacy-safe diagnostic event so we can investigate a problem.",
                        buttonTitle: "Send diagnostics",
                        tone: .neutral,
                        status: diagnosticsActionStatus,
                        isEnabled: CrashReporter.isAvailable && crashReportingEnabled,
                        action: onSendDiagnosticEvent
                    )

                    if let diagnosticsDisabledReason {
                        Text(diagnosticsDisabledReason)
                            .font(.caption)
                            .foregroundStyle(LibraryTokens.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
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
        // Clamp downloads-enabled to .notify when Sparkle reports downloads
        // unavailable: the .download segment isn't offered then, and checks
        // are what actually still run.
        if settings.automaticDownloadsEnabled, settings.automaticDownloadsAllowed { return .download }
        if settings.automaticChecksEnabled || settings.automaticDownloadsEnabled { return .notify }
        return .off
    }

    private var automaticUpdatePolicyBinding: Binding<AutomaticUpdatePolicy> {
        Binding(
            get: { currentAutomaticUpdatePolicy },
            set: { newPolicy in
                // The controller's setters have no unchanged-value guard —
                // every call emits update_setting_changed telemetry and an
                // enable also kicks refreshUpdateStatus() — so only call a
                // setter when its underlying boolean actually flips. The
                // controller still enforces the ladder internally (checks off
                // forces downloads off; downloads on forces checks on).
                let settings = sparkleUpdater.automaticUpdateSettings
                switch newPolicy {
                case .off:
                    if settings.automaticDownloadsEnabled {
                        onTrackSettingsToggle("automatic_update_downloads", false, .general)
                    }
                    if settings.automaticChecksEnabled {
                        onTrackSettingsToggle("automatic_update_checks", false, .general)
                        sparkleUpdater.setAutomaticallyChecksForUpdates(false)
                    }
                case .notify:
                    if settings.automaticDownloadsEnabled {
                        onTrackSettingsToggle("automatic_update_downloads", false, .general)
                        sparkleUpdater.setAutomaticallyDownloadsUpdates(false)
                    }
                    if !settings.automaticChecksEnabled {
                        onTrackSettingsToggle("automatic_update_checks", true, .general)
                        sparkleUpdater.setAutomaticallyChecksForUpdates(true)
                    }
                case .download:
                    if !settings.automaticChecksEnabled {
                        onTrackSettingsToggle("automatic_update_checks", true, .general)
                    }
                    if !settings.automaticDownloadsEnabled {
                        onTrackSettingsToggle("automatic_update_downloads", true, .general)
                        sparkleUpdater.setAutomaticallyDownloadsUpdates(true)
                    }
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
