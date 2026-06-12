import Foundation

/// Presentation policy for the meeting overlay's "Live View" affordance.
///
/// The recording pill offers the live-meeting sidecar view at point of use so
/// users do not have to visit Settings → Agent mid-meeting. The policy decides
/// when the button renders and which copy it carries; the persistent opt-in
/// stays in `LiveMeetingCodexPreferences`, and the overlay only performs an
/// action — it is not a second settings surface.
///
/// When the preference is off, the click enables live meetings and opens the
/// view in one step. Live streaming ASR cannot attach to an in-flight capture
/// (live PCM handlers must be installed before recording starts), so the
/// off-state copy promises the view, not live text for the current meeting.
enum MeetingLiveViewAffordancePolicy {
    static let automationIdentifier = "transcripted.meeting-overlay.live-view"

    struct Affordance: Equatable {
        let tooltip: String
        let accessibilityLabel: String
        let accessibilityHelp: String
        /// True when the click should enable `LiveMeetingCodexPreferences`
        /// (and late-join the sidecar) before opening the view.
        let enablesLiveMeetingsOnClick: Bool
    }

    static func affordance(
        isRecording: Bool,
        isRecordingMinimized: Bool,
        isLiveMeetingSidecarEnabled: Bool
    ) -> Affordance? {
        guard isRecording, !isRecordingMinimized else { return nil }

        if isLiveMeetingSidecarEnabled {
            return Affordance(
                tooltip: "Open live transcript view",
                accessibilityLabel: "Open live transcript view",
                accessibilityHelp: "Opens the local live transcript page in your browser.",
                enablesLiveMeetingsOnClick: false
            )
        }

        return Affordance(
            tooltip: "Turn on live transcript view",
            accessibilityLabel: "Turn on live transcript view",
            accessibilityHelp: "Turns on live meetings and opens the local live transcript page in your browser. Live transcript lines begin with your next meeting.",
            enablesLiveMeetingsOnClick: true
        )
    }
}
