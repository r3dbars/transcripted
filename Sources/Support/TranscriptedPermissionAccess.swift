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
            if #available(macOS 26.0, *) {
                return "System Audio Recording"
            }
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
            return MeetingRecordingStartGate.screenRecordingSummary
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

    @MainActor
    static func openSettings(for kind: TranscriptedPermissionKind) {
        switch kind {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                break
            case .notDetermined:
                activateForPermissionPrompt()
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
            if #available(macOS 26.0, *) {
                // macOS 26: direct to the lighter "System Audio Recording Only" section
                activateForPermissionPrompt()
                openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")
            } else {
                activateForPermissionPrompt()
                _ = CGRequestScreenCaptureAccess()
                openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
            }
        case .calendar:
            Task { @MainActor in
                activateForPermissionPrompt()
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
        if #available(macOS 26.0, *) {
            // On macOS 26, ScreenCaptureKit presents an inline permission dialog
            // when SCStream.startCapture() is called — the user can approve it
            // on the spot without visiting System Settings. CGPreflightScreenCaptureAccess()
            // returns false before that dialog has been shown, which would incorrectly
            // block the recording flow. Return true so the gate lets the flow proceed
            // to SCKAudioCapture, where startCapture() will trigger the dialog.
            return true
        }
        return CGPreflightScreenCaptureAccess()
    }

    @MainActor
    private static func activateForPermissionPrompt() {
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    private static func openSystemSettings(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
