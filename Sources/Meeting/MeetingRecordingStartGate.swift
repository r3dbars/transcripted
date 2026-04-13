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

enum MeetingRecordingStartGate {
    static func evaluate(
        microphoneGranted: Bool,
        screenRecordingGranted: Bool
    ) -> MeetingRecordingStartDecision {
        let missingPermissions = [
            microphoneGranted ? nil : "microphone",
            screenRecordingGranted ? nil : "screen_recording"
        ].compactMap { $0 }

        guard !missingPermissions.isEmpty else {
            return .allowed
        }

        switch missingPermissions {
        case ["microphone", "screen_recording"]:
            return MeetingRecordingStartDecision(
                canStart: false,
                errorMessage: "Turn on Microphone and Screen Recording in System Settings before recording a meeting.",
                failureReason: "microphone_and_screen_recording",
                missingPermissions: missingPermissions
            )
        case ["microphone"]:
            return MeetingRecordingStartDecision(
                canStart: false,
                errorMessage: "Turn on Microphone access in System Settings before recording a meeting.",
                failureReason: "microphone",
                missingPermissions: missingPermissions
            )
        case ["screen_recording"]:
            return MeetingRecordingStartDecision(
                canStart: false,
                errorMessage: "Turn on Screen Recording in System Settings before recording a meeting.",
                failureReason: "screen_recording",
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
