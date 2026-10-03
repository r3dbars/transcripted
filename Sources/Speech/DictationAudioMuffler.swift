// DictationAudioMuffler.swift
// Makes other apps' audio sound muffled while the dictation mic is open.
//
// How: a private process tap on the default output device (every process
// but ours) with `.mutedWhenTapped`, so the apps go quiet only while we are
// reading the tap. Apps playing to other devices are not tapped at all.
// The tap and the current output device share one private aggregate; its
// IOProc reads the tap, runs DictationMuffleFilter, and writes the result
// straight to the output. One device clock, no ring buffer, a single IO cycle
// of added latency.
//
// Failure is always "audio sounds normal". If the IOProc stops, the process
// quits or crashes, or the output changes, macOS unmutes the apps because
// nothing is reading the tap any more.
//
// Bluetooth: an output device that has an input stream is refused by
// DictationMuffleOutputRoute before anything is built, because starting the
// aggregate would start that input stream and flip a headset into call mode.
// On macOS 26 AirPods expose an output-only device and a separate mic, so the
// output is allowed and the mic is never started. As a backstop, if the
// output's sample rate changes mid-take (what call mode looks like from
// here), muffle stops at once. The dictation mic itself is not involved here
// at all, so a Bluetooth headset as the default *input* is unaffected: no
// AVAudioEngine, no inputNode, no input device is opened by this file.
//
// Threading: every HAL call happens on `queue`; all mutable state is confined
// to it. The IO thread only touches the render context (an atomic flag and a
// preallocated filter).

import CoreAudio
import Foundation
import Synchronization
import TranscriptedCore

private final class DictationMuffleRenderContext {
    let muffled = Atomic<Bool>(true)
    let filter: UnsafeMutablePointer<DictationMuffleFilter>

    init(sampleRate: Double) {
        filter = .allocate(capacity: 1)
        filter.initialize(to: DictationMuffleFilter(sampleRate: sampleRate))
    }

    deinit {
        filter.deinitialize(count: 1)
        filter.deallocate()
    }
}

final class DictationAudioMuffler: @unchecked Sendable {
    static let shared = DictationAudioMuffler()

    private let queue = DispatchQueue(label: "com.transcripted.dictation-muffle", qos: .userInitiated)

    // Queue-confined state.
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    private var context: Unmanaged<DictationMuffleRenderContext>?
    private var outputListener: AudioObjectPropertyListenerBlock?
    private var rateListener: AudioObjectPropertyListenerBlock?
    private var rateListenerDevice = AudioObjectID(kAudioObjectUnknown)
    private var releaseGeneration = 0

    private static let nominalSampleRateAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private static let defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    /// Starts muffling, or cancels a fade-out still in progress. Returns
    /// immediately; never blocks the mic start. The System Audio Recording
    /// preflight is an XPC round trip to tccd, so it runs here on `queue`
    /// rather than on main while the mic is opening.
    func engage(
        enabled: Bool,
        meetingRecording: Bool,
        dictatingFromSharedMeetingMic: Bool,
        voiceProcessingRequested: Bool
    ) {
        queue.async {
            let decision = DictationMufflePolicy.decision(
                enabled: enabled,
                systemAudioAuthorized: enabled
                    && TranscriptedPermissionAccess.refreshSystemAudioRecordingStatusFromSystem() == .authorized,
                meetingRecording: meetingRecording,
                dictatingFromSharedMeetingMic: dictatingFromSharedMeetingMic,
                voiceProcessingRequested: voiceProcessingRequested,
                automatedLaunch: AutomatedLaunchEnvironment.isActive()
            )
            guard decision == .muffle else { return }
            self.engageOnQueue()
        }
    }

    /// Fades back to normal, then tears the tap down.
    func release() {
        queue.async { self.releaseOnQueue() }
    }

    // MARK: - Queue

