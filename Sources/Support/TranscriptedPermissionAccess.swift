import AppKit
import AVFoundation
import ApplicationServices
import CoreMedia
import EventKit
import ScreenCaptureKit

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
            return microphoneAuthorizationStatus() == .authorized
        case .accessibility:
            return AXIsProcessTrusted()
        case .systemAudioRecording:
            return systemAudioRecordingGranted()
        case .calendar:
            return calendarAccessGranted()
        }
    }

    static func microphoneAuthorizationStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    @MainActor
    static func requestMicrophoneAccessIfNeeded(
        statusProvider: () -> AVAuthorizationStatus = { AVCaptureDevice.authorizationStatus(for: .audio) },
        activateForPrompt: @MainActor () -> Void = { activateForPermissionPrompt() },
        requester: @escaping (@escaping @Sendable (Bool) -> Void) -> Void = { completion in
            AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
        }
    ) async -> Bool {
        switch statusProvider() {
        case .authorized:
            return true
        case .notDetermined:
            activateForPrompt()
            return await withCheckedContinuation { continuation in
                requester { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    @MainActor
    static func openSettings(for kind: TranscriptedPermissionKind) {
        Task { @MainActor in
            _ = await requestAccessOrOpenSettings(for: kind)
        }
    }

    @MainActor
    @discardableResult
    static func requestAccessOrOpenSettings(for kind: TranscriptedPermissionKind) async -> Bool {
        switch kind {
        case .microphone:
            switch microphoneAuthorizationStatus() {
            case .authorized:
                return true
            case .notDetermined:
                let granted = await requestMicrophoneAccessIfNeeded()
                notifyPermissionsDidChange(kind: .microphone)
                if !granted {
                    openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
                }
                return granted
            case .denied, .restricted:
                openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
                return false
            @unknown default:
                openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
                return false
            }
        case .accessibility:
            if !AXIsProcessTrusted() {
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            }
            openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            notifyPermissionsDidChange(kind: .accessibility)
            return AXIsProcessTrusted()
        case .systemAudioRecording:
            if systemAudioRecordingStatus() == .granted {
                openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")
                return true
            }

            let granted = await requestSystemAudioRecordingAccessIfNeeded()
            notifyPermissionsDidChange(kind: .systemAudioRecording)
            if !granted {
                openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")
            }
            return granted
        case .calendar:
            activateForPermissionPrompt()
            let granted = await requestCalendarAccessIfNeeded()
            notifyPermissionsDidChange(kind: .calendar)
            if !granted {
                openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
            }
            return granted
        }
    }

    static func requestCalendarAccessIfNeeded(
        statusProvider: () -> EKAuthorizationStatus = { EKEventStore.authorizationStatus(for: .event) },
        requester: () async throws -> Bool = {
            let store = EKEventStore()
            return try await store.requestFullAccessToEvents()
        }
    ) async -> Bool {
        let status = statusProvider()
        switch status {
        case .fullAccess:
            return true
        case .authorized:
            return true
        case .notDetermined:
            do {
                return try await requester()
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
    static func requestSystemAudioRecordingAccessIfNeeded(forceRefresh: Bool = false) async -> Bool {
        if !forceRefresh, systemAudioRecordingStatus() == .granted {
            return true
        }

        activateForPermissionPrompt()
        let granted = await performSystemAudioRecordingAccessRequest()
        setSystemAudioRecordingGranted(granted)
        return granted
    }

    @MainActor
    static func requestSystemAudioRecordingAccessIfNeeded(
        forceRefresh: Bool = false,
        requester: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        if !forceRefresh, systemAudioRecordingStatus() == .granted {
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

    @MainActor
    private static func notifyPermissionsDidChange(kind: TranscriptedPermissionKind) {
        NotificationCenter.default.post(name: .transcriptedPermissionsDidChange, object: kind)
    }
}

extension Notification.Name {
    static let transcriptedPermissionsDidChange = Notification.Name("transcriptedPermissionsDidChange")
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

extension AVAuthorizationStatus {
    /// Stable, privacy-safe string used in analytics and diagnostics context.
    ///
    /// Centralized here so the mic/camera authorization mapping is defined once
    /// instead of being re-switched in every telemetry call site.
    var diagnosticName: String {
        switch self {
        case .notDetermined:
            return "not_determined"
        case .restricted:
            return "restricted"
        case .denied:
            return "denied"
        case .authorized:
            return "authorized"
        @unknown default:
            return "unknown"
        }
    }
}
