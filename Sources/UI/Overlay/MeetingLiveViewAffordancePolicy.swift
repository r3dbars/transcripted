import Foundation

/// Presentation policy for the meeting overlay's embedded live transcript.
///
/// The recording pill offers the live transcript at point of use so users do
/// not have to visit Settings → Agent mid-meeting. Clicking the button
/// toggles a transcript drawer rendered inside the overlay itself; the
/// browser/agent view stays reachable from the drawer header. The persistent
/// opt-in stays in `LiveMeetingCodexPreferences`, and the overlay only
/// performs actions — it is not a second settings surface.
///
/// When the preference is off, the click enables live meetings and opens the
/// drawer in one step. Live streaming ASR cannot attach to an in-flight
/// capture (live PCM handlers must be installed before recording starts), so
/// the off-state copy promises the panel, not live text for the current
/// meeting.
enum MeetingLiveViewAffordancePolicy {
    static let automationIdentifier = "transcripted.meeting-overlay.live-view"
    static let browserAutomationIdentifier = "transcripted.meeting-overlay.live-view.open-browser"
    static let browserTooltip = "Open live transcript in browser"
    static let copyAutomationIdentifier = "transcripted.meeting-overlay.live-view.copy"
    static let copyTooltip = "Copy live transcript"
    static let drawerTitle = "Live transcript"

    struct Affordance: Equatable {
        let tooltip: String
        let accessibilityLabel: String
        let accessibilityHelp: String
        /// True when the click should enable `LiveMeetingCodexPreferences`
        /// (and late-join the sidecar) before showing the drawer.
        let enablesLiveMeetingsOnClick: Bool
        /// True while the drawer is open so the button can render pressed-in.
        let showsActiveState: Bool
    }

    static func affordance(
        isRecording: Bool,
        isRecordingMinimized: Bool,
        isLiveMeetingSidecarEnabled: Bool,
        isTranscriptVisible: Bool
    ) -> Affordance? {
        guard isRecording, !isRecordingMinimized else { return nil }

        if isLiveMeetingSidecarEnabled {
            if isTranscriptVisible {
                return Affordance(
                    tooltip: "Hide live transcript",
                    accessibilityLabel: "Hide live transcript",
                    accessibilityHelp: "Hides the live transcript panel.",
                    enablesLiveMeetingsOnClick: false,
                    showsActiveState: true
                )
            }
            return Affordance(
                tooltip: "View live transcript",
                accessibilityLabel: "View live transcript",
                accessibilityHelp: "Shows the live transcript inside the meeting overlay.",
                enablesLiveMeetingsOnClick: false,
                showsActiveState: false
            )
        }

        return Affordance(
            tooltip: "Turn on live transcript",
            accessibilityLabel: "Turn on live transcript",
            accessibilityHelp: "Turns on live meetings and shows the live transcript panel. Live transcript lines begin with your next meeting.",
            enablesLiveMeetingsOnClick: true,
            showsActiveState: false
        )
    }

    /// Status copy shown inside the drawer instead of (or before) transcript
    /// lines. Returns nil when the drawer should render entries only.
    static func drawerStatus(
        phase: LiveMeetingTranscriptFeedPhase,
        hasEntries: Bool
    ) -> String? {
        switch phase {
        case .idle:
            return "Live transcript is off for this meeting."
        case .starting:
            return "Starting live transcription…"
        case .live:
            return hasEntries ? nil : "Listening — the live transcript appears as people talk."
        case .deferred(let note), .failed(let note):
            return note
        case .stopped:
            return hasEntries ? nil : "Recording stopped."
        }
    }
}
