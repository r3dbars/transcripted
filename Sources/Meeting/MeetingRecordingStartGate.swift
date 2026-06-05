import Foundation

struct MeetingRecordingStartDecision: Equatable {
    let canStart: Bool
    let errorMessage: String?
    let failureReason: String?
    let missingPermissions: [String]

    static let allowed = MeetingRecordingStartDecision(
        canStart: true,
        errorMessage: nil,
        failureReason: nil,
        missingPermissions: []
    )
}

struct ActiveAudioCaptureStartDecision: Equatable {
    let canStart: Bool
    let errorMessage: String?
    let failureReason: String?

    static let allowed = ActiveAudioCaptureStartDecision(
        canStart: true,
        errorMessage: nil,
        failureReason: nil
    )
}

enum ActiveAudioCaptureStartGate {
    static func evaluateMeetingStart(
        dictationIsRecording: Bool,
        dictationIsTranscribing: Bool
    ) -> ActiveAudioCaptureStartDecision {
        if dictationIsRecording {
            return ActiveAudioCaptureStartDecision(
                canStart: false,
                errorMessage: "Finish the current dictation before recording a meeting.",
                failureReason: "dictation_recording_active"
            )
        }

        if dictationIsTranscribing {
            return ActiveAudioCaptureStartDecision(
                canStart: false,
                errorMessage: "Transcripted is still finishing dictation. Try recording the meeting again in a moment.",
                failureReason: "dictation_transcribing_active"
            )
        }

        return .allowed
    }

    static func evaluateDictationStart(meetingCaptureIsActive: Bool) -> ActiveAudioCaptureStartDecision {
        guard meetingCaptureIsActive else { return .allowed }

        return ActiveAudioCaptureStartDecision(
            canStart: false,
            errorMessage: "Stop the meeting recording before starting dictation.",
            failureReason: "meeting_recording_active"
        )
    }
}

enum MeetingRecordingStartGate {
    static var systemAudioRecordingSummary: String {
        TranscriptedPermissionKind.systemAudioRecordingSummary
    }

    static var systemAudioRecordingQuickStart: String {
        "Transcripted will ask for System Audio Recording the first time you record a meeting so it can capture the other side of Zoom, Meet, and similar apps."
    }

    static var optionalPermissionsFootnote: String {
        "System Audio Recording is requested when you record your first meeting. Calendar is optional if you want Transcripted to spot upcoming meetings and offer a record prompt."
    }

    static func evaluate(
        microphoneGranted: Bool,
        systemAudioRecordingGranted: Bool
    ) -> MeetingRecordingStartDecision {
        let missingPermissions = [
            microphoneGranted ? nil : "microphone",
            systemAudioRecordingGranted ? nil : "system_audio_recording"
        ].compactMap { $0 }

        guard !missingPermissions.isEmpty else {
            return .allowed
        }

        switch missingPermissions {
        case ["microphone", "system_audio_recording"]:
            return MeetingRecordingStartDecision(
                canStart: false,
                errorMessage: "Turn on Microphone and System Audio Recording before recording a meeting.",
                failureReason: "microphone_and_system_audio_recording",
                missingPermissions: missingPermissions
            )
        case ["microphone"]:
            return MeetingRecordingStartDecision(
                canStart: false,
                errorMessage: "Turn on Microphone access in System Settings before recording a meeting.",
                failureReason: "microphone",
                missingPermissions: missingPermissions
            )
        case ["system_audio_recording"]:
            return MeetingRecordingStartDecision(
                canStart: false,
                errorMessage: "Turn on System Audio Recording before recording a meeting.",
                failureReason: "system_audio_recording",
                missingPermissions: missingPermissions
            )
        default:
            return MeetingRecordingStartDecision(
                canStart: false,
                errorMessage: "Turn on the required permissions in System Settings before recording a meeting.",
                failureReason: "permissions",
                missingPermissions: missingPermissions
            )
        }
    }
}
