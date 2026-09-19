import AppKit
import AVFoundation
import ApplicationServices
import CoreAudio
import EventKit
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

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
    /// explicit denial so a transient Core Audio/daemon problem cannot
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
        case prepareCapture = "prepare_capture"
        case silentAudio = "silent_audio"
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

    // Preserve existing users' previously verified access across the backend
    // change. This cache is historical evidence, not a live macOS TCC query.
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
    static func requestAccessOrOpenSettings(
        for kind: TranscriptedPermissionKind,
        microphoneStatus: () -> AVAuthorizationStatus = { microphoneAuthorizationStatus() },
        calendarStatus: () -> EKAuthorizationStatus = { EKEventStore.authorizationStatus(for: .event) },
        requestMicrophone: @MainActor () async -> Bool = { await requestMicrophoneAccessIfNeeded() },
        requestCalendar: @MainActor () async -> Bool = { await requestCalendarAccessIfNeeded() },
        activateForPrompt: @MainActor () -> Void = { activateForPermissionPrompt() },
        openSystemSettings: @MainActor (String) -> Void = { TranscriptedPermissionAccess.openSystemSettings($0) }
    ) async -> Bool {
        switch kind {
        case .microphone:
            switch microphoneStatus() {
            case .authorized:
                openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
                return true
            case .notDetermined:
                let granted = await requestMicrophone()
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
            // Review manages an existing grant. A successful first-time Allow
            // should still leave the user in Transcripted.
            let status = calendarStatus()
            if status == .fullAccess || status == .authorized {
                openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
                return true
            }
            activateForPrompt()
            let granted = await requestCalendar()
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
            // Silence cannot distinguish a quiet Mac from revoked access.
            // Keep the existing cached-grant policy without claiming a new
            // verification. Cancellation still revokes this start attempt.
            canProceed: (state == .granted && !result.wasCancelled)
                || result == .indeterminate(.silentAudio),
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
/// Audio services have no completion guarantee for every TCC or daemon state.
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
                if Task.isCancelled {
                    continuation.resume(returning: .indeterminate(.cancelled))
                    return
                }
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
final class SystemAudioPermissionRequester {
    typealias ProbeResult = TranscriptedPermissionAccess.SystemAudioPermissionProbeResult
    typealias ProbeStage = TranscriptedPermissionAccess.SystemAudioPermissionProbeStage

    private let worker: SystemAudioPermissionProbeWorker
    private var completion: ((ProbeResult) -> Void)?

    init(
        prepare: @escaping () throws -> Void,
        start: @escaping (@escaping (SystemAudioPermissionSampleEvidence) -> Void) throws -> Void,
        stop: @escaping () -> Void,
        silenceObservationDelay: TimeInterval = 2
    ) {
        worker = SystemAudioPermissionProbeWorker(prepare: prepare, start: start, stop: stop, silenceObservationDelay: silenceObservationDelay)
    }

    convenience init() {
#if canImport(TranscriptedCore)
        let capture = CoreAudioSystemAudioCapture()
        self.init(
            prepare: { try capture.prepare() },
            start: { receivedSignal in
                try capture.start { buffer in
                    receivedSignal(SystemAudioPermissionProbeClassifier.sampleEvidence(buffer))
                }
            },
            stop: { capture.stopSync() }
        )
#else
        // The dependency-free fast-test runner injects a fake capture above.
        // A missing production backend must never manufacture a grant.
        self.init(prepare: {
            throw NSError(domain: "SystemAudioPermissionProbe", code: 1)
        }, start: { _ in }, stop: {})
#endif
    }

    func requestAccess(completion: @escaping (ProbeResult) -> Void) {
        self.completion = completion

        worker.begin { [weak self] result in
            Task { @MainActor [weak self] in
                self?.finish(result)
            }
        }
    }

    func cancel() {
        completion = nil
        worker.cancel()
    }

    private func finish(_ result: ProbeResult) {
        let completion = completion
        self.completion = nil
        completion?(result)
    }
}

/// Serializes Core Audio setup/teardown away from the main actor. Cancellation
/// is remembered even while prepare is blocked, so its eventual return cannot
/// start a stale recording. Only signal presence is checked; no audio is saved
/// or sent anywhere. Core Audio can return silent frames when access is off.
private final class SystemAudioPermissionProbeWorker: @unchecked Sendable {
    typealias ProbeResult = TranscriptedPermissionAccess.SystemAudioPermissionProbeResult
    private let queue = DispatchQueue(label: "Transcripted.SystemAudioPermission")
    private let lock = NSLock()
    private var cancelled = false
    private var resolved = false
    private let prepare: () throws -> Void
    private let start: (@escaping (SystemAudioPermissionSampleEvidence) -> Void) throws -> Void
    private let stop: () -> Void
    private let silenceObservationDelay: TimeInterval
    private var silenceTimerScheduled = false // queue-owned

    init(prepare: @escaping () throws -> Void,
         start: @escaping (@escaping (SystemAudioPermissionSampleEvidence) -> Void) throws -> Void,
         stop: @escaping () -> Void,
         silenceObservationDelay: TimeInterval) {
        self.prepare = prepare
        self.start = start
        self.stop = stop
        self.silenceObservationDelay = silenceObservationDelay
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func begin(completion: @escaping (ProbeResult) -> Void) {
        queue.async { [self] in
            guard !isCancelled else { return }
            do {
                try prepare()
            } catch {
                resolve(SystemAudioPermissionProbeClassifier.result(for: error, stage: .prepareCapture), completion)
                return
            }
            guard !isCancelled else { return }
            do {
                try start { [weak self] evidence in
                    // The engine delivers owned buffers off its real-time I/O
                    // callback. Silence is inconclusive, never an explicit denial.
                    guard let self else { return }
                    self.queue.async { [self] in
                        guard !self.isCancelled else { return }
                        switch evidence {
                        case .signal:
                            self.resolve(.granted, completion)
                        case .silentFrames:
                            guard !self.silenceTimerScheduled else { return }
                            self.silenceTimerScheduled = true
                            self.queue.asyncAfter(deadline: .now() + self.silenceObservationDelay) { [weak self] in
                                self?.resolve(.indeterminate(.silentAudio), completion)
                            }
                        case .noValidFrames:
                            break
                        }
                    }
                }
            } catch {
                resolve(SystemAudioPermissionProbeClassifier.result(for: error, stage: .startCapture), completion)
            }
        }
    }

    private func resolve(_ result: ProbeResult, _ completion: (ProbeResult) -> Void) {
        lock.lock()
        let shouldResolve = !cancelled && !resolved
        resolved = true
        lock.unlock()
        if shouldResolve { completion(result) }
    }

    func cancel() {
        lock.lock()
        let wasCancelled = cancelled
        cancelled = true
        lock.unlock()
        guard !wasCancelled else { return }
        // Runs after in-flight setup, even if the caller already timed out.
        queue.async { [self] in stop() }
    }
}

enum SystemAudioPermissionSampleEvidence: Sendable {
    case noValidFrames
    case silentFrames
    case signal
}

enum SystemAudioPermissionProbeClassifier {
    typealias ProbeResult = TranscriptedPermissionAccess.SystemAudioPermissionProbeResult
    typealias ProbeStage = TranscriptedPermissionAccess.SystemAudioPermissionProbeStage

    static func containsAudioSignal(_ buffer: AVAudioPCMBuffer) -> Bool {
        if case .signal = sampleEvidence(buffer) { return true }
        return false
    }

    static func sampleEvidence(_ buffer: AVAudioPCMBuffer) -> SystemAudioPermissionSampleEvidence {
        guard buffer.frameLength > 0, buffer.format.commonFormat == .pcmFormatFloat32 else { return .noValidFrames }
        var hasFiniteSample = false
        var hasInvalidSample = false
        for channel in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            guard let data = channel.mData else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            for index in 0..<(Int(channel.mDataByteSize) / MemoryLayout<Float>.size) {
                if samples[index].isFinite {
                    hasFiniteSample = true
                    if samples[index] != 0 { return .signal }
                } else {
                    hasInvalidSample = true
                }
            }
        }
        return hasFiniteSample && !hasInvalidSample ? .silentFrames : .noValidFrames
    }

    static func result(for error: Error, stage: ProbeStage) -> ProbeResult {
        // Core Audio's public errors do not distinguish a TCC denial from
        // other device-access failures. In particular '!hog' is not specific
        // to the user's recording grant. Do not persist these as a revocation.
        return .indeterminate(stage)
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
