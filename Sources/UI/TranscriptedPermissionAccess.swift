import AppKit
import AVFoundation
import ApplicationServices
import EventKit

enum TranscriptedPermissionKind: String, CaseIterable, Identifiable {
    case microphone
    case accessibility
    case screenRecording
    case calendar

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .microphone:
            return "mic.fill"
        case .accessibility:
            return "hand.raised.fill"
        case .screenRecording:
            return "rectangle.on.rectangle"
        case .calendar:
            return "calendar"
        }
    }

    var isRequiredOnFirstLaunch: Bool {
        switch self {
        case .microphone, .accessibility:
            return true
        case .screenRecording, .calendar:
            return false
        }
    }

    var title: String {
        switch self {
        case .microphone:
            return "Microphone"
        case .accessibility:
            return "Accessibility"
        case .screenRecording:
            return "Screen Recording"
        case .calendar:
            return "Calendar"
        }
    }

    var summary: String {
        switch self {
        case .microphone:
            return "Needed for dictation and your side of meetings."
        case .accessibility:
            return "Needed for global shortcuts and pasting text back into the app you were using."
        case .screenRecording:
            return "Optional for meeting capture. Needed when you want call audio from other apps."
        case .calendar:
            return "Optional for meeting prompts. Lets Transcripted notice upcoming meetings from Apple Calendar, Google, or Exchange calendars synced to your Mac."
        }
    }

    var onboardingActionTitle: String {
        switch self {
        case .microphone:
            return "Allow microphone"
        case .accessibility:
            return "Allow accessibility"
        case .screenRecording:
            return "Enable meeting audio"
        case .calendar:
            return "Enable meeting prompts"
        }
    }
}

enum TranscriptedPermissionAccess {
    static func isGranted(_ kind: TranscriptedPermissionKind) -> Bool {
        switch kind {
        case .microphone:
            return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .accessibility:
            return AXIsProcessTrusted()
        case .screenRecording:
            return screenRecordingGranted()
        case .calendar:
            return calendarAccessGranted()
        }
    }

    static func openSettings(for kind: TranscriptedPermissionKind) {
        switch kind {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                break
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    guard !granted else { return }
                    Task { @MainActor in
                        openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
                    }
                }
            case .denied, .restricted:
                openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
            @unknown default:
                openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
            }
        case .accessibility:
            if !AXIsProcessTrusted() {
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            }
            openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        case .screenRecording:
            if #available(macOS 15.0, *) {
                _ = CGRequestScreenCaptureAccess()
            }
            openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        case .calendar:
            Task { @MainActor in
                let granted = await requestCalendarAccessIfNeeded()
                guard !granted else { return }
                openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
            }
        }
    }

    static func requestCalendarAccessIfNeeded() async -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .fullAccess:
            return true
        case .authorized:
            return true
        case .notDetermined:
            let store = EKEventStore()
            do {
                return try await store.requestFullAccessToEvents()
            } catch {
                return false
            }
        case .writeOnly, .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    static func calendarAccessGranted() -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .fullAccess, .authorized:
            return true
        case .writeOnly, .denied, .restricted, .notDetermined:
            return false
        @unknown default:
            return false
        }
    }

    static func screenRecordingGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    private static func openSystemSettings(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        Task { @MainActor in
            NSWorkspace.shared.open(url)
        }
    }
}
