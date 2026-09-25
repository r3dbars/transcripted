// DictationInputDeviceSelectionPolicy.swift
// Follows the selected Mac input unless the user opts into a local-mic recommendation.

import Foundation

enum DictationAudioTransport: String {
    case builtIn
    case bluetooth
    case bluetoothLE
    case usb
    case aggregate
    case virtual
    case other
}

struct DictationAudioDevice: Equatable {
    let id: UInt32
    let name: String
    let transport: DictationAudioTransport
    let inputChannelCount: UInt32
    let uid: String?

    init(
        id: UInt32,
        name: String,
        transport: DictationAudioTransport,
        inputChannelCount: UInt32,
        uid: String? = nil
    ) {
        self.id = id
        self.name = name
        self.transport = transport
        self.inputChannelCount = inputChannelCount
        self.uid = uid
    }
}

enum DictationPreferredInputPolicy {
    static func input(
        preferredUID: String?,
        availableInputs: [DictationAudioDevice],
        automaticFallback: DictationAudioDevice
    ) -> DictationAudioDevice {
        guard let preferredUID,
              let preferred = availableInputs.first(where: {
                  $0.uid == preferredUID
                      && DictationInputDeviceSelectionPolicy.deviceClass(for: $0) != "bluetooth"
              }) else {
            return automaticFallback
        }
        return preferred
    }
}

/// The pinned recorder opens only the device it is handed, so it can skip a
/// Bluetooth headset mic without touching the macOS input. When the automatic
/// pick is steering away from a headset, a mic the user chose wins. On a Mac
/// with no built-in mic (Mac mini, Mac Studio), a wired or USB mic still beats
/// the headset. When macOS input is already a non-Bluetooth mic, it is
/// followed, unless the user picked a specific mic in Settings
/// (`chosenInputAlwaysWins`), which is then recorded whatever macOS has.
enum PinnedDictationInputPolicy {
    /// The recorder is needed when the engine would open a Bluetooth headset
    /// that is the macOS input while we record a different mic, and for a mic
    /// the user picked over a safe macOS input (the engine only ever records
    /// the macOS input, so only the recorder can reach it).
    ///
    /// It is also used for a plain built-in or wired mic, for speed. On the
    /// same Mac the recorder delivered the first audio in about 70ms where
    /// the engine took about 190ms, with an engine tail past 500ms. A
    /// Bluetooth headset that is itself the recorded mic, and aggregate,
    /// virtual or unknown inputs, keep the engine path.
    static func recorderIsNeeded(for selection: DictationInputDeviceSelection) -> Bool {
        if selection.didOverrideDefault,
           selection.reason == .userChosenInput
            || DictationInputDeviceSelectionPolicy.deviceClass(for: selection.defaultInput) == "bluetooth" {
            return true
        }
        return recorderIsFasterPath(for: selection.selectedInput)
    }

    static func recorderIsFasterPath(for input: DictationAudioDevice) -> Bool {
        switch DictationInputDeviceSelectionPolicy.deviceClass(for: input) {
        case "built_in", "external":
            return true
        default:
            return false
        }
    }

    /// Inputs to rank when re-picking after `excluded` died or went silent.
    /// The macOS default stays listed so the selection can still describe it;
    /// the caller rejects a pick that lands on the excluded id.
    static func candidates(
        _ availableInputs: [DictationAudioDevice],
        excluding excluded: UInt32?,
        defaultInputID: UInt32
    ) -> [DictationAudioDevice] {
        guard let excluded, excluded != defaultInputID else { return availableInputs }
        return availableInputs.filter { $0.id != excluded }
    }

    static func mayReplace(_ automatic: DictationInputDeviceSelection) -> Bool {
        automatic.reason == .preferredBuiltInForBluetoothHeadset
            || automatic.reason == .noBuiltInFallbackAvailable
    }

