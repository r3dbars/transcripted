import AppKit
import AVFoundation
import ApplicationServices
import CoreMedia
import EventKit
import ScreenCaptureKit

enum TranscriptedPermissionAccess {
    enum SystemAudioPermissionState: Equatable, Sendable {
        case granted
        case denied
        case unknown

        var isGranted: Bool {
            self == .granted
        }
    }

    /// A permission probe can fail for reasons that say nothing about the
    /// user's TCC choice. Keep those transport failures distinct from an
    /// explicit denial so a transient ScreenCaptureKit/daemon problem cannot
    /// overwrite a previously verified grant and manufacture a permission
    /// popup at meeting start.
    enum SystemAudioPermissionProbeStage: String, CaseIterable, Sendable {
        case timedOut = "timed_out"
        case cancelled
        case shareableContent = "shareable_content"
        case displayUnavailable = "display_unavailable"
        case addStreamOutput = "add_stream_output"
        case startCapture = "start_capture"
        case stopCapture = "stop_capture"
    }

    enum SystemAudioPermissionProbeResult: Equatable, Sendable {
        case granted
        case explicitlyDenied
        case indeterminate(SystemAudioPermissionProbeStage)

        var diagnosticName: String {
            switch self {
            case .granted:
                return "granted"
            case .explicitlyDenied:
                return "explicitly_denied"
            case .indeterminate(let stage):
                return "indeterminate_\(stage.rawValue)"
            }
        }

        var isIndeterminate: Bool {
            if case .indeterminate = self { return true }
            return false
        }

        var wasCancelled: Bool {
            self == .indeterminate(.cancelled)
        }
    }

    struct SystemAudioPermissionAccessDecision: Equatable, Sendable {
        let canProceed: Bool
        let state: SystemAudioPermissionState
        /// Nil means a cached verified grant satisfied the request without a
        /// live probe. Non-nil records the privacy-safe terminal probe class.
        let probeResult: SystemAudioPermissionProbeResult?
    }

