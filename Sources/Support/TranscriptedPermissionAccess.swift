import AppKit
import AVFoundation
import ApplicationServices
import CoreMedia
import EventKit
import ScreenCaptureKit

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
            return "Needed for dictation and your side of meetings."
        case .accessibility:
            return "Needed for global shortcuts and pasting text back into the app you were using."
        case .systemAudioRecording:
            return MeetingRecordingStartGate.systemAudioRecordingSummary
        case .calendar:
            return "Optional for meeting prompts. Lets Transcripted notice upcoming meetings from Apple Calendar, Google, or Exchange calendars synced to your Mac."
        }
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

enum TranscriptedPermissionAccess {
    enum SystemAudioPermissionState {
        case granted
        case denied
        case unknown

        var isGranted: Bool {
            self == .granted
        }
    }

    private static let systemAudioRecordingGrantedKey = "systemAudioRecordingPermissionGranted"
    private static let systemAudioRecordingKnownKey = "systemAudioRecordingPermissionKnown"
    @MainActor private static var activeSystemAudioRequester: SystemAudioPermissionRequester?

    static func isGranted(_ kind: TranscriptedPermissionKind) -> Bool {
        switch kind {
        case .microphone:
            return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .accessibility:
            return AXIsProcessTrusted()
        case .systemAudioRecording:
            return systemAudioRecordingGranted()
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
        case .systemAudioRecording:
            if systemAudioRecordingStatus() == .granted {
                openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")
                return
            }

            Task { @MainActor in
                let granted = await requestSystemAudioRecordingAccessIfNeeded()
                guard !granted else { return }
                openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")
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

    static func systemAudioRecordingStatus() -> SystemAudioPermissionState {
        let defaults = UserDefaults.standard
        let known = defaults.bool(forKey: systemAudioRecordingKnownKey)

        if defaults.object(forKey: systemAudioRecordingGrantedKey) as? Bool == true {
            return .granted
        }

        return known ? .denied : .unknown
    }

    static func systemAudioRecordingGranted() -> Bool {
        systemAudioRecordingStatus().isGranted
    }

    private static func setSystemAudioRecordingGranted(_ granted: Bool) {
        UserDefaults.standard.set(true, forKey: systemAudioRecordingKnownKey)
        UserDefaults.standard.set(granted, forKey: systemAudioRecordingGrantedKey)
    }

    @MainActor
    static func requestSystemAudioRecordingAccessIfNeeded() async -> Bool {
        if systemAudioRecordingStatus() == .granted {
            return true
        }

        activateForPermissionPrompt()
        let granted = await performSystemAudioRecordingAccessRequest()
        setSystemAudioRecordingGranted(granted)
        return granted
    }

    @MainActor
    static func requestSystemAudioRecordingAccessIfNeeded(
        requester: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        if systemAudioRecordingStatus() == .granted {
            return true
        }

        let granted = await requester()
        setSystemAudioRecordingGranted(granted)
        return granted
    }

    @MainActor
    private static func performSystemAudioRecordingAccessRequest() async -> Bool {
        return await withCheckedContinuation { continuation in
            let requester = SystemAudioPermissionRequester()
            activeSystemAudioRequester = requester
            requester.requestAccess { granted in
                Task { @MainActor in
                    activeSystemAudioRequester = nil
                    continuation.resume(returning: granted)
                }
            }
        }
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

@available(macOS 26.0, *)
private final class SystemAudioPermissionRequester: NSObject, SCStreamOutput {
    private var stream: SCStream?
    private let sampleHandlerQueue = DispatchQueue(label: "Transcripted.SystemAudioPermission")
    private var completion: ((Bool) -> Void)?

    func requestAccess(completion: @escaping (Bool) -> Void) {
        self.completion = completion

        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [weak self] content, error in
            guard let self else { return }

            if error != nil {
                self.finish(granted: false)
                return
            }

            guard let display = content?.displays.first else {
                self.finish(granted: false)
                return
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 48000
            config.channelCount = 2
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            self.stream = stream

            do {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.sampleHandlerQueue)
            } catch {
                self.finish(granted: false)
                return
            }

            stream.startCapture { [weak self] error in
                guard let self else { return }

                if error != nil {
                    self.finish(granted: false)
                    return
                }

                stream.stopCapture { [weak self] _ in
                    self?.finish(granted: true)
                }
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {}

    private func finish(granted: Bool) {
        stream = nil
        let completion = completion
        self.completion = nil
        completion?(granted)
    }
}
