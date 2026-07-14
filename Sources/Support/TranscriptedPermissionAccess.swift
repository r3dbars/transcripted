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
    @MainActor private static var activeSystemAudioRevalidator: Task<Bool, Never>?

    static func isGranted(_ kind: TranscriptedPermissionKind) -> Bool {
        switch kind {
        case .microphone:
            return microphoneAuthorizationStatus() == .authorized
        case .accessibility:
            return AXIsProcessTrusted()
        case .systemAudioRecording:
            return systemAudioRecordingGranted()
        case .screenRecording:
            return screenRecordingGranted()
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
            let granted = await requestSystemAudioRecordingAccessIfNeeded(forceRefresh: true)
            notifyPermissionsDidChange(kind: .systemAudioRecording)
            if granted {
                openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")
                return true
            }

            openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")
            return granted
        case .screenRecording:
            if screenRecordingGranted() {
                openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
                return true
            }

            let granted = await requestScreenRecordingAccessIfNeeded()
            notifyPermissionsDidChange(kind: .screenRecording)
            if !granted {
                openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
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

    static func screenRecordingGranted(
        preflight: () -> Bool = { CGPreflightScreenCaptureAccess() }
    ) -> Bool {
        preflight()
    }

    @MainActor
    static func requestScreenRecordingAccessIfNeeded(
        preflight: () -> Bool = { CGPreflightScreenCaptureAccess() },
        activateForPrompt: @MainActor () -> Void = { activateForPermissionPrompt() },
        requester: () -> Bool = { CGRequestScreenCaptureAccess() }
    ) async -> Bool {
        if preflight() {
            return true
        }

        activateForPrompt()
        return requester()
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
    static func revalidateSystemAudioRecordingStatus() async -> Bool {
        if let activeSystemAudioRevalidator {
            return await activeSystemAudioRevalidator.value
        }

        let task = Task { @MainActor in
            let granted = await performSystemAudioRecordingAccessRequest()
            setSystemAudioRecordingGranted(granted)
            notifyPermissionsDidChange(kind: .systemAudioRecording)
            return granted
        }
        activeSystemAudioRevalidator = task
        let granted = await task.value
        activeSystemAudioRevalidator = nil
        return granted
    }

    @MainActor
    static func revalidateSystemAudioRecordingStatus(
        requester: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        let granted = await requester()
        setSystemAudioRecordingGranted(granted)
        notifyPermissionsDidChange(kind: .systemAudioRecording)
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
        let requester = SystemAudioPermissionRequester()
        let attempt = SystemAudioPermissionRequestAttempt()

        return await attempt.awaitResult(
            start: { completion in
                requester.requestAccess(completion: completion)
            },
            cleanup: {
                requester.cancel()
            }
        )
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

/// Bounds one callback-driven System Audio Recording permission request.
///
/// ScreenCaptureKit has no completion guarantee for every TCC or daemon state.
/// This main-actor gate makes timeout, caller cancellation, and real callbacks
/// race through one terminal result so a late callback cannot resume a checked
/// continuation twice or revive a finished request.
@MainActor
final class SystemAudioPermissionRequestAttempt {
    typealias Completion = (Bool) -> Void
    typealias TimeoutScheduler = @MainActor (@escaping @MainActor () -> Void) -> @MainActor () -> Void

    private let scheduleTimeout: TimeoutScheduler
    private let onTimeout: () -> Void
    private let onResolved: (Bool) -> Void
    private var continuation: CheckedContinuation<Bool, Never>?
    private var cancelTimeout: (() -> Void)?
    private var cleanup: (() -> Void)?
    private var result: Bool?

    init(
        scheduleTimeout: @escaping TimeoutScheduler = SystemAudioPermissionRequestAttempt.liveTimeoutScheduler,
        onTimeout: @escaping () -> Void = {},
        onResolved: @escaping (Bool) -> Void = { _ in }
    ) {
        self.scheduleTimeout = scheduleTimeout
        self.onTimeout = onTimeout
        self.onResolved = onResolved
    }

    func awaitResult(
        start: @escaping (@escaping Completion) -> Void,
        cleanup: @escaping () -> Void
    ) async -> Bool {
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                if let result {
                    continuation.resume(returning: result)
                    return
                }

                self.continuation = continuation
                self.cleanup = cleanup
                self.cancelTimeout = scheduleTimeout { [weak self] in
                    self?.timeout()
                }
                start { [weak self] granted in
                    Task { @MainActor [weak self] in
                        self?.finish(granted)
                    }
                }
            }
        }, onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                self?.finish(false)
            }
        })
    }

    private func timeout() {
        guard result == nil else { return }
        onTimeout()
        finish(false)
    }

    private func finish(_ granted: Bool) {
        guard result == nil else { return }
        result = granted

        let continuation = continuation
        self.continuation = nil
        let cancelTimeout = cancelTimeout
        self.cancelTimeout = nil
        let cleanup = cleanup
        self.cleanup = nil

        cancelTimeout?()
        cleanup?()
        onResolved(granted)
        continuation?.resume(returning: granted)
    }

    private static func liveTimeoutScheduler(
        _ action: @escaping @MainActor () -> Void
    ) -> @MainActor () -> Void {
        let task = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: TranscriptedConstants.systemAudioPermissionRequestTimeout)
            } catch {
                return
            }
            action()
        }
        return {
            task.cancel()
        }
    }
}

@available(macOS 26.0, *)
@MainActor
private final class SystemAudioPermissionRequester: NSObject, SCStreamOutput {
    private var stream: SCStream?
    private let sampleHandlerQueue = DispatchQueue(label: "Transcripted.SystemAudioPermission")
    private var completion: ((Bool) -> Void)?
    private var stopCaptureRequested = false

    func requestAccess(completion: @escaping (Bool) -> Void) {
        self.completion = completion

        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [weak self] content, error in
            Task { @MainActor [weak self] in
                self?.handleShareableContent(content, error: error)
            }
        }
    }

    func cancel() {
        completion = nil
        guard let stream else { return }

        self.stream = nil
        guard !stopCaptureRequested else { return }
        stopCaptureRequested = true
        stream.stopCapture { _ in }
    }

    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {}

    private func handleShareableContent(_ content: SCShareableContent?, error: Error?) {
        guard completion != nil else { return }

        if error != nil {
            finish(granted: false)
            return
        }

        guard let display = content?.displays.first else {
            finish(granted: false)
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
        stopCaptureRequested = false

        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleHandlerQueue)
        } catch {
            finish(granted: false)
            return
        }

        stream.startCapture { [weak self] error in
            Task { @MainActor [weak self] in
                self?.handleStartCapture(error: error)
            }
        }
    }

    private func handleStartCapture(error: Error?) {
        guard let stream, completion != nil else { return }

        if error != nil {
            finish(granted: false)
            return
        }

        stopCaptureRequested = true
        stream.stopCapture { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, self.stream != nil, self.completion != nil else { return }
                self.finish(granted: error == nil)
            }
        }
    }

    private func finish(granted: Bool) {
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
