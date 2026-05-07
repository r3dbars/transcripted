import AudioToolbox
@preconcurrency import AVFoundation
import Foundation

public enum MeetingAudioTransport: String {
    case builtIn
    case bluetooth
    case bluetoothLE
    case usb
    case aggregate
    case virtual
    case other
}

public struct MeetingAudioDevice: Equatable {
    public let id: AudioDeviceID
    public let name: String
    public let transport: MeetingAudioTransport
    public let inputChannelCount: UInt32

    public init(
        id: AudioDeviceID,
        name: String,
        transport: MeetingAudioTransport,
        inputChannelCount: UInt32
    ) {
        self.id = id
        self.name = name
        self.transport = transport
        self.inputChannelCount = inputChannelCount
    }
}

public enum MeetingInputDeviceSelectionReason: String {
    case defaultIsSafe
    case preferredBuiltInForBluetoothHeadset
    case noBuiltInFallbackAvailable
}

public struct MeetingInputDeviceSelection: Equatable {
    public let defaultInput: MeetingAudioDevice
    public let selectedInput: MeetingAudioDevice
    public let defaultOutput: MeetingAudioDevice?
    public let reason: MeetingInputDeviceSelectionReason

    public var didOverrideDefault: Bool {
        selectedInput.id != defaultInput.id
    }

    public init(
        defaultInput: MeetingAudioDevice,
        selectedInput: MeetingAudioDevice,
        defaultOutput: MeetingAudioDevice?,
        reason: MeetingInputDeviceSelectionReason
    ) {
        self.defaultInput = defaultInput
        self.selectedInput = selectedInput
        self.defaultOutput = defaultOutput
        self.reason = reason
    }
}

public enum MeetingInputDeviceSelectionPolicy {
    public static func selection(
        defaultInput: MeetingAudioDevice,
        defaultOutput: MeetingAudioDevice?,
        availableInputs: [MeetingAudioDevice]
    ) -> MeetingInputDeviceSelection {
        guard shouldAvoidBluetoothHeadsetInput(defaultInput, defaultOutput: defaultOutput) else {
            return MeetingInputDeviceSelection(
                defaultInput: defaultInput,
                selectedInput: defaultInput,
                defaultOutput: defaultOutput,
                reason: .defaultIsSafe
            )
        }

        guard let builtInInput = preferredBuiltInInput(from: availableInputs, defaultInput: defaultInput) else {
            return MeetingInputDeviceSelection(
                defaultInput: defaultInput,
                selectedInput: defaultInput,
                defaultOutput: defaultOutput,
                reason: .noBuiltInFallbackAvailable
            )
        }

        return MeetingInputDeviceSelection(
            defaultInput: defaultInput,
            selectedInput: builtInInput,
            defaultOutput: defaultOutput,
            reason: .preferredBuiltInForBluetoothHeadset
        )
    }

    public static func deviceClass(for device: MeetingAudioDevice) -> String {
        deviceClass(forName: device.name, transport: device.transport)
    }

