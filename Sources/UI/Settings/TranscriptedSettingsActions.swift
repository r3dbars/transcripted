import Foundation

@MainActor
struct TranscriptedSettingsActions {
    let startDictation: () -> Void
    let startMeeting: () -> Void
    let importAudioFile: () -> Void
    let sendFeedback: () -> Void
    let sendDiagnosticEvent: () -> String?
}
