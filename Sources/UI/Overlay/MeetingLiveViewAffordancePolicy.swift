import Foundation

/// Presentation policy for the meeting overlay's embedded live transcript.
///
/// The recording pill itself is the affordance: clicking the pill body
/// toggles a transcript drawer rendered inside the overlay, and the pill's
/// context menu carries the secondary actions (pin, browser view, discard).
/// The persistent opt-in stays in `LiveMeetingCodexPreferences`; the overlay
/// only performs actions — it is not a second settings surface.
///
/// When the preference is off, the click enables live meetings and opens the
/// drawer in one step. Live streaming ASR cannot attach to an in-flight
/// capture (live PCM handlers must be installed before recording starts), so
/// the off-state copy promises the panel, not live text for the current
/// meeting.
enum MeetingLiveViewAffordancePolicy {
    static let automationIdentifier = "transcripted.meeting-overlay.live-view"
    static let copyAutomationIdentifier = "transcripted.meeting-overlay.live-view.copy"
    static let moreAutomationIdentifier = "transcripted.meeting-overlay.live-view.more"
    static let copyTooltip = "Copy live transcript"
    static let moreTooltip = "More options"
    static let drawerTitle = "Live transcript"

    // Context- and overflow-menu copy (menus use Title Case per macOS
    // convention; tooltips stay sentence case).
    static let copyTranscriptMenuTitle = "Copy Transcript"
    static let openInBrowserMenuTitle = "Open Live View in Browser"
    static let keepControlsVisibleMenuTitle = "Keep Controls Visible"
    static let discardRecordingMenuTitle = "Discard Recording…"

    struct Affordance: Equatable {
        let tooltip: String
        let accessibilityLabel: String
        let accessibilityHelp: String
        /// True when the click should enable `LiveMeetingCodexPreferences`
        /// (and late-join the sidecar) before showing the drawer.
        let enablesLiveMeetingsOnClick: Bool
    }

    static func affordance(
        isRecording: Bool,
        isLiveMeetingSidecarEnabled: Bool,
        isTranscriptVisible: Bool
    ) -> Affordance? {
        guard isRecording else { return nil }

        if isLiveMeetingSidecarEnabled {
            if isTranscriptVisible {
                return Affordance(
                    tooltip: "Hide live transcript",
                    accessibilityLabel: "Hide live transcript",
                    accessibilityHelp: "Hides the live transcript panel.",
                    enablesLiveMeetingsOnClick: false
                )
            }
            return Affordance(
                tooltip: "View live transcript",
                accessibilityLabel: "View live transcript",
                accessibilityHelp: "Shows the live transcript inside the meeting overlay.",
                enablesLiveMeetingsOnClick: false
            )
        }

        return Affordance(
            tooltip: "Turn on live transcript",
            accessibilityLabel: "Turn on live transcript",
            accessibilityHelp: "Turns on live meetings and shows the live transcript panel. Live transcript lines begin with your next meeting.",
            enablesLiveMeetingsOnClick: true
        )
    }

    static func transcriptToggleMenuTitle(
        isLiveMeetingSidecarEnabled: Bool,
        isTranscriptVisible: Bool
    ) -> String {
        guard isLiveMeetingSidecarEnabled else { return "Turn On Live Transcript" }
        return isTranscriptVisible ? "Hide Live Transcript" : "View Live Transcript"
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
