import Foundation

struct MeetingRecordingStartDecision: Equatable {
    let canStart: Bool
    let errorMessage: String?
    let failureReason: String?
    let missingPermissions: [String]
    let systemAudioPermissionCheckWasInconclusive: Bool

    init(
        canStart: Bool,
        errorMessage: String?,
        failureReason: String?,
        missingPermissions: [String],
        systemAudioPermissionCheckWasInconclusive: Bool = false
    ) {
        self.canStart = canStart
        self.errorMessage = errorMessage
        self.failureReason = failureReason
        self.missingPermissions = missingPermissions
        self.systemAudioPermissionCheckWasInconclusive = systemAudioPermissionCheckWasInconclusive
    }

    static let allowed = MeetingRecordingStartDecision(
        canStart: true,
        errorMessage: nil,
        failureReason: nil,
        missingPermissions: []
    )

    func markingSystemAudioPermissionCheckInconclusive() -> MeetingRecordingStartDecision {
        MeetingRecordingStartDecision(
            canStart: canStart,
            errorMessage: errorMessage,
            failureReason: failureReason,
            missingPermissions: missingPermissions,
            systemAudioPermissionCheckWasInconclusive: true
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

    /// A ScreenCaptureKit probe can be inconclusive even when the user has not
    /// denied access. Keep that distinct from the missing-permission copy so a
    /// transient macOS audio-service failure never tells the user to toggle a
    /// permission we did not actually observe as denied.
    static func systemAudioVerificationUnavailable() -> MeetingRecordingStartDecision {
        MeetingRecordingStartDecision(
            canStart: false,
            errorMessage: "Transcripted couldn't verify System Audio Recording because macOS didn't finish the check. Try recording again. If it keeps happening, confirm System Audio Recording is on in System Settings.",
            failureReason: "system_audio_recording_check_unavailable",
            missingPermissions: [],
            systemAudioPermissionCheckWasInconclusive: true
        )
    }

    /// If a cached grant survived an inconclusive preflight, a later capture
    /// service error is not proof that the user revoked access. Strip only the
    /// permission-specific blame from that start failure; ordinary mic, stream,
    /// and timeout errors keep their more precise copy.
    static func captureFailureMessage(
        _ rawMessage: String,
        systemAudioPermissionCheckWasInconclusive: Bool,
        explicitSystemAudioPermissionDenialObserved: Bool = false
    ) -> String {
        // A typed denial from the actual capture attempt outranks the earlier
        // inconclusive preflight. Keep the direct Settings recovery copy.
        guard !explicitSystemAudioPermissionDenialObserved else { return rawMessage }
        guard systemAudioPermissionCheckWasInconclusive else { return rawMessage }

        let normalized = rawMessage.lowercased()
        let blamesSystemAudioPermission = normalized.contains("system audio")
            && (
                normalized.contains("system settings")
                    || normalized.contains("enable system audio recording")
                    || normalized.contains("permission")
            )
        guard blamesSystemAudioPermission else { return rawMessage }

        return "System audio didn't start after macOS returned an inconclusive access check. Try recording again. If it keeps happening, quit and reopen Transcripted."
    }
}
