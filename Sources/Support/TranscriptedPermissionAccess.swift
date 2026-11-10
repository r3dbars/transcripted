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
        case startCapture = "start_capture"
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

    /// Effects shared by the real decision path and explicitly injected fixtures.
    /// Constructing these values does not read preferences or request permission.
    struct SystemAudioPermissionCache: Sendable {
        let read: @Sendable () -> SystemAudioPermissionState
        let recordGrant: @Sendable (Bool) -> Void
        let clear: @Sendable () -> Void

        static var live: Self {
            Self(read: {
                let defaults = UserDefaults.standard
                if defaults.object(forKey: systemAudioRecordingGrantedKey) as? Bool == true { return .granted }
                return defaults.bool(forKey: systemAudioRecordingKnownKey) ? .denied : .unknown
            }, recordGrant: { granted in
                setSystemAudioRecordingGranted(granted)
            }, clear: {
                UserDefaults.standard.removeObjectIfPresent(forKey: systemAudioRecordingKnownKey)
                UserDefaults.standard.removeObjectIfPresent(forKey: systemAudioRecordingGrantedKey)
            })
        }
    }

    @MainActor
    struct SystemAudioPermissionDependencies {
        let cache: SystemAudioPermissionCache
        let tcc: SystemAudioCaptureTCC
        let isSmokeMode: @Sendable () -> Bool
        let probe: @MainActor (SystemAudioPermissionState) async -> SystemAudioPermissionProbeResult
        let activateForPrompt: @MainActor () -> Void
        let notifyChanged: @MainActor () -> Void

        static var live: Self {
            Self(cache: .live, tcc: systemAudioCaptureTCC, isSmokeMode: { isLaunchSmokeMode },
                 probe: { await performSystemAudioRecordingAccessRequest(cachedState: $0) },
                 activateForPrompt: { activateForPermissionPrompt() },
                 notifyChanged: { notifyPermissionsDidChange(kind: .systemAudioRecording) })
        }
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
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary // literal value of kAXTrustedCheckOptionPrompt
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

    static func systemAudioRecordingStatus(
        cache: SystemAudioPermissionCache = .live
    ) -> SystemAudioPermissionState {
        cache.read()
    }

    static func systemAudioRecordingGranted(cache: SystemAudioPermissionCache = .live) -> Bool {
        systemAudioRecordingStatus(cache: cache).isGranted
    }

    private static func setSystemAudioRecordingGranted(_ granted: Bool) {
        UserDefaults.standard.setIfChanged(true, forKey: systemAudioRecordingKnownKey)
        UserDefaults.standard.setIfChanged(granted, forKey: systemAudioRecordingGrantedKey)
    }

    /// Reads macOS's recorded System Audio Recording decision and folds it
    /// into the cached state. The tap probe can never observe a denial (a
    /// denied tap delivers the same silence as a quiet Mac), so without this
    /// a cached grant outlives Don't Allow or a reset in System Settings.
    /// Cheap and prompt-free: safe on window activation and at meeting start.
    @discardableResult
    static func refreshSystemAudioRecordingStatusFromSystem(
        tcc: SystemAudioCaptureTCC = systemAudioCaptureTCC,
        cache: SystemAudioPermissionCache = .live,
        isSmokeMode: @Sendable () -> Bool = { isLaunchSmokeMode }
    ) -> SystemAudioCaptureTCCStatus {
        if isSmokeMode() { return .unavailable }
        let status = tcc.preflight()
        switch status {
        case .authorized:
            cache.recordGrant(true)
        case .denied:
            cache.recordGrant(false)
        case .notDetermined:
            // Reset in System Settings (or never asked). Nothing is known.
            cache.clear()
        case .unavailable:
            break
        }
        return status
    }

    /// Live TCC preflight without writing the saved grant. Auto-record peeks
    /// at meeting-prompt time so a denied or reset answer cannot rewrite
    /// Settings while the island is deciding whether to start.
    static func peekSystemAudioRecordingStatusFromSystem(
        tcc: SystemAudioCaptureTCC = systemAudioCaptureTCC
    ) -> SystemAudioCaptureTCCStatus {
        if isLaunchSmokeMode { return .unavailable }
        return tcc.preflight()
    }

    /// Shows the macOS "record your system audio" box when the decision is
    /// still open, and records the answer. Returns nil only when macOS's
    /// request API is unavailable.
    @MainActor
    static func requestSystemAudioCaptureAccess(
        tcc: SystemAudioCaptureTCC = systemAudioCaptureTCC,
        activateForPrompt: @MainActor () -> Void = { activateForPermissionPrompt() },
        cache: SystemAudioPermissionCache = .live,
        notifyChanged: @MainActor () -> Void = {
            notifyPermissionsDidChange(kind: .systemAudioRecording)
        }
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
        cache.recordGrant(granted)
        notifyChanged()
        return granted
    }

    @MainActor
    static func requestSystemAudioRecordingAccessIfNeeded(
        forceRefresh: Bool = false,
        dependencies: SystemAudioPermissionDependencies? = nil
    ) async -> Bool {
        await systemAudioRecordingAccessDecision(forceRefresh: forceRefresh, dependencies: dependencies).canProceed
    }

    @MainActor
    static func systemAudioRecordingAccessDecision(
        forceRefresh: Bool = false,
        dependencies: SystemAudioPermissionDependencies? = nil
    ) async -> SystemAudioPermissionAccessDecision {
        let dependencies = dependencies ?? .live
        let cache = dependencies.cache
        switch refreshSystemAudioRecordingStatusFromSystem(
            tcc: dependencies.tcc, cache: cache, isSmokeMode: dependencies.isSmokeMode
        ) {
        case .authorized:
            return applySystemAudioRecordingProbeResult(.granted, cache: cache)
        case .denied:
            return applySystemAudioRecordingProbeResult(.explicitlyDenied, cache: cache)
        case .notDetermined:
            if let granted = await requestSystemAudioCaptureAccess(
                tcc: dependencies.tcc, activateForPrompt: dependencies.activateForPrompt,
                cache: cache, notifyChanged: dependencies.notifyChanged
            ) {
                return applySystemAudioRecordingProbeResult(granted ? .granted : .explicitlyDenied, cache: cache)
            }
        case .unavailable:
            break
        }

        if !forceRefresh, cache.read() == .granted {
            return SystemAudioPermissionAccessDecision(canProceed: true, state: .granted, probeResult: nil)
        }

        dependencies.activateForPrompt()
        let result = await dependencies.probe(cache.read())
        return applySystemAudioRecordingProbeResult(result, cache: cache)
    }

    @MainActor
    static func revalidateSystemAudioRecordingStatus(
        dependencies: SystemAudioPermissionDependencies? = nil
    ) async -> Bool {
        let dependencies = dependencies ?? .live
        let cache = dependencies.cache
        if dependencies.isSmokeMode() { return cache.read().isGranted }
        if let activeSystemAudioRevalidator {
            return await activeSystemAudioRevalidator.value
        }

        let cachedBefore = cache.read()
        switch refreshSystemAudioRecordingStatusFromSystem(
            tcc: dependencies.tcc, cache: cache, isSmokeMode: dependencies.isSmokeMode
        ) {
        case .authorized, .denied, .notDetermined:
            if cache.read() != cachedBefore { dependencies.notifyChanged() }
            return cache.read().isGranted
        case .unavailable:
            break
        }

        let task = Task { @MainActor in
            let result = await dependencies.probe(cache.read())
            let granted = applySystemAudioRecordingProbeResult(result, cache: cache).canProceed
            dependencies.notifyChanged()
            return granted
        }
        activeSystemAudioRevalidator = task
        let granted = await task.value
        activeSystemAudioRevalidator = nil
        return granted
    }

    @MainActor
    static func systemAudioProbeTimeout(for state: SystemAudioPermissionState) -> UInt64 {
        // A cached grant is historical, not new consent. Bound its health
        // recheck independently of the first-install dialog budget.
        state == .granted ? 3_000_000_000 : TranscriptedConstants.systemAudioPermissionRequestTimeout
    }

    @MainActor
    private static func performSystemAudioRecordingAccessRequest(
        cachedState: SystemAudioPermissionState
    ) async -> SystemAudioPermissionProbeResult {
        let requester = SystemAudioPermissionRequester()
        let attempt = SystemAudioPermissionRequestAttempt(
            timeoutNanoseconds: systemAudioProbeTimeout(for: cachedState)
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
        _ result: SystemAudioPermissionProbeResult,
        cache: SystemAudioPermissionCache
    ) -> SystemAudioPermissionAccessDecision {
        switch result {
        case .granted:
            cache.recordGrant(true)
        case .explicitlyDenied:
            cache.recordGrant(false)
        case .indeterminate:
            // Preserve the existing state. A probe timeout, daemon failure,
            // missing display, or stream setup/teardown error is not evidence
            // that the user revoked access.
            break
        }

        let state = cache.read()
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
