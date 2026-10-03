// DictationMuffleHAL.swift
// Small, fail-closed Core Audio reads for the dictation muffle: the default
// output's route facts and which processes are playing to it.
//
// Every reader returns nil (or an empty list) when the HAL read fails, and
// callers treat nil as "refuse". In particular an output whose input-stream
// count can't be read is never used, so a HAL error can't start a headset's
// mic (see DictationMuffleOutputRoute).
//
// Called only from the muffler's serial queue; nothing here runs on the IO
// thread or the main thread.

import CoreAudio
import Foundation

enum DictationMuffleHAL {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var address = address(selector, scope: scope)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func float64(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Float64? {
        var address = address(selector)
        var value: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func objectID(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> AudioObjectID? {
        var address = address(selector)
        var value = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              value != kAudioObjectUnknown else { return nil }
        return value
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func objectList(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                           scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID]? {
        var address = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr else { return nil }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var list = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &list) == noErr else { return nil }
        return Array(list.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    // MARK: - Output route

    static func defaultOutputDevice() -> AudioObjectID? {
        objectID(systemObject, kAudioHardwarePropertyDefaultOutputDevice)
    }

    static func transport(of device: AudioObjectID) -> DictationMuffleOutputTransport {
        guard let value = uint32(device, kAudioDevicePropertyTransportType) else { return .unknown }
        switch value {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeUSB: return .usb
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return .displayLink
        case kAudioDeviceTransportTypeThunderbolt: return .thunderbolt
        case kAudioDeviceTransportTypePCI: return .pci
        case kAudioDeviceTransportTypeFireWire: return .firewire
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        case kAudioDeviceTransportTypeAirPlay: return .airPlay
        case kAudioDeviceTransportTypeVirtual: return .virtual
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: return .aggregate
        default: return .unknown
        }
    }

    /// Number of streams in `scope`, or nil when the read fails.
    static func streamCount(of device: AudioObjectID, scope: AudioObjectPropertyScope) -> Int? {
        var address = address(kAudioDevicePropertyStreams, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else { return nil }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }

    /// Total channels across the streams in `scope`, or nil when the read fails.
    static func channelCount(of device: AudioObjectID, scope: AudioObjectPropertyScope) -> Int? {
        var address = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else { return nil }
        guard size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return nil }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    // MARK: - Processes

    static func ownProcessObject() -> AudioObjectID? {
        var pid = getpid()
        var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var process = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(systemObject, &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &process) == noErr,
              process != kAudioObjectUnknown else { return nil }
        return process
    }

    /// The processes the muffle should take over: running output on `device`,
    /// not us, and not also running input. An app that is using a microphone
    /// is most likely on a call, and a call should stay clear while the user
    /// dictates, so it's left alone (it keeps playing normally).
    ///
    /// One cheap pre-check first: if nothing at all is running IO on the
    /// output, there is nothing to muffle and no process scan happens.
    static func processesPlaying(to device: AudioObjectID, excluding own: AudioObjectID) -> [AudioObjectID] {
        guard uint32(device, kAudioDevicePropertyDeviceIsRunningSomewhere) == 1,
              let processes = objectList(systemObject, kAudioHardwarePropertyProcessObjectList) else { return [] }
        var playing: [AudioObjectID] = []
        for process in processes where process != own {
            guard uint32(process, kAudioProcessPropertyIsRunningOutput) == 1 else { continue }
            guard let devices = objectList(process, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput),
                  devices.contains(device) else { continue }
            if uint32(process, kAudioProcessPropertyIsRunningInput) == 1 { continue }
            playing.append(process)
        }
        return playing
    }
}
