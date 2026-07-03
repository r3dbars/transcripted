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

    static func shouldConfirmQuit(
        preferenceEnabled: Bool,
        activeMeetingCapture: Bool,
        backgroundTranscriptionWork: Bool = false
    ) -> Bool {
        preferenceEnabled && (activeMeetingCapture || backgroundTranscriptionWork)
    }
}

enum QuitConfirmationPreferences {
    static let confirmQuitDuringActiveMeetingRecordingKey = "confirm-quit-during-active-meeting-recording"

    static func confirmQuitDuringActiveMeetingRecording(
        userDefaults: UserDefaults = .standard
    ) -> Bool {
        guard userDefaults.object(forKey: confirmQuitDuringActiveMeetingRecordingKey) != nil else {
            return true
        }
        return userDefaults.bool(forKey: confirmQuitDuringActiveMeetingRecordingKey)
    }

    static func setConfirmQuitDuringActiveMeetingRecording(
        _ enabled: Bool,
        userDefaults: UserDefaults = .standard
    ) {
        userDefaults.set(enabled, forKey: confirmQuitDuringActiveMeetingRecordingKey)
    }
}