    private func engageOnQueue() {
        releaseGeneration += 1
        if let context, device != kAudioObjectUnknown {
            context.takeUnretainedValue().muffled.store(true, ordering: .relaxed)
            return
        }
        guard Self.anotherProcessIsPlayingAudio(excluding: getpid()) else { return }
        do {
            try build()
            AppLogger.transcription.info("DICTATION | muffling other audio")
        } catch let failure as BuildFailure {
            teardown()
            AppLogger.transcription.info("DICTATION | muffle skipped", ["reason": failure.reason])
        } catch {
            teardown()
        }
    }

    private func releaseOnQueue() {
        guard let context, device != kAudioObjectUnknown else { return }
        context.takeUnretainedValue().muffled.store(false, ordering: .relaxed)
        releaseGeneration += 1
        let generation = releaseGeneration
        // Let the filter fade back to full range before the apps unmute, so the
        // handoff is a crossfade and not a jump.
        queue.asyncAfter(deadline: .now() + DictationMuffleFilter.rampSeconds + 0.08) { [weak self] in
            guard let self, self.releaseGeneration == generation else { return }
            self.teardown()
        }
    }

    private struct BuildFailure: Error {
        let reason: String
    }

    private func build() throws {
        // Listen before reading the default output, so a switch that lands
        // while this builds still tears the build down once it finishes.
        installOutputListener()
        let output = try Self.defaultOutputDevice()
        let transport = Self.transport(of: output)
        let inputStreams = Self.streamCount(of: output, scope: kAudioObjectPropertyScopeInput)
        let outputChannels = Self.channelCount(of: output, scope: kAudioObjectPropertyScopeOutput)
        if let ineligible = DictationMuffleOutputRoute.ineligibility(
            transport: transport,
            inputStreamCount: inputStreams,
            outputChannelCount: outputChannels
        ) {
            throw BuildFailure(reason: ineligible.rawValue)
        }
        guard let outputUID = Self.stringProperty(kAudioDevicePropertyDeviceUID, of: output) else {
            throw BuildFailure(reason: "output_uid")
        }
        installRateListener(on: output)

        var pid = getpid()
        var process = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &process
        ) == noErr, process != kAudioObjectUnknown else {
            throw BuildFailure(reason: "own_process")
        }

        // Scoped to the default output's first stream, not global: an app
        // pinned to another device (a call on a USB headset, a DAW on an
        // interface) must keep playing where it was, untouched.
        let description = CATapDescription(excludingProcesses: [process], deviceUID: outputUID, stream: 0)
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        guard AudioHardwareCreateProcessTap(description, &tap) == noErr, tap != kAudioObjectUnknown else {
            tap = AudioObjectID(kAudioObjectUnknown)
            throw BuildFailure(reason: "tap")
        }

