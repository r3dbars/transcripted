import Foundation

struct ActiveMeetingQuitConfirmationPresentation: Equatable {
    let title: String
    let message: String
    let keepRecordingTitle: String
    let stopAndTranscribeTitle: String
    let saveAudioAndQuitTitle: String
}

struct BackgroundMeetingQuitConfirmationPresentation: Equatable {
    let title: String
    let message: String
    let keepOpenTitle: String
    let saveAudioAndQuitTitle: String
}

enum ActiveMeetingQuitDecision: Equatable {
    case keepRecording
    case stopAndTranscribe
    case saveAudioAndQuit
}

enum ActiveMeetingQuitConfirmationPolicy {
    static let presentation = ActiveMeetingQuitConfirmationPresentation(
        title: "Meeting work is still running",
        message: "Keep Transcripted open to finish the transcript, stop and make the transcript now, or save the audio and quit. Saved audio will show on Home so you can finish it later.",
        keepRecordingTitle: "Keep Recording",
        stopAndTranscribeTitle: "Stop & Transcribe",
        saveAudioAndQuitTitle: "Save Audio & Quit"
    )

    static let backgroundPresentation = BackgroundMeetingQuitConfirmationPresentation(
        title: "Meeting transcript is still running",
        message: "Keep Transcripted open to finish it now, or save the audio and quit. Saved audio will show on Home so you can finish it later.",
        keepOpenTitle: "Keep Open",
        saveAudioAndQuitTitle: "Save Audio & Quit"
    )

    /// Quit confirmation during meeting work is always on — the old opt-out
    /// preference (`confirm-quit-during-active-meeting-recording`) was removed
    /// by owner decision so nobody can accidentally kill a live recording.
    static func shouldConfirmQuit(
        activeMeetingCapture: Bool,
        backgroundTranscriptionWork: Bool = false
    ) -> Bool {
        activeMeetingCapture || backgroundTranscriptionWork
    }
}
