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
            UserDefaults.standard.removeObjectIfPresent(forKey: systemAudioRecordingKnownKey)
            UserDefaults.standard.removeObjectIfPresent(forKey: systemAudioRecordingGrantedKey)
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
