import SwiftUI

/// The Settings > Support page. Extracted from `TranscriptedSettingsView`
/// (codebase audit 2026-07-08 wave 2, spec W2-A). Tracking and diagnostic
/// dispatch stay owned by the parent and are passed in as closures.
struct SupportSettingsPage: View {
    let diagnosticsActionStatus: String?
    let crashReportingEnabled: Bool
    let onSubmitFeedback: () -> Void
    let onSendDiagnosticEvent: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsPageIntro(
                title: "Support",
                summary: "Need help, found a bug, or want to send feedback? Email is the best way to reach the team building Transcripted."
            )

            SupportActionCard(
                symbolName: "envelope.fill",
                title: "Email support",
                detail: "Send feedback, ask for help, or tell us what felt broken. This opens a prefilled email to help@transcripted.app.",
                buttonTitle: "Email support",
                buttonSymbolName: "paperplane.fill",
                tone: .primary,
                status: nil,
                isEnabled: true,
                action: onSubmitFeedback
            )

            SupportActionCard(
                symbolName: "waveform.path.ecg",
                title: "Send diagnostics",
                detail: "Had an error or something felt broken? Send a privacy-safe diagnostic event so we can investigate and try to fix it.",
                buttonTitle: "One-click send diagnostics",
                buttonSymbolName: "bolt.fill",
                tone: .secondary,
                status: diagnosticsActionStatus,
                isEnabled: CrashReporter.isAvailable && crashReportingEnabled,
                action: onSendDiagnosticEvent
            )

            SupportPrivacyNote()
        }
        .accessibilityIdentifier("transcripted.settings.page.support")
    }
}
