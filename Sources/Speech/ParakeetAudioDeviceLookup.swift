import CoreAudio
import Foundation

extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

private enum InputDeviceLookupError: Error {
    case propertyReadFailed(OSStatus)
    case unknownDevice
}

enum ParakeetAudioEngineWorkError: LocalizedError {
    case timedOut(operation: String, timeoutMs: Int)

    var errorDescription: String? {
        switch self {
        case .timedOut(let operation, let timeoutMs):
            return "Audio engine \(operation) timed out after \(timeoutMs)ms"
        }
    }
}

enum CoreAudioInputDeviceLookup {
    static func preferredDictationInputSelection() throws -> DictationInputDeviceSelection {
        let defaultInputID = try defaultInputDeviceID()
        var availableInputs = try allInputDevices()

        let defaultInput: DictationAudioDevice
        if let existingDefault = availableInputs.first(where: { $0.id == defaultInputID }) {
            defaultInput = existingDefault
        } else {
            defaultInput = try deviceDescriptor(for: defaultInputID, inputChannelCount: 1)
            availableInputs.append(defaultInput)
        }

        let defaultOutput = try? deviceDescriptor(for: defaultOutputDeviceID(), inputChannelCount: 0)

        return DictationInputDeviceSelectionPolicy.selection(
            defaultInput: defaultInput,
            defaultOutput: defaultOutput,
            availableInputs: availableInputs
        )
    }

    private static func allInputDevices() throws -> [DictationAudioDevice] {
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
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        )
        guard status == noErr else {
            throw InputDeviceLookupError.propertyReadFailed(status)
        }

        var devices = [AudioDeviceID](
            repeating: AudioDeviceID(kAudioObjectUnknown),
            count: Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        )

        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &devices
        )

        guard status == noErr else {
            throw InputDeviceLookupError.propertyReadFailed(status)
        }

        return devices.filter { $0 != AudioDeviceID(kAudioObjectUnknown) }
    }

    private static func deviceDescriptor(
        for deviceID: AudioDeviceID,
        inputChannelCount: UInt32
    ) throws -> DictationAudioDevice {
        let name = try readStringProperty(
            selector: kAudioDevicePropertyDeviceNameCFString,
            objectID: AudioObjectID(deviceID)
        )
        let transport = (try? readUInt32Property(
            selector: kAudioDevicePropertyTransportType,
            objectID: AudioObjectID(deviceID)
        )).map(transportType) ?? .other

        return DictationAudioDevice(
            id: deviceID,
            name: name.isEmpty ? "Unknown" : name,
            transport: transport,
            inputChannelCount: inputChannelCount
        )
    }

    private static func defaultInputDeviceID() throws -> AudioDeviceID {
        try defaultDeviceID(selector: kAudioHardwarePropertyDefaultInputDevice)
    }

    private static func defaultOutputDeviceID() throws -> AudioDeviceID {
        try defaultDeviceID(selector: kAudioHardwarePropertyDefaultOutputDevice)
    }

    private static func defaultDeviceID(selector: AudioObjectPropertySelector) throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )

        guard status == noErr else {
            throw InputDeviceLookupError.propertyReadFailed(status)
        }
        guard deviceID != AudioDeviceID(kAudioObjectUnknown) else {
            throw InputDeviceLookupError.unknownDevice
        }

        return deviceID
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
            AudioObjectID(deviceID),
            &address,
            0,
            nil,
            &dataSize
        )
        guard status == noErr else {
            throw InputDeviceLookupError.propertyReadFailed(status)
        }
        guard dataSize > 0 else { return 0 }

        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPointer.deallocate() }

        status = AudioObjectGetPropertyData(
            AudioObjectID(deviceID),
            &address,
            0,
            nil,
            &dataSize,
            rawPointer
        )
        guard status == noErr else {
            throw InputDeviceLookupError.propertyReadFailed(status)
        }

        let bufferList = rawPointer.bindMemory(to: AudioBufferList.self, capacity: 1)
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        return buffers.reduce(UInt32(0)) { total, buffer in
            total + buffer.mNumberChannels
        }
    }

    private static func readStringProperty(
        selector: AudioObjectPropertySelector,
        objectID: AudioObjectID
    ) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<CFString>.size)

        let status = withUnsafeMutablePointer(to: &value) { valuePointer in
            AudioObjectGetPropertyData(
                objectID,
                &address,
                0,
                nil,
                &dataSize,
                UnsafeMutableRawPointer(valuePointer)
            )
        }

        guard status == noErr else {
            throw InputDeviceLookupError.propertyReadFailed(status)
        }

        return (value?.takeUnretainedValue() as String?) ?? ""
    }

    private static func readUInt32Property(
        selector: AudioObjectPropertySelector,
        objectID: AudioObjectID
    ) throws -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)

        let status = AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &dataSize,
            &value
        )

        guard status == noErr else {
            throw InputDeviceLookupError.propertyReadFailed(status)
        }

        return value
    }

    private static func transportType(_ rawValue: UInt32) -> DictationAudioTransport {
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