        let properties: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Transcripted Dictation Muffle",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true
            ]]
        ]
        guard AudioHardwareCreateAggregateDevice(properties as CFDictionary, &device) == noErr,
              device != kAudioObjectUnknown else {
            device = AudioObjectID(kAudioObjectUnknown)
            throw BuildFailure(reason: "aggregate")
        }

        let sampleRate = Self.nominalSampleRate(of: device)
        let context = Unmanaged.passRetained(DictationMuffleRenderContext(sampleRate: sampleRate))
        let status = AudioDeviceCreateIOProcID(device, { _, _, input, _, output, _, clientData in
            guard let clientData else { return noErr }
            let context = Unmanaged<DictationMuffleRenderContext>.fromOpaque(clientData).takeUnretainedValue()
            let target: Float = context.muffled.load(ordering: .relaxed) ? 1 : 0
            context.filter.pointee.render(input: input, output: output, target: target)
            return noErr
        }, context.toOpaque(), &proc)
        guard status == noErr, proc != nil else {
            context.release()
            proc = nil
            throw BuildFailure(reason: "ioproc")
        }
        self.context = context

        guard AudioDeviceStart(device, proc) == noErr else {
            throw BuildFailure(reason: "start")
        }
    }

    /// Order matters: stop and detach the IOProc before freeing its context,
    /// then the aggregate, then the tap. If HAL refuses to destroy the IOProc,
    /// leak the context rather than free memory the IO thread may still read.
    private func teardown() {
        removeOutputListener()
        removeRateListener()
        if let proc, device != kAudioObjectUnknown {
            AudioDeviceStop(device, proc)
            let status = AudioDeviceDestroyIOProcID(device, proc)
            if status == noErr { context?.release() }
        } else {
            context?.release()
        }
        proc = nil
        context = nil
        if device != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(device)
            device = AudioObjectID(kAudioObjectUnknown)
        }
        if tap != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tap)
            tap = AudioObjectID(kAudioObjectUnknown)
        }
    }

    /// The aggregate is pinned to the output that was default at start. If the
    /// user switches outputs mid-take, stop muffling rather than keep playing
    /// to the old device.
    private func installOutputListener() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.device != kAudioObjectUnknown else { return }
            self.releaseGeneration += 1
            self.teardown()
            AppLogger.transcription.info("DICTATION | muffle stopped", ["reason": "output_changed"])
        }
        var address = Self.defaultOutputAddress
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener) == noErr {
            outputListener = listener
        }
    }

    /// A rate change on the output mid-take means something re-clocked it:
    /// most likely a Bluetooth headset dropping into call mode, or another app
    /// changing the rate. Either way the filter was tuned for the old rate
    /// and the route is no longer the one that was checked, so let the apps
    /// play normally again.
    private func installRateListener(on output: AudioObjectID) {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.device != kAudioObjectUnknown else { return }
            self.releaseGeneration += 1
            self.teardown()
            AppLogger.transcription.info("DICTATION | muffle stopped", ["reason": "output_rate_changed"])
        }
        var address = Self.nominalSampleRateAddress
        if AudioObjectAddPropertyListenerBlock(output, &address, queue, listener) == noErr {
            rateListener = listener
            rateListenerDevice = output
        }
    }

    private func removeRateListener() {
        guard let rateListener else { return }
        var address = Self.nominalSampleRateAddress
        AudioObjectRemovePropertyListenerBlock(rateListenerDevice, &address, queue, rateListener)
        self.rateListener = nil
        rateListenerDevice = AudioObjectID(kAudioObjectUnknown)
    }

    private func removeOutputListener() {
        guard let outputListener else { return }
        var address = Self.defaultOutputAddress
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, outputListener)
        self.outputListener = nil
    }

    // MARK: - HAL reads

    private static func defaultOutputDevice() throws -> AudioObjectID {
        var address = defaultOutputAddress
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else {
            throw BuildFailure(reason: "no_output")
        }
        return device
    }

    private static func transport(of device: AudioObjectID) -> DictationMuffleOutputTransport {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return .unknown }
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

    private static func streamCount(of device: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }

    private static func channelCount(of device: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(_ selector: AudioObjectPropertySelector, of device: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func nominalSampleRate(of device: AudioObjectID) -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr, rate > 0 else {
            return 48_000
        }
        return rate
    }

    /// True when any other process is running audio output. Read-only; with
    /// nothing playing there is nothing to muffle, so no tap is built.
    private static func anotherProcessIsPlayingAudio(excluding ownPID: pid_t) -> Bool {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var listAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &listAddress, 0, nil, &size) == noErr, size > 0 else { return false }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &listAddress, 0, nil, &size, &processes) == noErr else { return false }
        for process in processes.prefix(Int(size) / MemoryLayout<AudioObjectID>.size) {
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            var runningAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningOutput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectGetPropertyData(process, &runningAddress, 0, nil, &runningSize, &running) == noErr,
                  running != 0 else { continue }
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            if AudioObjectGetPropertyData(process, &pidAddress, 0, nil, &pidSize, &pid) == noErr, pid == ownPID { continue }
            return true
        }
        return false
    }
}
