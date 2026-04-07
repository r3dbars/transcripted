import AppKit
import AVFoundation
import ApplicationServices

enum TranscriptedPermissionKind: String, CaseIterable, Identifiable {
    case microphone
    case accessibility
    case screenRecording

    var id: String { rawValue }

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
            return "Needed for global shortcuts and reliable paste-back."
        case .screenRecording:
            return "Needed to capture system audio during meetings."
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
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                guard !granted else { return }
                Task { @MainActor in
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        case .accessibility:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        case .screenRecording:
            if #available(macOS 15.0, *) {
                CGRequestScreenCaptureAccess()
            }
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
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
}
