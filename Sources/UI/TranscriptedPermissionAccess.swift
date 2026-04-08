import AppKit
import AVFoundation
import ApplicationServices

enum TranscriptedPermissionKind: String, CaseIterable, Identifiable {
    case microphone
    case accessibility
    case screenRecording

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .microphone:
            return "mic.fill"
        case .accessibility:
            return "hand.raised.fill"
        case .screenRecording:
            return "rectangle.on.rectangle"
        }
    }

    var isRequiredOnFirstLaunch: Bool {
        switch self {
        case .microphone, .accessibility:
            return true
        case .screenRecording:
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
        }
    }

    static func screenRecordingGranted() -> Bool {
        if #available(macOS 15.0, *) {
            return CGPreflightScreenCaptureAccess()
        }

        let testImage = CGWindowListCreateImage(
            CGRect(x: 0, y: 0, width: 1, height: 1),
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.nominalResolution]
        )
        return testImage != nil
    }

    private static func openSystemSettings(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        Task { @MainActor in
            NSWorkspace.shared.open(url)
        }
    }
}