    public static func deviceClass(
        forName deviceName: String,
        transport: MeetingAudioTransport = .other
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
        _ defaultInput: MeetingAudioDevice,
        defaultOutput: MeetingAudioDevice?
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
        from availableInputs: [MeetingAudioDevice],
        defaultInput: MeetingAudioDevice
    ) -> MeetingAudioDevice? {
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

    private static func builtInInputRank(_ device: MeetingAudioDevice) -> Int {
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

    private static func isBluetoothHeadsetInput(_ device: MeetingAudioDevice) -> Bool {
        isBluetoothTransport(device.transport) || isBluetoothHeadsetName(normalize(device.name))
    }

    private static func isBluetoothAudioDevice(_ device: MeetingAudioDevice) -> Bool {
        isBluetoothTransport(device.transport) || isBluetoothHeadsetName(normalize(device.name))
    }

    private static func isBluetoothTransport(_ transport: MeetingAudioTransport) -> Bool {
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

#if !TRANSCRIPTED_FAST_TESTS
private enum MeetingInputDeviceLookup {
    static func preferredInputSelection() throws -> MeetingInputDeviceSelection {
        let defaultInputID = try AudioObjectID.readDefaultInputDevice()
        var availableInputs = try allInputDevices()

        let defaultInput: MeetingAudioDevice
        if let existingDefault = availableInputs.first(where: { $0.id == defaultInputID }) {
            defaultInput = existingDefault
        } else {
            defaultInput = try deviceDescriptor(for: defaultInputID, inputChannelCount: 1)
            availableInputs.append(defaultInput)
        }

        let defaultOutput = try? deviceDescriptor(
            for: AudioObjectID.readDefaultOutputDevice(),
            inputChannelCount: 0
        )

        return MeetingInputDeviceSelectionPolicy.selection(
            defaultInput: defaultInput,
            defaultOutput: defaultOutput,
            availableInputs: availableInputs
        )
    }

    private static func allInputDevices() throws -> [MeetingAudioDevice] {
        try allDeviceIDs().compactMap { deviceID in
            let inputChannels = (try? channelCount(for: deviceID, scope: kAudioDevicePropertyScopeInput)) ?? 0
            guard inputChannels > 0 else { return nil }
            return try? deviceDescriptor(for: deviceID, inputChannelCount: inputChannels)
        }
    }

    private static func allDeviceIDs() throws -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0

        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID.system,
            &address,
            0,
            nil,
            &dataSize
        )
        guard status == noErr else {
            throw NSError(domain: "MeetingInputDeviceLookup", code: Int(status))
        }

        var devices = [AudioDeviceID](
            repeating: AudioDeviceID.unknown,
            count: Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        )

        status = AudioObjectGetPropertyData(
            AudioObjectID.system,
            &address,
            0,
            nil,
            &dataSize,
            &devices
        )
        guard status == noErr else {
            throw NSError(domain: "MeetingInputDeviceLookup", code: Int(status))
        }

        return devices.filter(\.isValid)
    }

    private static func deviceDescriptor(
        for deviceID: AudioDeviceID,
        inputChannelCount: UInt32
    ) throws -> MeetingAudioDevice {
        let name = (try? deviceID.readString(kAudioDevicePropertyDeviceNameCFString)) ?? ""
        let transport = (try? deviceID.readTransportType()).map(transportType) ?? .other

        return MeetingAudioDevice(
            id: deviceID,
            name: name.isEmpty ? "Unknown" : name,
            transport: transport,
            inputChannelCount: inputChannelCount
        )
    }

    private static func channelCount(
        for deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope
    ) throws -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0

        var status = AudioObjectGetPropertyDataSize(
            deviceID,
            &address,
            0,
            nil,
            &dataSize
        )
        guard status == noErr else {
            throw NSError(domain: "MeetingInputDeviceLookup", code: Int(status))
        }
        guard dataSize > 0 else { return 0 }

        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPointer.deallocate() }

        status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            rawPointer
        )
        guard status == noErr else {
            throw NSError(domain: "MeetingInputDeviceLookup", code: Int(status))
        }

        let bufferList = rawPointer.bindMemory(to: AudioBufferList.self, capacity: 1)
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        return buffers.reduce(UInt32(0)) { total, buffer in
            total + buffer.mNumberChannels
        }
    }

    private static func transportType(_ rawValue: UInt32) -> MeetingAudioTransport {
        switch rawValue {
        case kAudioDeviceTransportTypeBuiltIn:
            return .builtIn
        case kAudioDeviceTransportTypeBluetooth:
            return .bluetooth
        case kAudioDeviceTransportTypeBluetoothLE:
            return .bluetoothLE
        case kAudioDeviceTransportTypeUSB:
            return .usb
        case kAudioDeviceTransportTypeAggregate:
            return .aggregate
        case kAudioDeviceTransportTypeVirtual:
            return .virtual
        default:
            return .other
        }
    }
}

extension Audio {
    func applyPreferredMeetingInputDevice(
        to inputNode: AVAudioInputNode,
        operation: String
    ) {
        let selection: MeetingInputDeviceSelection
        do {
            selection = try MeetingInputDeviceLookup.preferredInputSelection()
        } catch {
            AppLogger.audioMic.warning("Meeting input selection unavailable", [
                "operation": operation,
                "error": error.localizedDescription
            ])
            return
        }

        guard inputNode.auAudioUnit.deviceID != selection.selectedInput.id else {
            if selection.didOverrideDefault {
                AppLogger.audioMic.info("Meeting input already using preferred microphone", [
                    "operation": operation,
                    "reason": selection.reason.rawValue,
                    "defaultTransport": selection.defaultInput.transport.rawValue,
                    "selectedTransport": selection.selectedInput.transport.rawValue
                ])
            }
            return
        }

        do {
            try inputNode.auAudioUnit.setDeviceID(selection.selectedInput.id)
            let message = selection.didOverrideDefault
                ? "Meeting input changed away from Bluetooth headset microphone"
                : "Meeting input synced to selected microphone"
            AppLogger.audioMic.info(message, [
                "operation": operation,
                "reason": selection.reason.rawValue,
                "defaultTransport": selection.defaultInput.transport.rawValue,
                "selectedTransport": selection.selectedInput.transport.rawValue
            ])
        } catch {
            AppLogger.audioMic.warning("Meeting input override failed", [
                "operation": operation,
                "reason": selection.reason.rawValue,
                "error": error.localizedDescription
            ])
        }
    }
}
#endif
