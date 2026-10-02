import Foundation

extension Notification.Name {
    static let dictationPersistentInputPreferenceChanged = Notification.Name(
        "dictationPersistentInputPreferenceChanged"
    )
}

enum DictationPersistentInputPreferences {
    private static let enabledKey = "dictationKeepRecommendedMicrophoneActive"
    private static let preferredDeviceUIDKey = "dictationPreferredInputDeviceUID"
    private static let recoverySelectedUIDKey = "dictationPersistentInputRecoverySelectedUID"
    private static let recoveryPreviousUIDKey = "dictationPersistentInputRecoveryPreviousUID"

    struct RecoveryMarker: Equatable {
        let selectedUID: String
        let previousUID: String
    }

    /// Off while the Mac mic recorder handles dictation (`recorderReplacesToggle`):
    /// it records the Mac's own mic without switching the macOS input, and the
    /// one Settings "Microphone" choice (`MicrophoneChoicePreferences`)
    /// replaces this toggle, so the controller puts back any input it
    /// switched. The stored toggle is kept for a Mac that turns the recorder
    /// off again, or picks Apple voice processing.
    static func isEnabled(
        userDefaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        isStoredOn(userDefaults: userDefaults)
            && !recorderReplacesToggle(userDefaults: userDefaults, environment: environment)
    }

    /// The saved toggle itself, whatever the recorder is doing.
    static func isStoredOn(userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.bool(forKey: enabledKey)
    }

    /// The recorder is on and dictation can use it. Apple voice processing
    /// only exists on the engine path, so with it chosen dictation never uses
    /// the recorder, and this toggle's Mac-wide switch is still the only thing
    /// keeping it off an AirPods mic.
    static func recorderReplacesToggle(
        userDefaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        PinnedMicrophoneCapturePreferences.isEnabled(userDefaults: userDefaults, environment: environment)
            && !MicrophoneProcessingPreferences.isVoiceProcessingEnabled(userDefaults: userDefaults)
    }

    /// Tells the controller to re-read `isEnabled()` after something it
    /// depends on changed outside this file (the mic processing mode).
    static func effectiveStateMayHaveChanged() {
        NotificationCenter.default.post(
            name: .dictationPersistentInputPreferenceChanged,
            object: nil
        )
    }

    static func setEnabled(_ enabled: Bool, userDefaults: UserDefaults = .standard) {
        userDefaults.set(enabled, forKey: enabledKey)
        NotificationCenter.default.post(
            name: .dictationPersistentInputPreferenceChanged,
            object: nil
        )
    }

