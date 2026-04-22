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
}

enum DictationInputDeviceSelectionReason: String {
    case defaultIsSafe
    case preferredBuiltInForBluetoothHeadset
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

enum DictationInputDeviceSelectionPolicy {
    static func selection(
        defaultInput: DictationAudioDevice,
        defaultOutput: DictationAudioDevice?,
        availableInputs: [DictationAudioDevice]
    ) -> DictationInputDeviceSelection {
        guard shouldAvoidBluetoothHeadsetInput(defaultInput, defaultOutput: defaultOutput) else {
            return DictationInputDeviceSelection(
                defaultInput: defaultInput,
                selectedInput: defaultInput,
                defaultOutput: defaultOutput,
                reason: .defaultIsSafe
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

        if transport == .usb
            || normalized.contains("usb")
            || normalized.contains("scarlett")
            || normalized.contains("rode")
            || normalized.contains("shure")
            || normalized.contains("yeti") {
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
        isBluetoothTransport(device.transport) || isBluetoothHeadsetName(normalize(device.name))
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

    private static func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