    static func selection(
        automatic: DictationInputDeviceSelection,
        availableInputs: [DictationAudioDevice],
        preferredUID: String?,
        chosenInputAlwaysWins: Bool = false,
        lidClosed: Bool = false
    ) -> DictationInputDeviceSelection {
        let chosen = preferredUID.flatMap { preferredUID in
            availableInputs.first(where: {
                $0.uid == preferredUID
                    && $0.inputChannelCount > 0
                    && DictationInputDeviceSelectionPolicy.deviceClass(for: $0) != "bluetooth"
                    && !(lidClosed && DictationInputDeviceSelectionPolicy.isLidMicrophone($0))
            })
        }

        guard mayReplace(automatic) else {
            // Following a safe macOS input, or the headset on purpose. Only a
            // mic picked in Settings replaces the first.
            guard chosenInputAlwaysWins,
                  automatic.reason == .defaultIsSafe,
                  let chosen,
                  chosen.id != automatic.defaultInput.id else {
                return automatic
            }
            return DictationInputDeviceSelection(
                defaultInput: automatic.defaultInput,
                selectedInput: chosen,
                defaultOutput: automatic.defaultOutput,
                reason: .userChosenInput
            )
        }

        if let chosen {
            return DictationInputDeviceSelection(
                defaultInput: automatic.defaultInput,
                selectedInput: chosen,
                defaultOutput: automatic.defaultOutput,
                reason: .preferredUserChosenForBluetoothHeadset
            )
        }

        guard automatic.reason == .noBuiltInFallbackAvailable,
              let external = preferredExternalInput(
                from: availableInputs,
                defaultInput: automatic.defaultInput
              ) else {
            return automatic
        }
        return DictationInputDeviceSelection(
            defaultInput: automatic.defaultInput,
            selectedInput: external,
            defaultOutput: automatic.defaultOutput,
            reason: .preferredExternalForBluetoothHeadset
        )
    }

