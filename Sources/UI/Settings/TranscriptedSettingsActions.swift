import Foundation

@MainActor
struct TranscriptedSettingsActions {
    let startDictation: () -> Void
    let startMeeting: () -> Void
    let importAudioFile: () -> Void
    let pasteLastDictation: () -> Void
    let openConnectAgent: () -> Void
    let checkForUpdates: () -> Void
    let sendFeedback: () -> TranscriptedSupportActions.FeedbackEmailResult
    let copyDiagnostics: () -> Bool
    let sendDiagnosticEvent: () -> String?
}
