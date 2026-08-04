import SwiftUI

/// Single owner for the live-meeting Codex sidecar workspace lifecycle.
///
/// Two Settings surfaces expose the same `LiveMeetingCodexPreferences.enabledKey`
/// toggle — the Beta page (`TranscriptedSettingsView`) and the Agent page
/// (`AgentConnectionSettingsPage`) — and both used to hand-roll identical
/// prepare/stop/disable logic. This type is the one place that logic lives now;
/// both toggle sites route through it so the workspace-preparation, preview-server,
/// and meeting-session teardown behavior can't drift between them again.
///
/// `@MainActor` because both call sites are `View`-conforming settings pages
/// (implicitly main-actor isolated) and `stop(meetingSession:)` calls into
/// `MeetingSessionController`, which is itself `@MainActor`.
@MainActor
enum LiveMeetingSidecarController {
    /// Ensures the live-meeting Codex workspace folder exists and starts the
    /// local preview server for it (macOS 14+). Returns the workspace URL.
    @discardableResult
    static func prepareWorkspaceForUse() throws -> URL {
        let workspaceURL = try AgentConnectionGuide.ensureLiveMeetingCodexWorkspace()
        if #available(macOS 14.0, *) {
            _ = try LiveMeetingPreviewServer.shared.start(workspaceURL: workspaceURL)
        }
        return workspaceURL
    }

    /// Stops any active live-codex meeting session and the local preview server.
    /// Used both for an explicit user-initiated disable and after a
    /// workspace-preparation failure.
    static func stop(meetingSession: MeetingSessionController?) {
        meetingSession?.stopLiveCodexSessionFromSettings()
        if #available(macOS 14.0, *) {
            LiveMeetingPreviewServer.shared.stop()
        }
    }

    /// Turns the sidecar off: clears the persisted flag and local mirror, then
    /// tears down any active session and the preview server via `stop(meetingSession:)`.
    static func disable(enabled: Binding<Bool>, meetingSession: MeetingSessionController?) {
        enabled.wrappedValue = false
        LiveMeetingCodexPreferences.setEnabled(false)
        stop(meetingSession: meetingSession)
    }
}
