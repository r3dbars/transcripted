import AudioToolbox
@preconcurrency import AVFoundation
import Foundation

enum MeetingInputDeviceLookup {
    /// `excludingDeviceID` drops a mic that just died or went silent from
    /// the candidates (the default stays, since it may be all that's left).
    static func preferredInputSelection(
        mode: MeetingInputDeviceSelectionMode,
        preferredInputUID: String? = nil,
        excludingDeviceID: AudioDeviceID? = nil
    ) throws -> MeetingInputDeviceSelection {
        let defaultInputID = try AudioObjectID.readDefaultInputDevice()
        var availableInputs = try allInputDevices()
        if let excludingDeviceID, excludingDeviceID != defaultInputID {
            availableInputs.removeAll { $0.id == excludingDeviceID }
        }

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

        // An excluded chosen mic is already gone from the candidates, so a
        // replacement lands on the automatic pick.
        let preferredInputID = preferredInputUID.flatMap { uid in
            availableInputs.first { (try? $0.id.readString(kAudioDevicePropertyDeviceUID)) == uid }?.id
        }

        return MeetingInputDeviceSelectionPolicy.selectionForMeetingStart(
            defaultInput: defaultInput,
            defaultOutput: defaultOutput,
            availableInputs: availableInputs,
            mode: mode,
            preferredInputID: preferredInputID,
            lidClosed: MacLidState.isClosed()
        )
    }

    static func builtInFallbackAfterFailure(
        failedInputID: AudioDeviceID?
    ) throws -> MeetingInputDeviceSelection? {
        let defaultInputID = try AudioObjectID.readDefaultInputDevice()
        let availableInputs = try allInputDevices()
        let defaultInput = try availableInputs.first(where: { $0.id == defaultInputID })
            ?? deviceDescriptor(for: defaultInputID, inputChannelCount: 1)
        let defaultOutput = try? deviceDescriptor(
            for: AudioObjectID.readDefaultOutputDevice(),
            inputChannelCount: 0
        )
        return MeetingInputDeviceSelectionPolicy.builtInFallbackAfterFailure(
            failedInputID: failedInputID ?? defaultInputID,
            defaultInput: defaultInput,
            defaultOutput: defaultOutput,
            availableInputs: availableInputs,
            lidClosed: MacLidState.isClosed()
        )
    }

    static func preferredBuiltInFallback(
        for selectedInput: MeetingAudioDevice
    ) throws -> MeetingAudioDevice? {
        MeetingInputDeviceSelectionPolicy.preferredBuiltInFallback(
            for: selectedInput,
            availableInputs: try allInputDevices(),
            lidClosed: MacLidState.isClosed()
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
