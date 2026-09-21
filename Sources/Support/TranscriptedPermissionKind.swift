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

    static func requiredForCurrentUse(dictationShortcutsEnabled: Bool) -> [TranscriptedPermissionKind] {
        if dictationShortcutsEnabled {
            return [.microphone, .accessibility]
        }
        return [.microphone, .systemAudioRecording]
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

    var analyticsValue: String {
        switch self {
        case .microphone:
            return "microphone"
        case .accessibility:
            return "pasteback"
        case .systemAudioRecording:
            return "system_recording"
        case .calendar:
            return "calendar"
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
        "For the other side of calls, videos, and meetings. Audio only — no screen access needed."
    }

    struct SystemAudioOnboardingPresentation {
        let actionTitle: String
        let summary: String
        let isVerified: Bool
    }

    /// Permission approval and observed audio are separate evidence. In
    /// particular, a quiet stream must never manufacture a verified grant.
    static func systemAudioOnboardingPresentation(
        state: TranscriptedPermissionAccess.SystemAudioPermissionState,
        result: TranscriptedPermissionAccess.SystemAudioPermissionProbeResult?,
        isChecking: Bool
    ) -> SystemAudioOnboardingPresentation {
        if isChecking {
            return .init(actionTitle: "Checking…", summary: "Checking system audio. No audio is saved.", isVerified: false)
        }
        if state == .granted {
            return .init(actionTitle: "Granted", summary: systemAudioRecordingSummary, isVerified: true)
        }
        if state == .denied {
            return .init(actionTitle: "Check", summary: "Access was denied. Enable System Audio Recording Only in Settings, then check again.", isVerified: false)
        }
        if result != nil {
            return .init(actionTitle: "Check", summary: "Not yet verified. If access is enabled, you can continue. Play audio in another app, then check to verify.", isVerified: false)
        }
        return .init(actionTitle: "Grant", summary: systemAudioRecordingSummary, isVerified: false)
    }

    static var systemAudioRecordingMigrationInstructions: String {
        "In System Settings → Privacy & Security → Screen & System Audio Recording, enable Transcripted under System Audio Recording Only. If you previously allowed Screen & System Audio Recording, turn that broader permission off. Quit and reopen Transcripted if macOS asks. Play audio in another app, then check this permission again. Silence cannot distinguish a quiet Mac from denied access. Your existing recordings are unchanged."
    }

    var actionButtonTitle: String {
        switch self {
        case .microphone:
            return Self.microphoneActionTitle(for: TranscriptedPermissionAccess.microphoneAuthorizationStatus())
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
