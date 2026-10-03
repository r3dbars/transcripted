import CoreAudio
import Foundation

/// Everything `PersistentDictationInputController` reaches outside itself: the
/// shared default-input monitor, the HAL device-list listener, CoreAudio
/// lookups and the one Mac-wide input write, preferences, and reporting.
/// Production always uses `.live` (PersistentDictationInputController+Live.swift);
/// tests hand in fakes so the wiring runs without CoreAudio or real prefs.
struct PersistentDictationInputSystem {
    struct Report: Equatable {
        enum Level: Equatable { case info, warning }
        let level: Level
        let event: String
        let message: String
        let context: [String: String]?
    }

    var userDefaults: UserDefaults
    var defaultInputMonitor: any DefaultInputDeviceSubscribing
    /// The Mac-wide default-input write. Live: `DefaultInputDeviceMonitor.shared.setDefaultInputDevice(_:)`.
    var setDefaultInput: (AudioDeviceID) throws -> Void
    /// Registers `handler` for `kAudioHardwarePropertyDevices` changes. Returns
    /// the registration to remove later, or nil when the HAL refused it.
    var addDeviceListListener: (_ handler: @escaping @MainActor () -> Void) -> AudioObjectPropertyListenerBlock?
    var removeDeviceListListener: (@escaping AudioObjectPropertyListenerBlock) -> Void
    /// The current default input plus the faster-start (built-in over Bluetooth) recommendation.
    var recommendedSelection: () throws -> DictationInputDeviceSelection
    var availableInputs: () throws -> [DictationAudioDevice]
    var currentDefaultInputID: () throws -> AudioDeviceID
    /// May block in a driver; always called off the main actor.
    var hasExternalInputActivity: @Sendable () throws -> Bool
    var report: (Report) -> Void
    /// Wait between deferred maintenance checks.
    var refreshDelay: () async -> Void
    /// Runs a HAL listener add, then hands its result back on the main actor.
    /// Live: the add runs on `HALListenerRegistrationQueue` (after the shared
    /// monitor's default-input add, which is queued first), so the launch-time
    /// HAL client init never blocks main. Fakes run both steps inline.
    var registerListener: (
        _ work: @escaping @Sendable () -> AudioObjectPropertyListenerBlock?,
        _ completion: @escaping @MainActor (AudioObjectPropertyListenerBlock?) -> Void
    ) -> Void = { work, completion in
        let listener = work()
        MainActor.assumeIsolated { completion(listener) }
    }
}

/// Carries the device-list add onto the registration queue. Live, `add` is a
/// static function with no captured state and `handler` only runs on main
/// (the HAL listener hops there); fakes run the add inline on main. So nothing
/// in here is touched from two threads at once.
private struct DeviceListListenerAdd: @unchecked Sendable {
    let add: (_ handler: @escaping @MainActor () -> Void) -> AudioObjectPropertyListenerBlock?
    let handler: @MainActor () -> Void

    func callAsFunction() -> AudioObjectPropertyListenerBlock? { add(handler) }
}

/// Applies the recommended non-Bluetooth microphone once per app lifetime when
/// the user explicitly opts in. Keeping that device as the system default avoids
/// paying the CoreAudio Bluetooth route-switch penalty on every dictation start.
@MainActor
final class PersistentDictationInputController {
    private struct ActiveOverride {
        let selectedInput: AudioDeviceID
        let previousInput: AudioDeviceID
        let marker: DictationPersistentInputPreferences.RecoveryMarker?
    }

