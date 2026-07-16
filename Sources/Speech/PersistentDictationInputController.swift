import CoreAudio
import Foundation

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
    private var defaultInputListener: AudioObjectPropertyListenerBlock?
    private var deviceListListener: AudioObjectPropertyListenerBlock?
    private var topologyRefreshTask: Task<Void, Never>?
    private var shouldRecoverInheritedTemporaryOverride = false
    private var pendingDefaultInputChange = false
    private var pendingDeviceListChange = false
    private var runtimeOwnershipRelinquished = false
    private var lastMaintainedInput: AudioDeviceID?

    func start() {
        guard preferenceObserver == nil else { return }
        preferenceObserver = NotificationCenter.default.addObserver(
            forName: .dictationPersistentInputPreferenceChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.runtimeOwnershipRelinquished = false
                self?.lastMaintainedInput = nil
                self?.reconcileCurrentPreference()
            }
        }
        installDefaultInputListener()
        installDeviceListListener()
        shouldRecoverInheritedTemporaryOverride =
            DictationPersistentInputPreferences.temporaryRecoveryMarker() != nil
        reconcileCurrentPreference()
    }

    func stopAndRestore() {
        if let preferenceObserver {
            NotificationCenter.default.removeObserver(preferenceObserver)
            self.preferenceObserver = nil
        }
        removeDefaultInputListener()
        removeDeviceListListener()
        topologyRefreshTask?.cancel()
        topologyRefreshTask = nil
        pendingDefaultInputChange = false
        pendingDeviceListChange = false
        restoreIfStillOwned(operation: "app_termination")
        runtimeOwnershipRelinquished = false
        lastMaintainedInput = nil
    }

    private func installDefaultInputListener() {
        guard defaultInputListener == nil else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                self?.scheduleTopologyRefresh(defaultInputChanged: true)
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            listener
        )
        if status == noErr {
            defaultInputListener = listener
        } else {
            EventReporter.shared.capture(
                level: .warning,
                engine: "parakeet",
                event: "dictation_persistent_input_listener_failed",
                message: "Could not monitor system microphone changes for the faster-start preference"
            )
        }
    }

    private func removeDefaultInputListener() {
        guard let defaultInputListener else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            defaultInputListener
        )
        self.defaultInputListener = nil
    }

    private func installDeviceListListener() {
        guard deviceListListener == nil else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                self?.scheduleTopologyRefresh(deviceListChanged: true)
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            listener
        )
        if status == noErr {
            deviceListListener = listener
        } else {
            EventReporter.shared.capture(
                level: .warning,
                engine: "parakeet",
                event: "dictation_persistent_input_device_listener_failed",
                message: "Could not monitor microphone connections for the faster-start preference"
            )
        }
    }

    private func removeDeviceListListener() {
        guard let deviceListListener else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            deviceListListener
        )
        self.deviceListListener = nil
    }

    private func scheduleTopologyRefresh(
        defaultInputChanged: Bool = false,
        deviceListChanged: Bool = false
    ) {
        guard DictationPersistentInputPreferences.isEnabled()
                || DictationPersistentInputPreferences.recoveryMarker() != nil
                || shouldRecoverInheritedTemporaryOverride else { return }
        pendingDefaultInputChange = pendingDefaultInputChange || defaultInputChanged
        pendingDeviceListChange = pendingDeviceListChange || deviceListChanged
        topologyRefreshTask?.cancel()
        topologyRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: TranscriptedConstants.audioRecoveryDelay)
            guard !Task.isCancelled, let self else { return }
            let defaultInputChanged = self.pendingDefaultInputChange
            let deviceListChanged = self.pendingDeviceListChange
            self.pendingDefaultInputChange = false
            self.pendingDeviceListChange = false
            self.reconcileCurrentPreference(
                defaultInputChanged: defaultInputChanged,
                deviceListChanged: deviceListChanged
            )
        }
    }

    private func reconcileCurrentPreference(
        defaultInputChanged: Bool = false,
        deviceListChanged: Bool = false
    ) {
        if shouldRecoverInheritedTemporaryOverride {
            recoverTemporaryOwnership()
        }
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
        if !DictationPersistentInputPreferences.isEnabled() {
            restoreIfStillOwned(operation: "preference_disabled")
            runtimeOwnershipRelinquished = false
            lastMaintainedInput = nil
            return
        }

        guard !runtimeOwnershipRelinquished else { return }

        do {
            let selection = try CoreAudioInputDeviceLookup.preferredDictationInputSelection()
            let availableInputs = try CoreAudioInputDeviceLookup.availableInputDevices()
            if activeOverride == nil,
               let marker = DictationPersistentInputPreferences.recoveryMarker(),
               selection.defaultInput.uid == marker.selectedUID {
                return
            }
            let selectedInput = DictationPreferredInputPolicy.input(
                preferredUID: DictationPersistentInputPreferences.preferredDeviceUID(),
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
                DictationPersistentInputPreferences.setRecoveryMarker(nil)
                EventReporter.shared.capture(
                    level: .info,
                    engine: "parakeet",
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
                DictationPersistentInputPreferences.setRecoveryMarker(nil)
            }
            guard selectedInput.id != selection.defaultInput.id else {
                EventReporter.shared.capture(
                    level: .info,
                    engine: "parakeet",
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
            DictationPersistentInputPreferences.setRecoveryMarker(recoveryMarker)
            do {
                try CoreAudioInputDeviceLookup.setDefaultInputDeviceID(selectedInput.id)
            } catch {
                DictationPersistentInputPreferences.setRecoveryMarker(nil)
                throw error
            }
            activeOverride = ActiveOverride(
                selectedInput: selectedInput.id,
                previousInput: previousInput,
                marker: recoveryMarker
            )
            lastMaintainedInput = selectedInput.id
            EventReporter.shared.capture(
                level: .info,
                engine: "parakeet",
                event: "dictation_persistent_input_selected",
                message: "Kept the recommended microphone active for faster Bluetooth dictation starts",
                context: [
                    "previous_input_class": DictationInputDeviceSelectionPolicy.deviceClass(for: selection.defaultInput),
                    "selected_input_class": DictationInputDeviceSelectionPolicy.deviceClass(for: selectedInput),
                    "selection_mode": selectedInput.uid == DictationPersistentInputPreferences.preferredDeviceUID() ? "preferred" : "automatic",
                    "default_output_class": selection.defaultOutput.map(DictationInputDeviceSelectionPolicy.deviceClass(for:)) ?? "unknown"
                ]
            )
        } catch {
            EventReporter.shared.capture(
                level: .warning,
                engine: "parakeet",
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
            let currentInput = try CoreAudioInputDeviceLookup.currentDefaultInputDeviceID()
            guard currentInput == activeOverride.selectedInput else {
                DictationPersistentInputPreferences.setRecoveryMarker(nil)
                EventReporter.shared.capture(
                    level: .info,
                    engine: "parakeet",
                    event: "dictation_persistent_input_restore_skipped",
                    message: "Preserved a microphone selection changed outside Transcripted",
                    context: ["operation": operation]
                )
                return
            }
            try CoreAudioInputDeviceLookup.setDefaultInputDeviceID(activeOverride.previousInput)
            DictationPersistentInputPreferences.setRecoveryMarker(nil)
            EventReporter.shared.capture(
                level: .info,
                engine: "parakeet",
                event: "dictation_persistent_input_restored",
                message: "Restored the microphone selected before Transcripted's faster-start preference",
                context: ["operation": operation]
            )
        } catch {
            EventReporter.shared.capture(
                level: .warning,
                engine: "parakeet",
                event: "dictation_persistent_input_restore_failed",
                message: "Could not restore the previous system microphone",
                context: ["operation": operation]
            )
        }
    }

    private func recoverPersistedOwnership() {
        guard let marker = DictationPersistentInputPreferences.recoveryMarker() else { return }
        do {
            let availableInputs = try CoreAudioInputDeviceLookup.availableInputDevices()
            let currentInputID = try CoreAudioInputDeviceLookup.currentDefaultInputDeviceID()
            let currentUID = availableInputs.first(where: { $0.id == currentInputID })?.uid
            let availableByUID = Dictionary(
                uniqueKeysWithValues: availableInputs.compactMap { device in
                    device.uid.map { ($0, device) }
                }
            )
            let action = DictationPersistentInputRecoveryPolicy.action(
                preferenceEnabled: DictationPersistentInputPreferences.isEnabled(),
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
                    DictationPersistentInputPreferences.setRecoveryMarker(nil)
                    return
                }
                activeOverride = ActiveOverride(
                    selectedInput: selected.id,
                    previousInput: previous.id,
                    marker: marker
                )
                EventReporter.shared.capture(
                    level: .info,
                    engine: "parakeet",
                    event: "dictation_persistent_input_ownership_recovered",
                    message: "Recovered microphone restoration ownership after an unclean app exit"
                )
            case .restore:
                guard let previous = availableByUID[marker.previousUID] else {
                    DictationPersistentInputPreferences.setRecoveryMarker(nil)
                    return
                }
                try CoreAudioInputDeviceLookup.setDefaultInputDeviceID(previous.id)
                DictationPersistentInputPreferences.setRecoveryMarker(nil)
            case .preserve:
                return
            case .clear:
                DictationPersistentInputPreferences.setRecoveryMarker(nil)
            }
        } catch {
            EventReporter.shared.capture(
                level: .warning,
                engine: "parakeet",
                event: "dictation_persistent_input_ownership_recovery_failed",
                message: "Could not reconcile microphone ownership after an unclean app exit"
            )
        }
    }

    private func recoverTemporaryOwnership() {
        guard let marker = DictationPersistentInputPreferences.temporaryRecoveryMarker() else {
            shouldRecoverInheritedTemporaryOverride = false
            return
        }
        do {
            let availableInputs = try CoreAudioInputDeviceLookup.availableInputDevices()
            let currentInputID = try CoreAudioInputDeviceLookup.currentDefaultInputDeviceID()
            let currentUID = availableInputs.first(where: { $0.id == currentInputID })?.uid
            let availableByUID = Dictionary(
                uniqueKeysWithValues: availableInputs.compactMap { device in
                    device.uid.map { ($0, device) }
                }
            )
            let action = DictationPersistentInputRecoveryPolicy.action(
                preferenceEnabled: false,
                currentUID: currentUID,
                marker: marker,
                availableUIDs: Set(availableByUID.keys)
            )
            switch action {
            case .restore:
                guard let previous = availableByUID[marker.previousUID] else { return }
                try CoreAudioInputDeviceLookup.setDefaultInputDeviceID(previous.id)
                DictationPersistentInputPreferences.setTemporaryRecoveryMarker(nil)
                shouldRecoverInheritedTemporaryOverride = false
            case .clear:
                DictationPersistentInputPreferences.setTemporaryRecoveryMarker(nil)
                shouldRecoverInheritedTemporaryOverride = false
            case .none, .adopt, .preserve:
                return
            }
        } catch {
            EventReporter.shared.capture(
                level: .warning,
                engine: "parakeet",
                event: "dictation_temporary_input_ownership_recovery_failed",
                message: "Could not restore the microphone after an interrupted dictation"
            )
        }
    }
}
