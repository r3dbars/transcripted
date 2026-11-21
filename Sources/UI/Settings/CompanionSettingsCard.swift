import AppKit
import SwiftUI

/// Native controls remain visible even when the plugin is closed. Readiness
/// describes the local bridge; it never implies that ChatGPT has connected.
struct CompanionSettingsCard: View {
    @ObservedObject private var companion = CompanionConnectionService.shared
    @State private var promptCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ChatGPT companion")
                        .textRole(.heading)
                    HStack(spacing: 6) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 6, height: 6)
                        Text(statusText)
                            .font(LibraryTokens.meta)
                            .foregroundStyle(LibraryTokens.ink2)
                    }
                }
                Spacer(minLength: 12)
            }

            Text("Let ChatGPT follow a meeting you choose to share.")
                .font(LibraryTokens.body)
                .foregroundStyle(LibraryTokens.ink2)
                .fixedSize(horizontal: false, vertical: true)

            SettingsCard {
                SettingsControlRow(title: "Allow a local companion", info: GeneralInfo(
                    title: "Allow a local companion",
                    message: "A private connection on this Mac for meeting controls and live text. Off stops new sharing; recording carries on."
                ), automationIdentifier: "transcripted.settings.companion.enabled") {
                    Toggle("Allow a local companion", isOn: Binding(
                        get: { companion.isEnabled }, set: { companion.setEnabled($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
                SettingsControlRow(title: "Start and stop meetings", info: GeneralInfo(
                    title: "Start and stop meetings",
                    message: "ChatGPT can start recording when you ask, and stop the meeting you pick."
                ), automationIdentifier: "transcripted.settings.companion.meeting-control") {
                    Toggle("Start and stop meetings", isOn: Binding(
                        get: { companion.allowsMeetingControl }, set: { companion.setAllowsMeetingControl($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!companion.isEnabled)
                }
                SettingsControlRow(title: "Allow live transcript sharing", info: GeneralInfo(
                    title: "Allow live transcript sharing",
                    message: "Each meeting starts private. When you share one, its live text goes to ChatGPT and stays in that conversation even after you stop sharing."
                ), automationIdentifier: "transcripted.settings.companion.live-sharing", showsDivider: false) {
                    Toggle("Allow live transcript sharing", isOn: Binding(
                        get: { companion.allowsLiveSharing }, set: { companion.setAllowsLiveSharing($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!companion.isEnabled)
                }
            }

            if companion.isEnabled, companion.allowsLiveSharing,
               companion.captureActive || companion.liveSharingActive {
                HStack(spacing: 10) {
                    Image(systemName: companion.liveSharingActive ? "waveform" : "lock.fill")
                        .foregroundStyle(companion.liveSharingActive ? LibraryTokens.accent : LibraryTokens.ink2)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(companion.liveSharingActive ? "This meeting’s live context is shared" : "This meeting is private")
                            .font(LibraryTokens.rowTitle)
                        Text(companion.liveSharingActive
                            ? "Turn off sharing to clear this Mac’s live preview."
                            : "Share when you want ChatGPT to follow along.")
                            .font(LibraryTokens.meta)
                            .foregroundStyle(LibraryTokens.ink2)
                    }
                    Spacer(minLength: 8)
                    Toggle("Share this meeting", isOn: Binding(
                        get: { companion.liveSharingActive }, set: { companion.setCurrentMeetingSharing($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!companion.liveSharingActive && !companion.canShareCurrentMeeting)
                }
                .padding(14)
                .background(LibraryTokens.raisedFill, in: RoundedRectangle(cornerRadius: LibraryTokens.radiusRaised))
                .accessibilityIdentifier("transcripted.settings.companion.current-meeting-sharing")
            }

            if let issue = companion.connectionIssue {
                HStack(alignment: .center, spacing: 12) {
                    Text(issue)
                        .font(LibraryTokens.meta)
                        .foregroundStyle(LibraryTokens.attention)
                    Spacer(minLength: 8)
                    SettingsInlineActionButton(title: "Reconnect") { companion.reconnect() }
                }
            }

            HStack(alignment: .center, spacing: 12) {
                Spacer(minLength: 8)
                SettingsInlineActionButton(title: promptCopied ? "Copied" : "Copy setup prompt") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString("Use the Transcripted plugin to check the local companion connection. Show me meeting status first. Start recording or share live text only when I explicitly ask.", forType: .string)
                    promptCopied = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(2))
                        promptCopied = false
                    }
                }
                .accessibilityIdentifier("transcripted.settings.companion.copy-setup")
            }
        }
        .frame(maxWidth: 620, alignment: .leading)
        .accessibilityIdentifier("transcripted.settings.companion.card")
    }

    private var statusText: String {
        if !companion.isEnabled { return "Off · you’re in control" }
        return companion.isListening ? "Ready on this Mac" : "Needs attention"
    }

    private var statusColor: Color {
        if !companion.isEnabled { return LibraryTokens.ink2 }
        // Ready is fine, not live: neutral. Live sharing keeps the green.
        return companion.isListening ? LibraryTokens.ink2 : LibraryTokens.attention
    }
}