    static func preferredDeviceUID(userDefaults: UserDefaults = .standard) -> String? {
        guard let value = userDefaults.string(forKey: preferredDeviceUIDKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    static func setPreferredDeviceUID(_ uid: String?, userDefaults: UserDefaults = .standard) {
        if let uid, !uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            userDefaults.set(uid, forKey: preferredDeviceUIDKey)
        } else {
            userDefaults.removeObject(forKey: preferredDeviceUIDKey)
        }
        NotificationCenter.default.post(
            name: .dictationPersistentInputPreferenceChanged,
            object: nil
        )
    }

    static func recoveryMarker(userDefaults: UserDefaults = .standard) -> RecoveryMarker? {
        guard let selectedUID = userDefaults.string(forKey: recoverySelectedUIDKey),
              !selectedUID.isEmpty,
              let previousUID = userDefaults.string(forKey: recoveryPreviousUIDKey),
              !previousUID.isEmpty else {
            return nil
        }
        return RecoveryMarker(selectedUID: selectedUID, previousUID: previousUID)
    }

    static func setRecoveryMarker(
        _ marker: RecoveryMarker?,
        userDefaults: UserDefaults = .standard
    ) {
        if let marker {
            userDefaults.set(marker.selectedUID, forKey: recoverySelectedUIDKey)
            userDefaults.set(marker.previousUID, forKey: recoveryPreviousUIDKey)
        } else {
            userDefaults.removeObject(forKey: recoverySelectedUIDKey)
            userDefaults.removeObject(forKey: recoveryPreviousUIDKey)
        }
        userDefaults.synchronize()
    }

}

enum DictationPersistentInputRecoveryAction: Equatable {
    case none
    case adopt
    case restore
    case preserve
    case clear
}

enum DictationPersistentInputRecoveryPolicy {
    static func action(
        preferenceEnabled: Bool,
        currentUID: String?,
        marker: DictationPersistentInputPreferences.RecoveryMarker?,
        availableUIDs: Set<String>
    ) -> DictationPersistentInputRecoveryAction {
        guard let marker else { return .none }
        guard currentUID == marker.selectedUID else {
            return .clear
        }
        guard availableUIDs.contains(marker.previousUID) else { return .preserve }
        return preferenceEnabled ? .adopt : .restore
    }
}

enum DictationPersistentInputRuntimeAction: Equatable {
    case reconcile
    case preserveExternalSelection
}

/// Decides whether a default-input notification represents an external choice
/// that the persistent preference must preserve. Device removal remains a
/// topology recovery; a live device changed away from Transcripted's last
/// maintained target relinquishes ownership for the rest of the app session.
enum DictationPersistentInputRuntimePolicy {
    static func action<ID: Equatable>(
        preferenceEnabled: Bool,
        runtimeOwnershipRelinquished: Bool,
        defaultInputChanged: Bool,
        deviceListChanged: Bool,
        currentInputID: ID,
        desiredInputID: ID,
        lastMaintainedInputID: ID?,
        lastMaintainedInputIsAvailable: Bool
    ) -> DictationPersistentInputRuntimeAction {
        guard preferenceEnabled else { return .reconcile }
        guard !runtimeOwnershipRelinquished else { return .preserveExternalSelection }
        guard defaultInputChanged, currentInputID != desiredInputID else { return .reconcile }

        if let lastMaintainedInputID {
            guard lastMaintainedInputIsAvailable else { return .reconcile }
            if lastMaintainedInputID == desiredInputID {
                return .preserveExternalSelection
            }
        }

        return deviceListChanged ? .reconcile : .preserveExternalSelection
    }
}

enum DictationPersistentInputRefreshPolicy {
    static func shouldSchedule(
        preferenceChanged: Bool,
        preferenceEnabled: Bool,
        hasRecoveryMarker: Bool
    ) -> Bool {
        preferenceChanged
            || preferenceEnabled
            || hasRecoveryMarker
    }

    /// The live speech engine already owns its selected input while dictation
    /// is active. Changing the system-wide default at that point can stop an
    /// otherwise healthy graph, so persistent preference maintenance waits
    /// until the recording has finished. Meeting capture has the same
    /// constraint: a Mac-wide default-input write mid-meeting can disrupt
    /// the capture graph. `isMeetingCaptureActive` is the full capture
    /// session (starting / recording / stopping), not steady-state only.
    /// External capture and an unavailable activity reading also defer this
    /// optional optimization; neither is evidence that a global write is safe.
    static func shouldDefer(
        isDictationActive: Bool,
        isMeetingCaptureActive: Bool,
        externalInputActive: Bool? = false
    ) -> Bool {
        isDictationActive || isMeetingCaptureActive || externalInputActive != false
    }
}

enum DictationPersistentInputShutdownPolicy {
    /// Quitting restores the user's previous mic only when no other app is
    /// known to be capturing. A busy or unreadable reading (nil, e.g. a
    /// blocked driver read that timed out) leaves the system input alone and
    /// keeps the durable marker so a later idle launch can restore it.
    static func shouldRestoreOnQuit(externalInputActive: Bool?) -> Bool {
        externalInputActive == false
    }
}

enum DictationPersistentInputRestorePolicy {
    /// Put the previous mic back only if the system input is still the one
    /// Transcripted chose. A mic the user picked elsewhere is left alone.
    static func shouldRestorePrevious<ID: Equatable>(currentInput: ID, ownedSelectedInput: ID) -> Bool {
        currentInput == ownedSelectedInput
    }
}

/// Defers persistent-input maintenance (a Mac-wide default-input write) until
/// no capture could be disturbed by it, and coalesces bursts of default-input,
/// device-list, and preference changes into one reconcile.
@MainActor
final class DictationPersistentInputRefreshScheduler {
    private var pendingDefaultInputChange = false
    private var pendingDeviceListChange = false
    private(set) var refreshTask: Task<Void, Never>?

