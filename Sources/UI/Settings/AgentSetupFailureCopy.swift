import Foundation

/// Plain-words copy for Agent-page setup failures.
///
/// Foundation-pure so the strings can be pinned by fast tests and can never
/// regress to a raw `error.localizedDescription` dump the way these sites did
/// before. Each message says what happened and the one thing to try; the raw
/// error is offered separately behind "Copy Details", never shown inline. Plain
/// words, no jargon, no exclamation marks — the repo voice convention.
///
/// This mirrors `HomeActionFailureCopy` (the meeting/Home path's template):
/// classify the failure into a context, return `{plain message}`, and keep the
/// raw string for a reveal affordance while the triggering control provides retry.
enum AgentSetupFailureCopy {
    /// Title for the reveal affordance that copies the raw error to the clipboard.
    static let detailsTitle = "Copy Details"

    static func connect(agentName: String) -> String {
        "Transcripted couldn't connect \(agentName). Check that it's installed and not already running, then try Connect again."
    }

    static let liveMeetings =
        "Transcripted couldn't set up Live Meetings. Check that Codex is installed, then try again."

    static let liveMeetingsPrepare =
        "Transcripted couldn't prepare Live Meetings. Try turning it on again."

    static let liveView =
        "Transcripted couldn't open the live view. Try turning Live Meetings on again."

    static let codexInbox =
        "Transcripted couldn't set up the Codex inbox. Check that Codex is installed and you have free disk space, then try again."
}
