import AppKit
import SwiftUI

/// The Settings > About page. Extracted from `TranscriptedSettingsView`
/// (codebase audit 2026-07-08 wave 2, spec W2-A). `updateActionEnabled`
/// bundles the update-safety policy (capture-in-progress guard) that the
/// parent's sidebar footer also consumes, so it stays owned by the parent
/// and is passed in as a closure.
///
/// It renders inside Settings › Advanced: the version and update check,
/// Automatic updates, and the one Feedback row. Send diagnostics sits in the
/// visible Privacy group (`SendDiagnosticsSettingsRow`), and email support is
/// offered there after diagnostics are sent, so the composer is the only
/// standing feedback entry here.
struct AboutSettingsPage: View {
    @ObservedObject var sparkleUpdater: SparkleUpdaterController
    let onTrackSettingsToggle: (String, Bool, TranscriptedSettingsPage?) -> Void
    let updateActionEnabled: (SparkleUpdaterController.UpdateStatus) -> Bool
    /// What a disabled update button is waiting on, or nil when nothing blocks it.
    let updateBlockedDetail: (SparkleUpdaterController.UpdateStatus) -> String?
    let onPerformUpdateAction: () -> Void

    let onSubmitFeedback: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            versionGroup
        }
        .accessibilityElement(children: .contain)
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
                        Text([TranscriptedAppVersion.description, updateBlockedDetail(sparkleUpdater.updateStatus) ?? aboutUpdateStatusTitle]
                            .compactMap { $0 }
                            .joined(separator: " · "))
                            .font(LibraryTokens.meta)
                            .foregroundStyle(aboutUpdateStatusInkColor)
                            .lineLimit(1)
                        SettingsInlineActionButton(title: aboutUpdateButtonTitle) {
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
                        message: "Download automatically gets new versions in the background and installs them when you quit. Never during a recording."
                    ),
                    automationIdentifier: "transcripted.settings.about.automatic-updates"
                ) {
                    // A menu, not a segmented control: three full-sentence
                    // choices in one segmented row squeezed the label down to
                    // "Au…". One control for what was two coupled booleans —
                    // the controller enforces the ladder (checks off forces
                    // downloads off; downloads on forces checks on), and writes
                    // route through the existing setters so
                    // update_setting_changed telemetry keeps firing unchanged.
                    Picker("Automatic updates", selection: automaticUpdatePolicyBinding) {
                        ForEach(availableAutomaticUpdatePolicies) { policy in
                            Text(policy.title).tag(policy)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }

                // The one feedback entry in Settings; the sidebar has the other.
                SettingsControlRow(
                    title: "Feedback",
                    info: GeneralInfo(
                        title: "Feedback",
                        message: "Write to Transcripted support. You review the report before it goes to help@transcripted.app."
                    ),
                    automationIdentifier: "transcripted.settings.about.support",
                    showsDivider: false
                ) {
                    SettingsInlineActionButton(title: "Send feedback…") {
                        onSubmitFeedback()
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("transcripted.settings.section.about")
        }
    }

    /// Words from `UpdateStatusWords`, the same set the sidebar and popover use.
    private var aboutUpdateStatusTitle: String? {
        let state = sparkleUpdater.updateStatus.state
        let checkedUpToDate: Bool
        if case .noUpdateAvailable = state { checkedUpToDate = true } else { checkedUpToDate = false }
        return UpdateStatusWords.versionNote(
            for: UpdateStatusWords.Phase(state),
            checkedUpToDate: checkedUpToDate,
            downloadsAutomatically: sparkleUpdater.availableUpdateDownloadsAutomatically
        )
    }

    /// A healthy update state stays silent (plain ink); only live progress
    /// (accent) or a waiting update (attention) earns color.
    private var aboutUpdateStatusInkColor: Color {
        switch sparkleUpdater.updateStatus.state {
        case .unknown, .readyToCheck, .noUpdateAvailable:
            return LibraryTokens.ink2
        case .checking:
            return LibraryTokens.accent
        case .updateAvailable where sparkleUpdater.availableUpdateDownloadsAutomatically:
            return LibraryTokens.accent
        case .downloading:
            return LibraryTokens.accent
        case .updateAvailable, .readyToInstall:
            return LibraryTokens.attention
        }
    }

    private var aboutUpdateButtonTitle: String {
        UpdateStatusWords.buttonTitle(
            for: UpdateStatusWords.Phase(sparkleUpdater.updateStatus.state),
            downloadsAutomatically: sparkleUpdater.availableUpdateDownloadsAutomatically
        )
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
            case .off: return "Check on launch"
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
        // Checks off wins: with no scheduled checks nothing downloads, even
        // when the Info.plist default leaves the download flag on.
        if !settings.automaticChecksEnabled { return .off }
        // Clamp downloads-enabled to .notify when Sparkle reports downloads
        // unavailable: the .download choice isn't offered in the menu then,
        // and checks are what actually still run.
        if settings.automaticDownloadsEnabled, settings.automaticDownloadsAllowed { return .download }
        return .notify
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
                        // Don't rely on the checks-off cascade to clear this:
                        // if checks are somehow already off (externally mutated
                        // Sparkle prefs), that cascade never runs.
                        sparkleUpdater.setAutomaticallyDownloadsUpdates(false)
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
                    }
                    // Also call it when only checks are off: the download flag
                    // can already read true from the Info.plist default, and
                    // this setter is what turns checks back on.
                    if !settings.automaticDownloadsEnabled || !settings.automaticChecksEnabled {
                        sparkleUpdater.setAutomaticallyDownloadsUpdates(true)
                    }
                }
            }
        )
    }
}

