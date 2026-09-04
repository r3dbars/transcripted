// DictationInputDeviceSelectionPolicy.swift
// Keeps Bluetooth headset microphones from taking over music playback when a local mic is available.

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

enum DictationInputDeviceSelectionReason: String {
    case defaultIsSafe
    case preferredBuiltInForBluetoothHeadset
    case builtInFallbackSuppressedForRecoveryAttempt
    case noBuiltInFallbackAvailable
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
        allowsBuiltInBluetoothFallback: Bool = true
    ) -> DictationInputDeviceSelection {
        guard shouldAvoidBluetoothHeadsetInput(defaultInput, defaultOutput: defaultOutput) else {
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

        guard let builtInInput = preferredBuiltInInput(from: availableInputs, defaultInput: defaultInput) else {
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

    private static func preferredBuiltInInput(
        from availableInputs: [DictationAudioDevice],
        defaultInput: DictationAudioDevice
    ) -> DictationAudioDevice? {
        availableInputs
            .filter { $0.id != defaultInput.id }
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

    var errorDescription: String? {
        "The selected microphone is still settling. Try dictation again."
    }
}

enum DictationInputDeviceBindingPolicy {
    @discardableResult
    static func apply(
        selection: DictationInputDeviceSelection,
        currentDeviceID: () -> UInt32,
        setDeviceID: (UInt32) throws -> Void
    ) throws -> Bool {
        let selectedID = selection.selectedInput.id
        // Following the default also needs a rebind if an earlier session
        // pinned this graph to a different microphone.
        let needsBinding = currentDeviceID() != selectedID
        if needsBinding {
            try setDeviceID(selectedID)
        }
        try verify(selectedDeviceID: selectedID, boundDeviceID: currentDeviceID())
        return needsBinding
    }

    static func verify(selectedDeviceID: UInt32, boundDeviceID: UInt32) throws {
        guard selectedDeviceID != 0, selectedDeviceID == boundDeviceID else {
            throw DictationInputDeviceBindingError.selectedDeviceNotBound
        }
    }
}
