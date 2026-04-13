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
    static var screenRecordingSummary: String {
        "Optional on first launch. Required before Transcripted can capture meeting audio from other apps."
    }

    static var screenRecordingQuickStart: String {
        if #available(macOS 26.0, *) {
            return "Turn on System Audio Recording before you record meetings so Transcripted can capture the other side of Zoom, Meet, and similar apps."
        }
        return "Turn on Screen Recording before you record meetings so Transcripted can capture the other side of Zoom, Meet, and similar apps."
    }

    static var optionalPermissionsFootnote: String {
        if #available(macOS 26.0, *) {
            return "You can start dictating without these. Turn on System Audio Recording before you record meetings, and add Calendar later if you want meeting prompts."
        }
        return "You can start dictating without these. Turn on Screen Recording before you record meetings, and add Calendar later if you want meeting prompts."
    }

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
            let message: String
            if #available(macOS 26.0, *) {
                message = "Turn on System Audio Recording in System Settings before recording a meeting."
            } else {
                message = "Turn on Screen Recording in System Settings before recording a meeting."
            }
            return MeetingRecordingStartDecision(
                canStart: false,
                errorMessage: message,
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