    /// Only mics that read as real external hardware. Virtual and aggregate
    /// devices can be silent loopbacks, so they never stand in automatically.
    private static func preferredExternalInput(
        from availableInputs: [DictationAudioDevice],
        defaultInput: DictationAudioDevice
    ) -> DictationAudioDevice? {
        availableInputs
            .filter { $0.id != defaultInput.id && $0.inputChannelCount > 0 }
            .filter { DictationInputDeviceSelectionPolicy.deviceClass(for: $0) == "external" }
            .sorted { lhs, rhs in
                let lhsRank = lhs.transport == .usb ? 0 : 1
                let rhsRank = rhs.transport == .usb ? 0 : 1
                if lhsRank != rhsRank {
                    return lhsRank < rhsRank
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            .first
    }
}

enum DictationInputDeviceSelectionReason: String {
    case defaultIsSafe
    case preferredBuiltInForBluetoothHeadset
    case builtInFallbackSuppressedForRecoveryAttempt
    case noBuiltInFallbackAvailable
    case preferredUserChosenForBluetoothHeadset
    case preferredExternalForBluetoothHeadset
    /// A mic picked in Settings, recorded over a non-Bluetooth macOS input.
    case userChosenInput
}

struct DictationInputDeviceSelection: Equatable {
    let defaultInput: DictationAudioDevice
    let selectedInput: DictationAudioDevice
    let defaultOutput: DictationAudioDevice?
    let reason: DictationInputDeviceSelectionReason

    var didOverrideDefault: Bool {
        selectedInput.id != defaultInput.id
    }
}

enum DictationVoiceProcessingRouteDecision: Equatable {
    case disabledByPreference
    case enabled
    case deferredForSplitBluetoothOutput

    var shouldEnable: Bool {
        self == .enabled
    }
}

/// Apple voice processing owns a coupled input/output voice-call graph. On a
/// split route (for example, a built-in or USB mic with Bluetooth playback),
/// enabling it can pull CoreAudio toward the headset input and repeatedly
/// renegotiate the live mic format. Keep the user's preference for matched
/// routes, but use the stable regular input graph for split Bluetooth output.
enum DictationVoiceProcessingRoutePolicy {
    static func decision(
        requested: Bool,
        selection: DictationInputDeviceSelection?
    ) -> DictationVoiceProcessingRouteDecision {
        guard requested else { return .disabledByPreference }
        guard let selection, let defaultOutput = selection.defaultOutput else {
            return .enabled
        }

        let inputClass = DictationInputDeviceSelectionPolicy.deviceClass(
            for: selection.selectedInput
        )
        let outputClass = DictationInputDeviceSelectionPolicy.deviceClass(
            for: defaultOutput
        )
        guard outputClass == "bluetooth", inputClass != "bluetooth" else {
            return .enabled
        }
        return .deferredForSplitBluetoothOutput
    }
}

enum DictationInputDeviceSelectionPolicy {
    static func selection(
        defaultInput: DictationAudioDevice,
        defaultOutput: DictationAudioDevice?,
        availableInputs: [DictationAudioDevice],
        prefersBuiltInBluetoothInput: Bool = false,
        allowsBuiltInBluetoothFallback: Bool = true,
        lidClosed: Bool = false
    ) -> DictationInputDeviceSelection {
        // A visible built-in device is not proof that it can hear the user.
        // Normal dictation follows macOS; only the explicit faster-start mode
        // may recommend a different microphone to preserve Bluetooth playback.
        guard prefersBuiltInBluetoothInput,
              shouldAvoidBluetoothHeadsetInput(defaultInput, defaultOutput: defaultOutput) else {
            return DictationInputDeviceSelection(
                defaultInput: defaultInput,
                selectedInput: defaultInput,
                defaultOutput: defaultOutput,
                reason: .defaultIsSafe
            )
        }

        guard allowsBuiltInBluetoothFallback else {
            return DictationInputDeviceSelection(
                defaultInput: defaultInput,
                selectedInput: defaultInput,
                defaultOutput: defaultOutput,
                reason: .builtInFallbackSuppressedForRecoveryAttempt
            )
        }

        guard let builtInInput = preferredBuiltInInput(
            from: availableInputs,
            defaultInput: defaultInput,
            lidClosed: lidClosed
        ) else {
            return DictationInputDeviceSelection(
                defaultInput: defaultInput,
                selectedInput: defaultInput,
                defaultOutput: defaultOutput,
                reason: .noBuiltInFallbackAvailable
            )
        }

        return DictationInputDeviceSelection(
            defaultInput: defaultInput,
            selectedInput: builtInInput,
            defaultOutput: defaultOutput,
            reason: .preferredBuiltInForBluetoothHeadset
        )
    }

    static func deviceClass(for device: DictationAudioDevice) -> String {
        deviceClass(forName: device.name, transport: device.transport)
    }

    static func deviceClass(
        forName deviceName: String,
        transport: DictationAudioTransport = .other
    ) -> String {
        let normalized = normalize(deviceName)

        if isBluetoothTransport(transport) || isBluetoothHeadsetName(normalized) {
            return "bluetooth"
        }

        if isBuiltInCandidateName(normalized) || transport == .builtIn {
            return "built_in"
        }

        if transport == .aggregate {
            return "aggregate"
        }

        if transport == .virtual {
            return "virtual"
        }

        if isExternalMicrophoneName(normalized, transport: transport) {
            return "external"
        }

        return "unknown"
    }

    private static func shouldAvoidBluetoothHeadsetInput(
        _ defaultInput: DictationAudioDevice,
        defaultOutput: DictationAudioDevice?
    ) -> Bool {
        guard isBluetoothHeadsetInput(defaultInput) else { return false }

        guard let defaultOutput else {
            return true
        }

        if defaultOutput.id == defaultInput.id {
            return true
        }

        if isBluetoothAudioDevice(defaultOutput) {
            return true
        }

        return normalize(defaultOutput.name) == normalize(defaultInput.name)
    }

    /// A MacBook's own mic, which is cut off in hardware while the lid is
    /// closed. Not the headphone-jack mic or a display's mic.
    static func isLidMicrophone(_ device: DictationAudioDevice) -> Bool {
        let normalized = normalize(device.name)
        if normalized.contains("macbook") {
            return true
        }
        return device.transport == .builtIn
            && (normalized.contains("built-in microphone") || normalized.contains("built in microphone"))
    }

    private static func preferredBuiltInInput(
        from availableInputs: [DictationAudioDevice],
        defaultInput: DictationAudioDevice,
        lidClosed: Bool
    ) -> DictationAudioDevice? {
        availableInputs
            .filter { $0.id != defaultInput.id }
            .filter { !(lidClosed && isLidMicrophone($0)) }
            .filter { builtInInputRank($0) < Int.max }
            .sorted { lhs, rhs in
                let lhsRank = builtInInputRank(lhs)
                let rhsRank = builtInInputRank(rhs)
                if lhsRank != rhsRank {
                    return lhsRank < rhsRank
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            .first
    }

    private static func builtInInputRank(_ device: DictationAudioDevice) -> Int {
        let normalized = normalize(device.name)

        if normalized.contains("macbook") && normalized.contains("microphone") {
            return 0
        }

        if normalized.contains("built-in microphone")
            || normalized.contains("built in microphone") {
            return 1
        }

        if normalized.contains("studio display") && normalized.contains("microphone") {
            return 2
        }

        if device.transport == .builtIn
            && (normalized.contains("microphone") || normalized.contains("mic")) {
            return 3
        }

        if device.transport == .builtIn {
            return 4
        }

        return Int.max
    }

    private static func isBluetoothHeadsetInput(_ device: DictationAudioDevice) -> Bool {
        isBluetoothAudioDevice(device)
    }

    private static func isBluetoothAudioDevice(_ device: DictationAudioDevice) -> Bool {
        isBluetoothTransport(device.transport) || isBluetoothHeadsetName(normalize(device.name))
    }

    private static func isBluetoothTransport(_ transport: DictationAudioTransport) -> Bool {
        transport == .bluetooth || transport == .bluetoothLE
    }

    private static func isBluetoothHeadsetName(_ normalized: String) -> Bool {
        normalized.contains("airpod")
            || normalized.contains("bluetooth")
            || normalized.contains("beats")
            || normalized.contains("buds")
            || normalized.contains("earbuds")
            || normalized.contains("headset")
            || normalized.contains("hands-free")
            || normalized.contains("hands free")
            || normalized.contains("hfp")
    }

    private static func isBuiltInCandidateName(_ normalized: String) -> Bool {
        normalized.contains("macbook")
            || normalized.contains("built-in")
            || normalized.contains("built in")
            || normalized.contains("studio display")
    }

    private static func isExternalMicrophoneName(
        _ normalized: String,
        transport: DictationAudioTransport
    ) -> Bool {
        transport == .usb
            || normalized.contains("usb")
            || normalized.contains("audio interface")
            || normalized.contains("camera")
            || normalized.contains("c920")
            || normalized.contains("elgato")
            || normalized.contains("external")
            || normalized.contains("interface")
            || normalized.contains("logitech")
            || normalized.contains("mv7")
            || normalized.contains("rode")
            || normalized.contains("scarlett")
            || normalized.contains("shure")
            || normalized.contains("webcam")
            || normalized.contains("yeti")
    }

    private static func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

/// A valid audio format does not prove that AUHAL is bound to the selected mic.
/// Keep the binding operation testable without opening real audio hardware.
enum DictationInputDeviceBindingError: LocalizedError, Equatable {
    case applicationFailed
    case selectedDeviceNotBound
    case selectionUnavailable

    var errorDescription: String? {
        "The selected microphone is still settling. Try dictation again."
    }
}

enum DictationInputDeviceBindingPolicy {
    static func requireSelection(_ selection: DictationInputDeviceSelection?) throws -> DictationInputDeviceSelection {
        guard let selection, selection.selectedInput.id != 0 else {
            throw DictationInputDeviceBindingError.selectionUnavailable
        }
        return selection
    }

    /// Poll an already-issued route command. Reissuing the setter on every
    /// stale read can restart a slow driver's transition indefinitely.
    /// The probe must honor its remaining timeout, including native work.
    ///
    /// The probe reads back the device ID the route command just set, so it
    /// passes almost at once. The real settle is `initialDelayNanoseconds`,
    /// which the caller picks with `initialSettleDelay(for:)`.
    @MainActor
    static func waitForBinding<Value>(
        timeoutNanoseconds: UInt64 = TranscriptedConstants.audioInputBindingSettleTimeout,
        initialDelayNanoseconds: UInt64 = 0,
        pollIntervalNanoseconds: UInt64 = TranscriptedConstants.dictationReadinessPollInterval,
        now: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        sleep: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
        isCurrent: () -> Bool,
        probe: (UInt64) async throws -> Value
    ) async throws -> Value {
        let startedAt = now()
        func remaining() -> UInt64 {
            let elapsed = now() &- startedAt
            return elapsed < timeoutNanoseconds ? timeoutNanoseconds - elapsed : 0
        }
        var delay = initialDelayNanoseconds
        while true {
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            let beforeSleep = remaining()
            guard beforeSleep > 0 else { throw DictationInputDeviceBindingError.selectedDeviceNotBound }
            try await sleep(min(delay, beforeSleep))
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            let budget = remaining()
            guard budget > 0 else { throw DictationInputDeviceBindingError.selectedDeviceNotBound }
            do {
                let value = try await probe(budget)
                try Task.checkCancellation()
                guard isCurrent() else { throw CancellationError() }
                guard remaining() > 0 else { throw DictationInputDeviceBindingError.selectedDeviceNotBound }
                return value
            } catch DictationInputDeviceBindingError.selectedDeviceNotBound {
                // Only an unsettled ID is retryable. Native failures and
                // cancellation must leave this loop immediately.
                delay = max(1, pollIntervalNanoseconds)
            }
        }
    }

    /// Moving AUHAL off a Bluetooth headset that is the macOS input is the
    /// AirPods call-mode path (#1784), so it keeps the 300ms settle before
    /// the engine starts. Any other override starts right away.
    static func initialSettleDelay(for selection: DictationInputDeviceSelection) -> UInt64 {
        DictationInputDeviceSelectionPolicy.deviceClass(for: selection.defaultInput) == "bluetooth"
            ? TranscriptedConstants.audioRecoveryDelay
            : 0
    }

    /// Returns whether a route command was issued. A changed route must be
    /// verified by the caller after settling before publishing readiness.
    @discardableResult
    static func apply(
        selection: DictationInputDeviceSelection,
        currentDeviceID: () -> UInt32,
        setDeviceID: (UInt32) throws -> Void
    ) throws -> Bool {
        let selectedID = selection.selectedInput.id
        guard selectedID != 0 else {
            throw DictationInputDeviceBindingError.selectedDeviceNotBound
        }
        // Following the default also needs a rebind if an earlier session
        // pinned this graph to a different microphone.
        let needsBinding = currentDeviceID() != selectedID
        if needsBinding {
            try setDeviceID(selectedID)
            // A successful AUHAL command need not publish the new ID immediately.
            // Let audioInputSnapshot reach its bounded delay and strict verification.
            return true
        }
        try verify(selectedDeviceID: selectedID, boundDeviceID: currentDeviceID())
        return false
    }

    static func verify(selectedDeviceID: UInt32, boundDeviceID: UInt32) throws {
        guard selectedDeviceID != 0, selectedDeviceID == boundDeviceID else {
            throw DictationInputDeviceBindingError.selectedDeviceNotBound
        }
    }
}