    private var activeOverride: ActiveOverride?
    private var preferenceObserver: NSObjectProtocol?
    private var defaultInputObserverToken: DefaultInputDeviceObserverToken?
    private var deviceListListener: AudioObjectPropertyListenerBlock?
    private var deviceListRegistrationPending = false
    /// Bumped on every stop, so a device-list add that finishes after
    /// `stopMonitoring()` is undone instead of adopted.
    private var deviceListRegistrationGeneration: UInt64 = 0
    private var externalInputActivityTask: Task<Bool?, Never>?
    private var runtimeOwnershipRelinquished = false
    private var lastMaintainedInput: AudioDeviceID?
    private let isDictationActive: () -> Bool
    private let isMeetingCaptureActive: () -> Bool
    private let system: PersistentDictationInputSystem
    private lazy var refreshScheduler = DictationPersistentInputRefreshScheduler(
        isMonitoring: { [weak self] in self?.preferenceObserver != nil },
        preferenceEnabled: { [system] in DictationPersistentInputPreferences.isEnabled(userDefaults: system.userDefaults) },
        hasRecoveryMarker: { [system] in DictationPersistentInputPreferences.recoveryMarker(userDefaults: system.userDefaults) != nil },
        isDictationActive: { [weak self] in self?.isDictationActive() ?? false },
        isMeetingCaptureActive: { [weak self] in self?.isMeetingCaptureActive() ?? false },
        readExternalInputActivity: { [weak self] in await self?.readExternalInputActivity() },
        delay: { [system] in await system.refreshDelay() },
        reconcile: { [weak self] defaultInputChanged, deviceListChanged in
            self?.reconcileCurrentPreference(
                defaultInputChanged: defaultInputChanged,
                deviceListChanged: deviceListChanged
            )
        }
    )

    init(
        isDictationActive: @escaping () -> Bool = { false },
        isMeetingCaptureActive: @escaping () -> Bool = { false },
        system: PersistentDictationInputSystem
    ) {
        self.isDictationActive = isDictationActive
        self.isMeetingCaptureActive = isMeetingCaptureActive
        self.system = system
    }

    /// The deferred maintenance pass currently scheduled, if any. Tests await it.
    var pendingRefresh: Task<Void, Never>? { refreshScheduler.refreshTask }

