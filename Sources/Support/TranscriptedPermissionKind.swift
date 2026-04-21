import AVFoundation
import ApplicationServices
import EventKit

enum TranscriptedPermissionKind: String, CaseIterable, Identifiable {
    case microphone
    case accessibility
    case systemAudioRecording
    case calendar

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .microphone:
            return "mic.fill"
        case .accessibility:
            return "hand.raised.fill"
        case .systemAudioRecording:
            return "speaker.wave.2.fill"
        case .calendar:
            return "calendar"
        }
    }

    var isRequiredOnFirstLaunch: Bool {
        switch self {
        case .microphone, .accessibility:
            return true
        case .systemAudioRecording, .calendar:
            return false
        }
    }

    var title: String {
        switch self {
        case .microphone:
            return "Microphone"
        case .accessibility:
            return "Accessibility"
        case .systemAudioRecording:
            return "System Audio Recording"
        case .calendar:
            return "Calendar"
        }
    }

    var summary: String {
        switch self {
        case .microphone:
            return "For dictation and your side of meetings."
        case .accessibility:
            return "For shortcuts and paste-back."
        case .systemAudioRecording:
            return Self.systemAudioRecordingSummary
        case .calendar:
            return "Optional. Shows meeting prompts from synced calendars."
        }
    }

    static var systemAudioRecordingSummary: String {
        "For the other side of calls, videos, and meetings."
    }

    var actionButtonTitle: String {
        switch self {
        case .microphone:
            return Self.microphoneActionTitle(for: AVCaptureDevice.authorizationStatus(for: .audio))
        case .accessibility:
            return Self.accessibilityActionTitle(isTrusted: AXIsProcessTrusted())
        case .systemAudioRecording:
            return Self.systemAudioRecordingActionTitle(for: TranscriptedPermissionAccess.systemAudioRecordingStatus())
        case .calendar:
            return Self.calendarActionTitle(for: EKEventStore.authorizationStatus(for: .event))
        }
    }

    static func microphoneActionTitle(for status: AVAuthorizationStatus) -> String {
        switch status {
        case .notDetermined:
            return "Allow microphone"
        case .denied, .restricted:
            return "Open Microphone Settings"
        case .authorized:
            return "Review"
        @unknown default:
            return "Open Microphone Settings"
        }
    }

    static func accessibilityActionTitle(isTrusted: Bool) -> String {
        isTrusted ? "Review" : "Open Accessibility Settings"
    }

    static func systemAudioRecordingActionTitle(for status: TranscriptedPermissionAccess.SystemAudioPermissionState) -> String {
        switch status {
        case .granted:
            return "Review"
        case .unknown:
            return "Check System Audio Recording"
        case .denied:
            return "Open Audio Recording Settings"
        }
    }

    static func calendarActionTitle(for status: EKAuthorizationStatus) -> String {
        switch status {
        case .fullAccess, .authorized:
            return "Review"
        case .notDetermined:
            return "Allow Calendar Access"
        case .writeOnly, .denied, .restricted:
            return "Open Calendar Settings"
        @unknown default:
            return "Open Calendar Settings"
        }
    }
}
