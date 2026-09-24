import AppKit
import AVFoundation
import ApplicationServices
import CoreAudio
import Combine
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
        AutomatedLaunchEnvironment.isActive()
    }

    /// macOS's own System Audio Recording decision. Tests swap in a fake so
    /// they never read the host's real TCC record.
    nonisolated(unsafe) static var systemAudioCaptureTCC: SystemAudioCaptureTCC = .live

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

    /// macOS will not show the microphone prompt again; only System Settings can change it.
    static func microphoneAccessBlocked() -> Bool {
        switch microphoneAuthorizationStatus() {
        case .denied, .restricted:
            return true
        case .authorized, .notDetermined:
            return false
        @unknown default:
            return false
        }
    }

    /// macOS will not show the calendar prompt again; only System Settings can change it.
    static func calendarAccessBlocked() -> Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .denied, .restricted, .writeOnly:
            return true
        case .fullAccess, .authorized, .notDetermined:
            return false
        @unknown default:
            return false
        }
    }

    private static let accessibilityPromptShownKey = "accessibilityPermissionPromptShown"

    static func hasShownAccessibilityPrompt(userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.bool(forKey: accessibilityPromptShownKey)
    }

    static func showAccessibilityPrompt(userDefaults: UserDefaults = .standard) {
        userDefaults.set(true, forKey: accessibilityPromptShownKey)
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
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

    /// Opens the narrow permission pane without starting a capture probe.
    @MainActor
    static func openSystemAudioRecordingSettings() {
        openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")
    }

    @MainActor
    @discardableResult
    static func requestAccessOrOpenSettings(
        for kind: TranscriptedPermissionKind,
        /// Onboarding only: the first Accessibility Grant shows just the macOS
        /// prompt. Settings rows always open the pane, because a user who lost
        /// trust after an update may get no prompt at all.
        firstAccessibilityAskShowsPromptOnly: Bool = false,
        microphoneStatus: () -> AVAuthorizationStatus = { microphoneAuthorizationStatus() },
        calendarStatus: () -> EKAuthorizationStatus = { EKEventStore.authorizationStatus(for: .event) },
        requestMicrophone: @MainActor () async -> Bool = { await requestMicrophoneAccessIfNeeded() },
        requestCalendar: @MainActor () async -> Bool = { await requestCalendarAccessIfNeeded() },
        activateForPrompt: @MainActor () -> Void = { activateForPermissionPrompt() },
        isAccessibilityTrusted: () -> Bool = { AXIsProcessTrusted() },
        hasShownAccessibilityPrompt: () -> Bool = { TranscriptedPermissionAccess.hasShownAccessibilityPrompt() },
        promptForAccessibility: () -> Void = { TranscriptedPermissionAccess.showAccessibilityPrompt() },
        openSystemSettings: @MainActor (String) -> Void = { TranscriptedPermissionAccess.openSystemSettings($0) }
    ) async -> Bool {
        switch kind {
        case .microphone:
            switch microphoneStatus() {
            case .authorized:
                openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
                return true
            case .notDetermined:
                // A fresh Don't Allow stays in Transcripted: the row flips to
                // "Open Settings" and says macOS won't ask again. Opening
                // Settings on top of the answer they just gave felt like a trap.
                let granted = await requestMicrophone()
                notifyPermissionsDidChange(kind: .microphone)
                return granted
            case .denied, .restricted:
                openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
                return false
            @unknown default:
                openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
                return false
            }
        case .accessibility:
            // In onboarding, the first Grant shows only the macOS prompt, which
            // has its own Open System Settings button. Opening Settings as well
            // stacked two windows on top of each other. Every other click
            // keeps the old behavior: prompt if untrusted, and open the pane.
            let trusted = isAccessibilityTrusted()
            let firstAsk = firstAccessibilityAskShowsPromptOnly && !trusted && !hasShownAccessibilityPrompt()
            if !trusted {
                promptForAccessibility()
            }
            if !firstAsk {
                openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            }
            notifyPermissionsDidChange(kind: .accessibility)
            return isAccessibilityTrusted()
        case .systemAudioRecording:
            let wasGranted = systemAudioRecordingGranted()
            let granted = await requestSystemAudioRecordingAccessIfNeeded(forceRefresh: true)
            notifyPermissionsDidChange(kind: .systemAudioRecording)
            // Review manages an existing grant. A fresh Allow in the macOS
            // box should leave the user in Transcripted.
            if granted && !wasGranted {
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
            let wasUndetermined = status == .notDetermined
            activateForPrompt()
            let granted = await requestCalendar()
            notifyPermissionsDidChange(kind: .calendar)
            // Blocked access has no prompt, so Settings is the only way on.
            // A fresh Don't Allow stays in the app, like the microphone.
            if !granted && !wasUndetermined {
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

    /// Reads macOS's recorded System Audio Recording decision and folds it
    /// into the cached state. The tap probe can never observe a denial (a
    /// denied tap delivers the same silence as a quiet Mac), so without this
    /// a cached grant outlives Don't Allow or a reset in System Settings.
    /// Cheap and prompt-free: safe on window activation and at meeting start.
    @discardableResult
    static func refreshSystemAudioRecordingStatusFromSystem(
        tcc: SystemAudioCaptureTCC = systemAudioCaptureTCC
    ) -> SystemAudioCaptureTCCStatus {
        if isLaunchSmokeMode { return .unavailable }
        let status = tcc.preflight()
        switch status {
        case .authorized:
            setSystemAudioRecordingGranted(true)
        case .denied:
            setSystemAudioRecordingGranted(false)
        case .notDetermined:
            // Reset in System Settings (or never asked). Nothing is known.
            UserDefaults.standard.removeObject(forKey: systemAudioRecordingKnownKey)
            UserDefaults.standard.removeObject(forKey: systemAudioRecordingGrantedKey)
        case .unavailable:
            break
        }
        return status
    }

    /// Shows the macOS "record your system audio" box when the decision is
    /// still open, and records the answer. Returns nil only when macOS's
    /// request API is unavailable.
    @MainActor
    static func requestSystemAudioCaptureAccess(
        tcc: SystemAudioCaptureTCC = systemAudioCaptureTCC,
        activateForPrompt: @MainActor () -> Void = { activateForPermissionPrompt() }
    ) async -> Bool? {
        activateForPrompt()
        // Bounded like the tap probe so a request that never answers cannot
        // hang meeting start. No answer reads as unavailable.
        let attempt = SystemAudioPermissionRequestAttempt()
        let result = await attempt.awaitResult(
            start: { completion in
                Task {
                    switch await tcc.request() {
                    case .some(true): completion(.granted)
                    case .some(false): completion(.explicitlyDenied)
                    case .none: completion(.indeterminate(.startCapture))
                    }
                }
            },
            cleanup: {}
        )
        let granted: Bool
        switch result {
        case .granted: granted = true
        case .explicitlyDenied: granted = false
        case .indeterminate: return nil
        }
        setSystemAudioRecordingGranted(granted)
        notifyPermissionsDidChange(kind: .systemAudioRecording)
        return granted
    }

    @MainActor
    static func requestSystemAudioRecordingAccessIfNeeded(forceRefresh: Bool = false) async -> Bool {
        await systemAudioRecordingAccessDecision(forceRefresh: forceRefresh).canProceed
    }

    @MainActor
    static func systemAudioRecordingAccessDecision(
        forceRefresh: Bool = false
    ) async -> SystemAudioPermissionAccessDecision {
        switch refreshSystemAudioRecordingStatusFromSystem() {
        case .authorized:
            return applySystemAudioRecordingProbeResult(.granted)
        case .denied:
            return applySystemAudioRecordingProbeResult(.explicitlyDenied)
        case .notDetermined:
            // The real macOS box answers directly, however long the user
            // takes, instead of a tap probe racing a timeout.
            if let granted = await requestSystemAudioCaptureAccess() {
                return applySystemAudioRecordingProbeResult(granted ? .granted : .explicitlyDenied)
            }
        case .unavailable:
            break
        }

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

        let cachedBefore = systemAudioRecordingStatus()
        switch refreshSystemAudioRecordingStatusFromSystem() {
        case .authorized, .denied, .notDetermined:
            if systemAudioRecordingStatus() != cachedBefore {
                notifyPermissionsDidChange(kind: .systemAudioRecording)
            }
            return systemAudioRecordingGranted()
        case .unavailable:
            break
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
    static func systemAudioProbeTimeout(for state: SystemAudioPermissionState) -> UInt64 {
        // A cached grant is historical, not new consent. Bound its health
        // recheck independently of the first-install dialog budget.
        state == .granted ? 3_000_000_000 : TranscriptedConstants.systemAudioPermissionRequestTimeout
    }

    @MainActor
    private static func performSystemAudioRecordingAccessRequest() async -> SystemAudioPermissionProbeResult {
        let requester = SystemAudioPermissionRequester()
        let attempt = SystemAudioPermissionRequestAttempt(
            timeoutNanoseconds: systemAudioProbeTimeout(for: systemAudioRecordingStatus())
        )

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

enum SystemAudioCaptureTCCStatus: String, Equatable, Sendable {
    case authorized
    case denied
    case notDetermined = "not_determined"
    /// macOS's permission API could not be loaded. Callers fall back to the
    /// tap probe and the in-recording signal check.
    case unavailable
}

/// Direct access to macOS's System Audio Recording decision
/// (`kTCCServiceAudioCapture`). Core Audio process taps have no public
/// permission query, so this uses TCC.framework's `TCCAccessPreflight` and
/// `TCCAccessRequest`. They are private symbols, loaded lazily; a missing
/// symbol reads as `.unavailable` so an OS change degrades to the old probe
/// instead of crashing or inventing an answer.
struct SystemAudioCaptureTCC: Sendable {
    let preflight: @Sendable () -> SystemAudioCaptureTCCStatus
    /// Shows the macOS allow box when the decision is open; returns the
    /// current answer without a box once it is decided. Nil = unavailable.
    let request: @Sendable () async -> Bool?

    static let live = SystemAudioCaptureTCC(
        preflight: { SystemAudioCaptureTCCSymbols.preflightStatus() },
        request: { await SystemAudioCaptureTCCSymbols.requestAccess() }
    )

    static let unavailable = SystemAudioCaptureTCC(preflight: { .unavailable }, request: { nil })
}

private enum SystemAudioCaptureTCCSymbols {
    typealias PreflightFunction = @convention(c) (CFString, CFDictionary?) -> Int32
    typealias RequestFunction = @convention(c) (
        CFString,
        CFDictionary?,
        @escaping @convention(block) (Bool) -> Void
    ) -> Void

    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let symbols: (preflight: PreflightFunction?, request: RequestFunction?) = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW) else {
            return (nil, nil)
        }
        let preflight = dlsym(handle, "TCCAccessPreflight").map { unsafeBitCast($0, to: PreflightFunction.self) }
        let request = dlsym(handle, "TCCAccessRequest").map { unsafeBitCast($0, to: RequestFunction.self) }
        return (preflight, request)
    }()

    static func preflightStatus() -> SystemAudioCaptureTCCStatus {
        guard let preflight = symbols.preflight else { return .unavailable }
        switch preflight(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        case 2: return .notDetermined
        default: return .unavailable
        }
    }

    static func requestAccess() async -> Bool? {
        guard let request = symbols.request else { return nil }
        return await withCheckedContinuation { continuation in
            // Private API: never trust it to call back exactly once.
            let resumed = NSLock()
            var didResume = false
            request(service, nil) { granted in
                resumed.lock()
                let shouldResume = !didResume
                didResume = true
                resumed.unlock()
                if shouldResume { continuation.resume(returning: granted) }
            }
        }
    }
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
        timeoutNanoseconds: UInt64 = TranscriptedConstants.systemAudioPermissionRequestTimeout,
        scheduleTimeout: TimeoutScheduler? = nil,
        onTimeout: @escaping () -> Void = {},
        onResolved: @escaping (ProbeResult) -> Void = { _ in }
    ) {
        self.scheduleTimeout = scheduleTimeout ?? { action in
            Self.liveTimeoutScheduler(action, timeoutNanoseconds: timeoutNanoseconds)
        }
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
        _ action: @escaping @MainActor () -> Void,
        timeoutNanoseconds: UInt64
    ) -> @MainActor () -> Void {
        let task = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
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
    private var backendErrorSubscription: AnyCancellable?

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
        backendErrorSubscription = capture.errorMessagePublisher.sink { [weak self] message in
            Task { @MainActor [weak self] in self?.handleBackendError(message) }
        }
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
        backendErrorSubscription = nil
        worker.cancel()
    }

    func handleBackendError(_ message: String?) {
        // Match the backend's terminal-failure vocabulary, not its temporary
        // reconnecting notice. An audio-service failure is never TCC denial.
        guard message?.hasPrefix("System audio failed") == true else { return }
        finish(.indeterminate(.startCapture))
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