    func start() {
        guard preferenceObserver == nil else { return }
        preferenceObserver = NotificationCenter.default.addObserver(
            forName: .dictationPersistentInputPreferenceChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.runtimeOwnershipRelinquished = false
                self.lastMaintainedInput = nil
                self.scheduleTopologyRefresh(preferenceChanged: true)
            }
        }
        installDefaultInputListener()
        // The first reconcile is scheduled once the device-list add returns
        // (see deviceListRegistrationFinished), so no reconcile or Mac-wide
        // input write runs before both listeners are live.
        installDeviceListListener()
    }

    func stopAndRestore() async {
        stopMonitoring()
        guard activeOverride != nil else { return }
        let externalInputActive = try? await TranscriptedConstants.withDetachedTimeout(seconds: 0.5) {
            await self.readExternalInputActivity()
        }
        // Do not perturb another app's call just because Transcripted quits.
        // Keep the durable marker so a later idle launch can restore ownership.
        guard DictationPersistentInputShutdownPolicy.shouldRestoreOnQuit(
            externalInputActive: externalInputActive
        ) else {
            activeOverride = nil
            return
        }
        restoreIfStillOwned(operation: "app_termination")
        runtimeOwnershipRelinquished = false
        lastMaintainedInput = nil
    }

    func stopMonitoring() {
        if let preferenceObserver {
            NotificationCenter.default.removeObserver(preferenceObserver)
            self.preferenceObserver = nil
        }
        removeDefaultInputListener()
        removeDeviceListListener()
        refreshScheduler.cancel()
    }

    // MARK: - Default input device monitoring
    //
    // Migrated to the shared `DefaultInputDeviceMonitor` (codebase audit
    // 2026-08 — three independent listeners on
    // kAudioHardwarePropertyDefaultInputDevice with no ordering guarantee,
    // and this controller's own writes re-firing everyone including itself).
    // Previously this installed its own `AudioObjectAddPropertyListenerBlock`
    // and had no explicit self-write suppression of its own beyond the
    // recovery-marker short-circuit in `applyCurrentPreference` (which only
    // skips *reapplying* an already-satisfied preference — it did not stop
    // the notification from firing or from being handled by the other two
    // listeners).
    //
    // isSelfWrite policy: ignore. `DefaultInputDeviceMonitor` classifies the
    // notification caused by this controller's own
    // `setDefaultInputDevice(_:)` writes as `isSelfWrite == true`; this
    // handler drops those instead of scheduling a topology refresh, which is
    // what prevents the write-triggers-notification-triggers-reconcile
    // feedback loop this migration exists to fix. The recovery-marker
    // short-circuit in `applyCurrentPreference` is unrelated and unchanged
    // (it survives unclean exits, where there is no in-memory pending write
    // to classify).
    private func installDefaultInputListener() {
        guard defaultInputObserverToken == nil else { return }
        system.defaultInputMonitor.start()
        defaultInputObserverToken = system.defaultInputMonitor.addObserver { [weak self] isSelfWrite in
            guard !isSelfWrite else { return }
            self?.scheduleTopologyRefresh(defaultInputChanged: true)
        }
    }

    private func removeDefaultInputListener() {
        guard let defaultInputObserverToken else { return }
        system.defaultInputMonitor.removeObserver(defaultInputObserverToken)
        self.defaultInputObserverToken = nil
    }

    private func installDeviceListListener() {
        guard deviceListListener == nil, !deviceListRegistrationPending else { return }
        deviceListRegistrationPending = true
        let generation = deviceListRegistrationGeneration
        let add = DeviceListListenerAdd(add: system.addDeviceListListener) { [weak self] in
            self?.scheduleTopologyRefresh(deviceListChanged: true)
        }
        system.registerListener({ add() }) { [weak self] listener in
            self?.deviceListRegistrationFinished(listener, generation: generation)
        }
    }

    private func deviceListRegistrationFinished(
        _ listener: AudioObjectPropertyListenerBlock?,
        generation: UInt64
    ) {
        guard generation == deviceListRegistrationGeneration else {
            // stopMonitoring() ran while the add was pending: undo it.
            if let listener { system.removeDeviceListListener(listener) }
            return
        }
        deviceListRegistrationPending = false
        if let listener {
            deviceListListener = listener
        } else {
            report(
                .warning,
                event: "dictation_persistent_input_device_listener_failed",
                message: "Could not monitor microphone connections for the faster-start preference"
            )
        }
        // The default-input add was queued ahead of this one, so both
        // listeners are live now. A change that landed during registration is
        // picked up by this first pass.
        guard preferenceObserver != nil else { return }
        scheduleTopologyRefresh()
    }

    private func removeDeviceListListener() {
        deviceListRegistrationGeneration &+= 1
        deviceListRegistrationPending = false
        guard let deviceListListener else { return }
        system.removeDeviceListListener(deviceListListener)
        self.deviceListListener = nil
    }

    private func scheduleTopologyRefresh(
        defaultInputChanged: Bool = false,
        deviceListChanged: Bool = false,
        preferenceChanged: Bool = false
    ) {
        refreshScheduler.schedule(
            defaultInputChanged: defaultInputChanged,
            deviceListChanged: deviceListChanged,
            preferenceChanged: preferenceChanged
        )
    }

    private func readExternalInputActivity() async -> Bool? {
        // A cancelled refresh must not spawn another HAL read while the previous
        // one is still blocked in a driver. All callers share the in-flight read.
        if let externalInputActivityTask {
            return await externalInputActivityTask.value
        }
        let hasExternalInputActivity = system.hasExternalInputActivity
        let task = Task.detached(priority: .utility) {
            try? hasExternalInputActivity()
        }
        externalInputActivityTask = task
        let activity = await task.value
        externalInputActivityTask = nil
        return activity
    }

    private func reconcileCurrentPreference(
        defaultInputChanged: Bool = false,
        deviceListChanged: Bool = false
    ) {
        recoverPersistedOwnership()
        applyCurrentPreference(
            defaultInputChanged: defaultInputChanged,
            deviceListChanged: deviceListChanged
        )
    }

    private func applyCurrentPreference(
        defaultInputChanged: Bool,
        deviceListChanged: Bool
    ) {
        if !DictationPersistentInputPreferences.isEnabled(userDefaults: system.userDefaults) {
            restoreIfStillOwned(operation: "preference_disabled")
            runtimeOwnershipRelinquished = false
            lastMaintainedInput = nil
            return
        }

        guard !runtimeOwnershipRelinquished else { return }

        do {
            let selection = try system.recommendedSelection()
            let availableInputs = try system.availableInputs()
            if activeOverride == nil,
               let marker = DictationPersistentInputPreferences.recoveryMarker(userDefaults: system.userDefaults),
               selection.defaultInput.uid == marker.selectedUID {
                return
            }
            let selectedInput = DictationPreferredInputPolicy.input(
                preferredUID: DictationPersistentInputPreferences.preferredDeviceUID(userDefaults: system.userDefaults),
                availableInputs: availableInputs,
                automaticFallback: selection.selectedInput
            )
            let runtimeAction = DictationPersistentInputRuntimePolicy.action(
                preferenceEnabled: true,
                runtimeOwnershipRelinquished: runtimeOwnershipRelinquished,
                defaultInputChanged: defaultInputChanged,
                deviceListChanged: deviceListChanged,
                currentInputID: selection.defaultInput.id,
                desiredInputID: selectedInput.id,
                lastMaintainedInputID: lastMaintainedInput,
                lastMaintainedInputIsAvailable: lastMaintainedInput.map { inputID in
                    availableInputs.contains(where: { $0.id == inputID })
                } ?? false
            )
            if runtimeAction == .preserveExternalSelection {
                activeOverride = nil
                lastMaintainedInput = nil
                runtimeOwnershipRelinquished = true
                DictationPersistentInputPreferences.setRecoveryMarker(nil, userDefaults: system.userDefaults)
                report(
                    .info,
                    event: "dictation_persistent_input_external_selection_preserved",
                    message: "Preserved a microphone selection changed outside Transcripted",
                    context: [
                        "current_input_class": DictationInputDeviceSelectionPolicy.deviceClass(for: selection.defaultInput),
                        "preferred_input_class": DictationInputDeviceSelectionPolicy.deviceClass(for: selectedInput),
                        "device_list_changed": String(deviceListChanged)
                    ]
                )
                return
            }
            if selection.defaultInput.id == selectedInput.id {
                lastMaintainedInput = selectedInput.id
                if activeOverride?.selectedInput == selectedInput.id {
                    return
                }
                activeOverride = nil
                DictationPersistentInputPreferences.setRecoveryMarker(nil, userDefaults: system.userDefaults)
            }
            guard selectedInput.id != selection.defaultInput.id else {
                report(
                    .info,
                    event: "dictation_persistent_input_already_safe",
                    message: "Persistent dictation microphone preference required no system input change",
                    context: [
                        "default_input_class": DictationInputDeviceSelectionPolicy.deviceClass(for: selection.defaultInput),
                        "default_output_class": selection.defaultOutput.map(DictationInputDeviceSelectionPolicy.deviceClass(for:)) ?? "unknown"
                    ]
                )
                return
            }

            let previousInput: AudioDeviceID
            let previousUID: String?
            if let activeOverride, activeOverride.selectedInput == selection.defaultInput.id {
                previousInput = activeOverride.previousInput
                previousUID = activeOverride.marker?.previousUID
            } else {
                previousInput = selection.defaultInput.id
                previousUID = selection.defaultInput.uid
            }
            let recoveryMarker = selectedInput.uid.flatMap { selectedUID in
                previousUID.map {
                    DictationPersistentInputPreferences.RecoveryMarker(
                        selectedUID: selectedUID,
                        previousUID: $0
                    )
                }
            }
            DictationPersistentInputPreferences.setRecoveryMarker(recoveryMarker, userDefaults: system.userDefaults)
            do {
                try system.setDefaultInput(selectedInput.id)
            } catch {
                DictationPersistentInputPreferences.setRecoveryMarker(nil, userDefaults: system.userDefaults)
                throw error
            }
            activeOverride = ActiveOverride(
                selectedInput: selectedInput.id,
                previousInput: previousInput,
                marker: recoveryMarker
            )
            lastMaintainedInput = selectedInput.id
            report(
                .info,
                event: "dictation_persistent_input_selected",
                message: "Kept the recommended microphone active for faster Bluetooth dictation starts",
                context: [
                    "previous_input_class": DictationInputDeviceSelectionPolicy.deviceClass(for: selection.defaultInput),
                    "selected_input_class": DictationInputDeviceSelectionPolicy.deviceClass(for: selectedInput),
                    "selection_mode": selectedInput.uid == DictationPersistentInputPreferences.preferredDeviceUID(userDefaults: system.userDefaults) ? "preferred" : "automatic",
                    "default_output_class": selection.defaultOutput.map(DictationInputDeviceSelectionPolicy.deviceClass(for:)) ?? "unknown"
                ]
            )
        } catch {
            report(
                .warning,
                event: "dictation_persistent_input_failed",
                message: "Could not keep the recommended microphone active",
                context: ["operation": "apply"]
            )
        }
    }

    private func restoreIfStillOwned(operation: String) {
        guard let activeOverride else { return }
        self.activeOverride = nil
        do {
            let currentInput = try system.currentDefaultInputID()
            guard DictationPersistentInputRestorePolicy.shouldRestorePrevious(
                currentInput: currentInput,
                ownedSelectedInput: activeOverride.selectedInput
            ) else {
                DictationPersistentInputPreferences.setRecoveryMarker(nil, userDefaults: system.userDefaults)
                report(
                    .info,
                    event: "dictation_persistent_input_restore_skipped",
                    message: "Preserved a microphone selection changed outside Transcripted",
                    context: ["operation": operation]
                )
                return
            }
            try system.setDefaultInput(activeOverride.previousInput)
            DictationPersistentInputPreferences.setRecoveryMarker(nil, userDefaults: system.userDefaults)
            report(
                .info,
                event: "dictation_persistent_input_restored",
                message: "Restored the microphone selected before Transcripted's faster-start preference",
                context: ["operation": operation]
            )
        } catch {
            report(
                .warning,
                event: "dictation_persistent_input_restore_failed",
                message: "Could not restore the previous system microphone",
                context: ["operation": operation]
            )
        }
    }

    private func recoverPersistedOwnership() {
        guard let marker = DictationPersistentInputPreferences.recoveryMarker(userDefaults: system.userDefaults) else { return }
        do {
            let availableInputs = try system.availableInputs()
            let currentInputID = try system.currentDefaultInputID()
            let currentUID = availableInputs.first(where: { $0.id == currentInputID })?.uid
            let availableByUID = Dictionary(
                availableInputs.compactMap { device in
                    device.uid.map { ($0, device) }
                },
                // A duplicate UID is out-of-spec but reachable from a bad driver, and
                // uniqueKeysWithValues traps on one instead of throwing, so the
                // enclosing do/catch cannot contain it. First match wins, matching the
                // first(where:) UID lookups elsewhere in this subsystem.
                uniquingKeysWith: { first, _ in first }
            )
            let action = DictationPersistentInputRecoveryPolicy.action(
                preferenceEnabled: DictationPersistentInputPreferences.isEnabled(userDefaults: system.userDefaults),
                currentUID: currentUID,
                marker: marker,
                availableUIDs: Set(availableByUID.keys)
            )
            switch action {
            case .none:
                return
            case .adopt:
                guard let selected = availableByUID[marker.selectedUID],
                      let previous = availableByUID[marker.previousUID] else {
                    DictationPersistentInputPreferences.setRecoveryMarker(nil, userDefaults: system.userDefaults)
                    return
                }
                activeOverride = ActiveOverride(
                    selectedInput: selected.id,
                    previousInput: previous.id,
                    marker: marker
                )
                report(
                    .info,
                    event: "dictation_persistent_input_ownership_recovered",
                    message: "Recovered microphone restoration ownership after an unclean app exit"
                )
            case .restore:
                guard let previous = availableByUID[marker.previousUID] else {
                    DictationPersistentInputPreferences.setRecoveryMarker(nil, userDefaults: system.userDefaults)
                    return
                }
                try system.setDefaultInput(previous.id)
                DictationPersistentInputPreferences.setRecoveryMarker(nil, userDefaults: system.userDefaults)
            case .preserve:
                return
            case .clear:
                DictationPersistentInputPreferences.setRecoveryMarker(nil, userDefaults: system.userDefaults)
            }
        } catch {
            report(
                .warning,
                event: "dictation_persistent_input_ownership_recovery_failed",
                message: "Could not reconcile microphone ownership after an unclean app exit"
            )
        }
    }

    private func report(
        _ level: PersistentDictationInputSystem.Report.Level,
        event: String,
        message: String,
        context: [String: String]? = nil
    ) {
        system.report(.init(level: level, event: event, message: message, context: context))
    }
}
