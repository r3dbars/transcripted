import Foundation

/// Presentation policy for the meeting overlay's embedded live transcript.
///
/// The recording pill itself is the affordance: clicking the pill body
/// toggles a transcript drawer rendered inside the overlay, and the pill's
/// context menu carries the secondary actions (pin and discard).
enum MeetingLiveViewAffordancePolicy {
    static let automationIdentifier = "transcripted.meeting-overlay.live-view"
    static let copyAutomationIdentifier = "transcripted.meeting-overlay.live-view.copy"
    static let copyTooltip = "Copy live transcript"
    static let drawerTitle = "Live transcript"

    // Context- and overflow-menu copy (menus use Title Case per macOS
    // convention; tooltips stay sentence case).
    static let keepControlsVisibleMenuTitle = "Keep Controls Visible"
    static let discardRecordingMenuTitle = "Discard Recording…"

    struct Affordance: Equatable {
        let tooltip: String
        let accessibilityLabel: String
        let accessibilityHelp: String
    }

    static func affordance(
        isRecording: Bool,
        isTranscriptVisible: Bool
    ) -> Affordance? {
        guard isRecording else { return nil }

        if isTranscriptVisible {
            return Affordance(
                tooltip: "Hide live transcript",
                accessibilityLabel: "Hide live transcript",
                accessibilityHelp: "Hides the live transcript panel."
            )
        }

        return Affordance(
            tooltip: "View live transcript",
            accessibilityLabel: "View live transcript",
            accessibilityHelp: "Shows the live transcript inside the meeting overlay."
        )
    }

    static func transcriptToggleMenuTitle(isTranscriptVisible: Bool) -> String {
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
