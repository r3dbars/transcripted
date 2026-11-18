import Foundation

/// Island copy and routing for an auto-started detected call. Stop and
/// Discard sit together here on purpose: the recording began without a
/// prompt, so discarding must be one tap (then a confirmation) rather than
/// buried in the right-click menu.
enum MeetingAutoRecordNoteCopy {
    static let title = "Recording automatically"
    static let detail = "This call started without asking."
    static let primaryTitle = "Stop"
    static let secondaryTitle = "Discard"
    /// Short enough to get out of the way of the call-audio ask.
    static let visibleDuration: TimeInterval = 8

    static func isVisible(
        duration: TimeInterval,
        asksAboutCallAudio: Bool,
        noteEnabled: Bool
    ) -> Bool {
        noteEnabled && !asksAboutCallAudio && duration < visibleDuration
    }

    static var prompt: NotchIslandMeetingContent.Prompt {
        NotchIslandMeetingContent.Prompt(
            title: title,
            detail: detail,
            countdown: "",
            primaryTitle: primaryTitle,
            secondaryTitle: secondaryTitle,
            tertiaryTitle: nil,
            // Stop keeps the recording, so it's the safe primary; Discard
            // throws it away (after a confirmation), so it's the red one.
            primaryRole: .primary,
            secondaryRole: .destructive
        )
    }
}

enum MeetingAutoRecordIslandActionPolicy {
    enum Route: Equatable {
        case stop
        case discard
        case inherit
    }

    /// While the consent note is up and no overlay warning owns the island,
    /// Stop ends the recording and Discard asks to delete it.
    static func route(
        action: NotchIslandAction,
        noteVisible: Bool,
        recordingID: UUID?
    ) -> Route {
        guard noteVisible, case .meetingPrompt(let button, .autoRecord(let id)) = action,
              recordingID == id else { return .inherit }
        switch button {
        case .primary:
            return .stop
        case .secondary:
            return .discard
        default:
            return .inherit
        }
    }
}