/// Privacy's last row: send an anonymous app snapshot to support. Needs Crash
/// reports. After a send (or a failure) the status line offers email support,
/// which carries the report ID so the two can be matched.
struct SendDiagnosticsSettingsRow: View {
    let status: String?
    let crashReportingEnabled: Bool
    let isSending: Bool
    let onSend: () -> Void
    let onEmailSupport: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsControlRow(
                title: "Send diagnostics",
                info: GeneralInfo(
                    title: "Send diagnostics",
                    message: "Sends support an anonymous snapshot of how the app is doing. No transcripts, audio or names."
                ),
                automationIdentifier: "transcripted.settings.about.send-diagnostics",
                showsDivider: footnote != nil
            ) {
                SettingsInlineActionButton(title: isSending ? "Sending…" : "Send…") {
                    onSend()
                }
                .disabled(!(CrashReporter.isAvailable && crashReportingEnabled) || isSending)
            }

            if let footnote {
                VStack(alignment: .leading, spacing: 4) {
                    Text(footnote)
                        .font(LibraryTokens.meta)
                        .foregroundStyle(LibraryTokens.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    if status != nil {
                        Button("Email support") {
                            onEmailSupport()
                        }
                        .buttonStyle(.transcriptedQuiet)
                        .controlSize(.small)
                        .accessibilityIdentifier("transcripted.settings.about.email-support")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
        }
    }

    private var footnote: String? {
        status ?? disabledReason
    }

    private var disabledReason: String? {
        if !CrashReporter.isAvailable {
            return "Not available in this build."
        }
        if !crashReportingEnabled {
            return "Turn on Crash reports to send diagnostics."
        }
        return nil
    }
}

/// Advanced › App: open the folder with logs and app state for support.
struct SupportFilesSettingsRow: View {
    let folder: URL

    var body: some View {
        SettingsControlRow(
            title: "Support files",
            info: GeneralInfo(
                title: "Support files",
                message: "Logs and app state for support. Not your transcripts."
            ),
            automationIdentifier: "transcripted.settings.storage.support-files",
            showsDivider: false
        ) {
            SettingsInlineActionButton(title: "Show in Finder", symbolName: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            }
        }
    }
}