    private static let systemAudioRecordingGrantedKey = "systemAudioRecordingPermissionGranted"
    private static let systemAudioRecordingKnownKey = "systemAudioRecordingPermissionKnown"
    @MainActor private static var activeSystemAudioRevalidator: Task<Bool, Never>?
    private static var isLaunchSmokeMode: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["TRANSCRIPTED_LAUNCH_UI_SMOKE_REPORT"] != nil
            || environment["TRANSCRIPTED_FIRST_RUN_RELIABILITY_REPORT"] != nil
    }

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
            let granted = await requestSystemAudioRecordingAccessIfNeeded(forceRefresh: true)
            notifyPermissionsDidChange(kind: .systemAudioRecording)
            if granted {
                openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")
                return true
            }

            openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")
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
        await systemAudioRecordingAccessDecision(forceRefresh: forceRefresh).canProceed
    }

    @MainActor
    static func systemAudioRecordingAccessDecision(
        forceRefresh: Bool = false
    ) async -> SystemAudioPermissionAccessDecision {
        if !forceRefresh, systemAudioRecordingStatus() == .granted {
            return SystemAudioPermissionAccessDecision(
                canProceed: true,
                state: .granted,
                probeResult: nil
            )
        }

        activateForPermissionPrompt()
        let result = await performSystemAudioRecordingAccessRequest()
        return applySystemAudioRecordingProbeResult(result)
    }

    @MainActor
    static func revalidateSystemAudioRecordingStatus() async -> Bool {
        if isLaunchSmokeMode {
            return systemAudioRecordingGranted()
        }
        if let activeSystemAudioRevalidator {
            return await activeSystemAudioRevalidator.value
        }

        let task = Task { @MainActor in
            let result = await performSystemAudioRecordingAccessRequest()
            let granted = applySystemAudioRecordingProbeResult(result).canProceed
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
        requester: @escaping @MainActor () async -> Bool,
        skipSmokeRevalidation: Bool = isLaunchSmokeMode
    ) async -> Bool {
        if skipSmokeRevalidation {
            return systemAudioRecordingGranted()
        }
        let granted = await requester()
        _ = applySystemAudioRecordingProbeResult(granted ? .granted : .explicitlyDenied)
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
        _ = applySystemAudioRecordingProbeResult(granted ? .granted : .explicitlyDenied)
        return granted
    }

    /// Typed test/integration seam for exercising transport failures without
    /// turning them into a synthetic denial. Production callers use the
    /// no-requester overload above.
    @MainActor
    static func systemAudioRecordingAccessDecision(
        forceRefresh: Bool = false,
        probeRequester: @escaping @MainActor () async -> SystemAudioPermissionProbeResult
    ) async -> SystemAudioPermissionAccessDecision {
        if !forceRefresh, systemAudioRecordingStatus() == .granted {
            return SystemAudioPermissionAccessDecision(
                canProceed: true,
                state: .granted,
                probeResult: nil
            )
        }

        return applySystemAudioRecordingProbeResult(await probeRequester())
    }

    @MainActor
    private static func performSystemAudioRecordingAccessRequest() async -> SystemAudioPermissionProbeResult {
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
    private static func applySystemAudioRecordingProbeResult(
        _ result: SystemAudioPermissionProbeResult
    ) -> SystemAudioPermissionAccessDecision {
        switch result {
        case .granted:
            setSystemAudioRecordingGranted(true)
        case .explicitlyDenied:
            setSystemAudioRecordingGranted(false)
        case .indeterminate:
            // Preserve the existing state. A probe timeout, daemon failure,
            // missing display, or stream setup/teardown error is not evidence
            // that the user revoked access.
            break
        }

        let state = systemAudioRecordingStatus()
        return SystemAudioPermissionAccessDecision(
            // Cancellation says nothing about the persisted TCC choice, but it
            // does revoke this caller's authority to continue into capture.
            // Preserve a cached grant while still stopping this start attempt.
            canProceed: state == .granted && !result.wasCancelled,
            state: state,
            probeResult: result
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
    typealias ProbeResult = TranscriptedPermissionAccess.SystemAudioPermissionProbeResult
    typealias Completion = (ProbeResult) -> Void
    typealias TimeoutScheduler = @MainActor (@escaping @MainActor () -> Void) -> @MainActor () -> Void

    private let scheduleTimeout: TimeoutScheduler
    private let onTimeout: () -> Void
    private let onResolved: (ProbeResult) -> Void
    private var continuation: CheckedContinuation<ProbeResult, Never>?
    private var cancelTimeout: (() -> Void)?
    private var cleanup: (() -> Void)?
    private var result: ProbeResult?

    init(
        scheduleTimeout: @escaping TimeoutScheduler = SystemAudioPermissionRequestAttempt.liveTimeoutScheduler,
        onTimeout: @escaping () -> Void = {},
        onResolved: @escaping (ProbeResult) -> Void = { _ in }
    ) {
        self.scheduleTimeout = scheduleTimeout
        self.onTimeout = onTimeout
        self.onResolved = onResolved
    }

    func awaitResult(
        start: @escaping (@escaping Completion) -> Void,
        cleanup: @escaping () -> Void
    ) async -> ProbeResult {
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
                self?.finish(.indeterminate(.cancelled))
            }
        })
    }

    private func timeout() {
        guard result == nil else { return }
        onTimeout()
        finish(.indeterminate(.timedOut))
    }

    private func finish(_ result: ProbeResult) {
        guard self.result == nil else { return }
        self.result = result

        let continuation = continuation
        self.continuation = nil
        let cancelTimeout = cancelTimeout
        self.cancelTimeout = nil
        let cleanup = cleanup
        self.cleanup = nil

        cancelTimeout?()
        cleanup?()
        onResolved(result)
        continuation?.resume(returning: result)
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
    typealias ProbeResult = TranscriptedPermissionAccess.SystemAudioPermissionProbeResult
    typealias ProbeStage = TranscriptedPermissionAccess.SystemAudioPermissionProbeStage

    private var stream: SCStream?
    private let sampleHandlerQueue = DispatchQueue(label: "Transcripted.SystemAudioPermission")
    private var completion: ((ProbeResult) -> Void)?
    private var stopCaptureRequested = false

    func requestAccess(completion: @escaping (ProbeResult) -> Void) {
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

        if let error {
            finish(SystemAudioPermissionProbeClassifier.result(for: error, stage: .shareableContent))
            return
        }

        guard let display = content?.displays.first else {
            finish(.indeterminate(.displayUnavailable))
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
            finish(SystemAudioPermissionProbeClassifier.result(for: error, stage: .addStreamOutput))
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

        if let error {
            finish(SystemAudioPermissionProbeClassifier.result(for: error, stage: .startCapture))
            return
        }

        // Once startCapture succeeds, ScreenCaptureKit has already proved the
        // TCC grant. A teardown/daemon error is cleanup noise, not evidence that
        // access was denied, so resolve granted before the best-effort stop.
        stopCaptureRequested = true
        finish(SystemAudioPermissionProbeClassifier.resultAfterSuccessfulStart())
        stream.stopCapture { _ in }
    }

    private func finish(_ result: ProbeResult) {
        let completion = completion
        self.completion = nil
        completion?(result)
    }
}

enum SystemAudioPermissionProbeClassifier {
    typealias ProbeResult = TranscriptedPermissionAccess.SystemAudioPermissionProbeResult
    typealias ProbeStage = TranscriptedPermissionAccess.SystemAudioPermissionProbeStage

    static func result(for error: Error, stage: ProbeStage) -> ProbeResult {
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain,
           nsError.code == SCStreamError.Code.userDeclined.rawValue {
            return .explicitlyDenied
        }
        return .indeterminate(stage)
    }

    /// `startCapture` success is the permission proof. Teardown happens after
    /// that proof and cannot turn it back into a denial or unknown state.
    static func resultAfterSuccessfulStart() -> ProbeResult {
        .granted
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