    private let isMonitoring: () -> Bool
    private let preferenceEnabled: () -> Bool
    private let hasRecoveryMarker: () -> Bool
    private let isDictationActive: () -> Bool
    private let isMeetingCaptureActive: () -> Bool
    private let readExternalInputActivity: () async -> Bool?
    private let delay: () async -> Void
    private let reconcile: (_ defaultInputChanged: Bool, _ deviceListChanged: Bool) -> Void

    init(
        isMonitoring: @escaping () -> Bool,
        preferenceEnabled: @escaping () -> Bool,
        hasRecoveryMarker: @escaping () -> Bool,
        isDictationActive: @escaping () -> Bool,
        isMeetingCaptureActive: @escaping () -> Bool,
        readExternalInputActivity: @escaping () async -> Bool?,
        delay: @escaping () async -> Void,
        reconcile: @escaping (_ defaultInputChanged: Bool, _ deviceListChanged: Bool) -> Void
    ) {
        self.isMonitoring = isMonitoring
        self.preferenceEnabled = preferenceEnabled
        self.hasRecoveryMarker = hasRecoveryMarker
        self.isDictationActive = isDictationActive
        self.isMeetingCaptureActive = isMeetingCaptureActive
        self.readExternalInputActivity = readExternalInputActivity
        self.delay = delay
        self.reconcile = reconcile
    }

    func schedule(
        defaultInputChanged: Bool = false,
        deviceListChanged: Bool = false,
        preferenceChanged: Bool = false
    ) {
        // A late listener callback after shutdown must not restart maintenance.
        guard isMonitoring() else { return }
        guard DictationPersistentInputRefreshPolicy.shouldSchedule(
            preferenceChanged: preferenceChanged,
            preferenceEnabled: preferenceEnabled(),
            hasRecoveryMarker: hasRecoveryMarker()
        ) else { return }
        pendingDefaultInputChange = pendingDefaultInputChange || defaultInputChanged
        pendingDeviceListChange = pendingDeviceListChange || deviceListChanged
        refreshTask?.cancel()
        let delay = self.delay
        refreshTask = Task { @MainActor [weak self] in
            await delay()
            guard !Task.isCancelled, let self else { return }
            while true {
                // The preference changes the Mac-wide input, so another app's
                // capture deserves the same protection as our own recordings.
                // Unknown activity defers this optional optimization rather
                // than risking a call.
                let externalInputActive = await self.readExternalInputActivity()
                guard !Task.isCancelled else { return }
                // Recheck our own capture after the asynchronous HAL read.
                guard DictationPersistentInputRefreshPolicy.shouldDefer(
                    isDictationActive: self.isDictationActive(),
                    isMeetingCaptureActive: self.isMeetingCaptureActive(),
                    externalInputActive: externalInputActive
                ) else { break }
                await self.delay()
                // Stopped monitoring (or a released owner) ends the wait.
                guard !Task.isCancelled, self.isMonitoring() else { return }
            }
            let defaultInputChanged = self.pendingDefaultInputChange
            let deviceListChanged = self.pendingDeviceListChange
            self.pendingDefaultInputChange = false
            self.pendingDeviceListChange = false
            self.reconcile(defaultInputChanged, deviceListChanged)
        }
    }

    func cancel() {
        refreshTask?.cancel()
        refreshTask = nil
        pendingDefaultInputChange = false
        pendingDeviceListChange = false
    }
}
