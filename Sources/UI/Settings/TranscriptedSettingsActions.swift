import Foundation

@MainActor
struct TranscriptedSettingsActions {
    let startDictation: () -> Void
    let startMeeting: () -> Void
    let importAudioFile: () -> Void
    /// Files dropped onto Home. Unsupported files are filtered out by the app.
    let importAudioFiles: ([URL]) -> Void
    /// Drops files still waiting to be handed to the import flow.
    let cancelPendingAudioImports: () -> Void
    let sendFeedback: () -> Void
    let sendDiagnosticEvent: () -> String?
}
