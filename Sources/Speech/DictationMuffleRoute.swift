// DictationMuffleRoute.swift
// The Core Audio objects behind one muffled dictation take. Two taps on the
// processes playing to the default output:
//
// - Tap A (unmuted) feeds the copy. It lives in a private aggregate whose
//   main sub-device is the output; the aggregate's IOProc filters the tap and
//   writes the copy straight to the output. It runs silent and dry until the
//   cut, so starting it changes nothing anyone hears.
// - Tap B (.mutedWhenTapped) does nothing but mute. It lives in a tap-only
//   private aggregate with a no-op IOProc that stays stopped until the cut.
//   Starting it mutes the originals within a few milliseconds; stopping it
//   unmutes them at once.
//
// Why two taps: changing a running tap's mute behavior makes coreaudiod
// re-register the tap and restart our aggregate's IO, which left a 51-67 ms
// hole right at the cut (the start hitch). A tap muted from creation mutes at
// IO start, before the copy can play: a 26-30 ms gap. A second tap that only
// mutes cut cleanly in every lab run and never disturbed tap A.
//
// Both taps include only the processes playing to this output when the take
// starts (DictationMuffleHAL.processesPlaying), so nothing else is muted,
// apps that are also using a mic (calls) stay clear, and an app that starts
// playing mid-take plays normally rather than doubled.
//
// Failure is always "audio sounds normal". Tap B mutes only while its
// aggregate runs, so if the process quits or crashes, macOS unmutes the apps
// by itself. If the copy's aggregate stops on its own while tap B still
// runs, a listener closes the route, which stops tap B first.
//
// Bluetooth: the route is only built for outputs with no input streams
// (DictationMuffleOutputRoute), so starting the aggregate never starts a
// headset's mic and never flips AirPods into call mode. No input device,
// AVAudioEngine or inputNode is opened here; a Bluetooth headset as the
// default input is unaffected.
//
// Threading: created, driven and closed on the muffler's serial queue. The
// IO threads only touch DictationMuffleRenderState.

import CoreAudio
import Foundation
import Synchronization

/// The only state the copy's IO thread touches: three atomics, two counters
/// and a preallocated filter.
final class DictationMuffleRenderState {
    /// Below this input peak a cycle counts as quiet (-40 dBFS).
    static let quietPeak: Float = 0.01

    let gateOpen = Atomic<Bool>(false)
    let muffled = Atomic<Bool>(false)
    let soundFlowing = Atomic<Bool>(false)
    let quietFrames = Atomic<Int>(0)
    /// outputTime - inputTime (sample frames) on the first cycle with sound.
    let rawDelayFrames = Atomic<Int>(Int.min)
    let filter: UnsafeMutablePointer<DictationMuffleFilter>

    init(sampleRate: Double) {
        filter = .allocate(capacity: 1)
        filter.initialize(to: DictationMuffleFilter(sampleRate: sampleRate, startGated: true))
    }

    deinit {
        filter.deinitialize(count: 1)
        filter.deallocate()
    }
}

/// The copy's IOProc: tap in, filtered copy out. No allocation, locks or ObjC.
private let dictationMuffleCopyIOProc: AudioDeviceIOProc = { _, _, input, inputTime, output, outputTime, clientData in
    guard let clientData else { return noErr }
    let state = Unmanaged<DictationMuffleRenderState>.fromOpaque(clientData).takeUnretainedValue()
    let peak = state.filter.pointee.render(
        input: input,
        output: output,
        muffleTarget: state.muffled.load(ordering: .relaxed) ? 1 : 0,
        gateTarget: state.gateOpen.load(ordering: .relaxed) ? 1 : 0
    )
    if peak > 0, !state.soundFlowing.load(ordering: .relaxed) {
        if inputTime.pointee.mFlags.contains(.sampleTimeValid),
           outputTime.pointee.mFlags.contains(.sampleTimeValid) {
            let delta = outputTime.pointee.mSampleTime - inputTime.pointee.mSampleTime
            if delta.isFinite, abs(delta) < 1_000_000 {
                state.rawDelayFrames.store(Int(delta), ordering: .relaxed)
            }
        }
        state.soundFlowing.store(true, ordering: .releasing)
    }
    let firstBuffer = output.pointee.mBuffers
    let channels = Int(max(1, firstBuffer.mNumberChannels))
    let frames = Int(firstBuffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
    if peak < DictationMuffleRenderState.quietPeak {
        state.quietFrames.wrappingAdd(frames, ordering: .relaxed)
    } else {
        state.quietFrames.store(0, ordering: .relaxed)
    }
    return noErr
}

/// Tap B's IOProc: reading the tap is what mutes; there is nothing to do.
private let dictationMuffleCutIOProc: AudioDeviceIOProc = { _, _, _, _, _, _, _ in noErr }

final class DictationMuffleRoute {
    struct Plan {
        let output: AudioObjectID
        let outputUID: String
        let bluetooth: Bool
        let processes: [AudioObjectID]
    }

    struct OpenFailure: Error {
        let step: String
    }

    /// The copy's IO buffer. The copy lags the original by about
    /// buffer x 2 + 81 + drift latency frames (lab, built-in speakers): ~7 ms
    /// here vs ~24 ms at the default 512. The setting is per process, so
    /// other apps keep their own.
    static let copyBufferFrames: UInt32 = 128
    /// Drift compensation latency at quality 0 (lab-measured; 48 at default
    /// quality). The tap and the output share one clock, so the cheapest
    /// quality is enough.
    static let driftLatencyFrames = 8

    let bluetooth: Bool
    let processCount: Int
    private(set) var copyBufferFrames = 0

    private let output: AudioObjectID
    private let queue: DispatchQueue
    private let onLost: (String) -> Void
    private var sampleRate: Double = 48_000
    private var delayCorrectionFrames = 0

    private var copyTap = AudioObjectID(kAudioObjectUnknown)
    private var copyDevice = AudioObjectID(kAudioObjectUnknown)
    private var copyProc: AudioDeviceIOProcID?
    private var copyRunning = false
    private var state: Unmanaged<DictationMuffleRenderState>?

    private var cutTap = AudioObjectID(kAudioObjectUnknown)
    private var cutDevice = AudioObjectID(kAudioObjectUnknown)
    private var cutProc: AudioDeviceIOProcID?
    private var cutRunning = false

    private var listeners: [(object: AudioObjectID, address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []

    private init(plan: Plan, queue: DispatchQueue, onLost: @escaping (String) -> Void) {
        bluetooth = plan.bluetooth
        processCount = plan.processes.count
        output = plan.output
        self.queue = queue
        self.onLost = onLost
    }

    /// Builds both taps and aggregates and starts the silent copy. Throws (and
    /// leaves nothing behind) if any step fails.
    static func open(
        _ plan: Plan,
        queue: DispatchQueue,
        onLost: @escaping (String) -> Void
    ) throws -> DictationMuffleRoute {
        let route = DictationMuffleRoute(plan: plan, queue: queue, onLost: onLost)
        do {
            try route.build(plan)
        } catch {
            route.close()
            throw error
        }
        return route
    }

    /// What the copy's IO thread has seen so far.
    func signals() -> DictationMuffleSignals {
        guard let state else { return .none }
        let render = state.takeUnretainedValue()
        let flowing = render.soundFlowing.load(ordering: .acquiring)
        let quiet = render.quietFrames.load(ordering: .relaxed) >= Int(sampleRate * 0.03)
        return DictationMuffleSignals(soundFlowing: flowing, quiet: quiet, copyDelayNanos: copyDelayNanos)
    }

    /// How far the copy lags the original: the IOProc's output-minus-input
    /// time, corrected by the aggregate's input safety offset and latency and
    /// the drift compensator. Matched the measured delay exactly in the lab.
    var copyDelayNanos: UInt64? {
        guard let state else { return nil }
        let raw = state.takeUnretainedValue().rawDelayFrames.load(ordering: .relaxed)
        guard raw != Int.min else { return nil }
        let frames = max(0, raw + delayCorrectionFrames)
        return UInt64(Double(frames) / sampleRate * 1_000_000_000)
    }

    /// Opens the copy's gate and mutes the originals in the same step.
    /// Returns false (and leaves the originals playing) if the mute can't
    /// start.
    func cut() -> Bool {
        guard let state, let cutProc else { return false }
        state.takeUnretainedValue().gateOpen.store(true, ordering: .relaxed)
        guard AudioDeviceStart(cutDevice, cutProc) == noErr else {
            state.takeUnretainedValue().gateOpen.store(false, ordering: .relaxed)
            return false
        }
        cutRunning = true
        return true
    }

    func setMuffled(_ muffled: Bool) {
        state?.takeUnretainedValue().muffled.store(muffled, ordering: .relaxed)
    }

    /// Unmutes the originals and closes the copy's gate. The originals come
    /// back first, so the copy fades out over them instead of leaving a gap.
    func handBack() {
        stopCut()
        state?.takeUnretainedValue().gateOpen.store(false, ordering: .relaxed)
    }

    /// Stops and destroys everything, unmuting first. Safe to call twice.
    /// If the HAL refuses to destroy the copy's IOProc, its state is leaked
    /// rather than freed under a running IO thread.
    func close() {
        for listener in listeners {
            var address = listener.address
            AudioObjectRemovePropertyListenerBlock(listener.object, &address, queue, listener.block)
        }
        listeners.removeAll()

        stopCut()
        if let cutProc, cutDevice != kAudioObjectUnknown {
            AudioDeviceDestroyIOProcID(cutDevice, cutProc)
        }
        cutProc = nil
        if cutDevice != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(cutDevice)
            cutDevice = AudioObjectID(kAudioObjectUnknown)
        }
        if cutTap != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(cutTap)
            cutTap = AudioObjectID(kAudioObjectUnknown)
        }

        if let copyProc, copyDevice != kAudioObjectUnknown {
            if copyRunning { AudioDeviceStop(copyDevice, copyProc) }
            if AudioDeviceDestroyIOProcID(copyDevice, copyProc) == noErr {
                state?.release()
            }
        }
        copyRunning = false
        copyProc = nil
        state = nil
        if copyDevice != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(copyDevice)
            copyDevice = AudioObjectID(kAudioObjectUnknown)
        }
        if copyTap != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(copyTap)
            copyTap = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // MARK: - Build

    private func build(_ plan: Plan) throws {
        // Listen first, so a change that lands mid-build still closes the route.
        listen(DictationMuffleHAL.systemObject, kAudioHardwarePropertyDefaultOutputDevice, reason: "output_changed")
        listen(DictationMuffleHAL.systemObject, kAudioHardwarePropertyServiceRestarted, reason: "audio_service_restarted")
        // A rate change mid-take means something re-clocked the output (on a
        // Bluetooth headset, most likely call mode); the filter and the
        // checked route no longer hold.
        listen(plan.output, kAudioDevicePropertyNominalSampleRate, reason: "output_rate_changed")
        listen(plan.output, kAudioDevicePropertyDeviceIsAlive, reason: "output_gone")

        let copyDescription = CATapDescription(processes: plan.processes, deviceUID: plan.outputUID, stream: 0)
        copyDescription.uuid = UUID()
        copyDescription.isPrivate = true
        copyDescription.muteBehavior = .unmuted
        guard AudioHardwareCreateProcessTap(copyDescription, &copyTap) == noErr, copyTap != kAudioObjectUnknown else {
            copyTap = AudioObjectID(kAudioObjectUnknown)
            throw OpenFailure(step: "copy_tap")
        }

        let copyProperties: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Transcripted Dictation Muffle",
            kAudioAggregateDeviceUIDKey: "com.transcripted.muffle.copy." + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: plan.outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: plan.outputUID]],
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: copyDescription.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapDriftCompensationQualityKey: 0,
            ]],
        ]
        guard AudioHardwareCreateAggregateDevice(copyProperties as CFDictionary, &copyDevice) == noErr,
              copyDevice != kAudioObjectUnknown else {
            copyDevice = AudioObjectID(kAudioObjectUnknown)
            throw OpenFailure(step: "copy_aggregate")
        }

        setCopyBufferFrames()
        sampleRate = DictationMuffleHAL.float64(copyDevice, kAudioDevicePropertyNominalSampleRate).flatMap { $0 > 0 ? $0 : nil } ?? 48_000
        let inputSafetyOffset = DictationMuffleHAL.uint32(copyDevice, kAudioDevicePropertySafetyOffset, scope: kAudioObjectPropertyScopeInput) ?? 0
        let inputLatency = DictationMuffleHAL.uint32(copyDevice, kAudioDevicePropertyLatency, scope: kAudioObjectPropertyScopeInput) ?? 0
        delayCorrectionFrames = Int(inputLatency) - Int(inputSafetyOffset) + Self.driftLatencyFrames

        let render = Unmanaged.passRetained(DictationMuffleRenderState(sampleRate: sampleRate))
        var proc: AudioDeviceIOProcID?
        guard AudioDeviceCreateIOProcID(copyDevice, dictationMuffleCopyIOProc, render.toOpaque(), &proc) == noErr,
              let proc else {
            render.release()
            throw OpenFailure(step: "copy_ioproc")
        }
        copyProc = proc
        state = render
        guard AudioDeviceStart(copyDevice, proc) == noErr else {
            throw OpenFailure(step: "copy_start")
        }
        copyRunning = true
        // If the copy stops on its own while the originals are muted, the
        // user would hear nothing: close the route (which unmutes) instead.
        listen(copyDevice, kAudioDevicePropertyDeviceIsRunning, reason: "copy_stopped") { [copyDevice] in
            DictationMuffleHAL.uint32(copyDevice, kAudioDevicePropertyDeviceIsRunning) == 0
        }

        // Tap B, built now so the cut is a single AudioDeviceStart. A
        // .mutedWhenTapped tap mutes nothing until its aggregate runs.
        let cutDescription = CATapDescription(processes: plan.processes, deviceUID: plan.outputUID, stream: 0)
        cutDescription.uuid = UUID()
        cutDescription.isPrivate = true
        cutDescription.muteBehavior = .mutedWhenTapped
        guard AudioHardwareCreateProcessTap(cutDescription, &cutTap) == noErr, cutTap != kAudioObjectUnknown else {
            cutTap = AudioObjectID(kAudioObjectUnknown)
            throw OpenFailure(step: "cut_tap")
        }
        let cutProperties: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Transcripted Dictation Muffle Cut",
            kAudioAggregateDeviceUIDKey: "com.transcripted.muffle.cut." + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: cutDescription.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        guard AudioHardwareCreateAggregateDevice(cutProperties as CFDictionary, &cutDevice) == noErr,
              cutDevice != kAudioObjectUnknown else {
            cutDevice = AudioObjectID(kAudioObjectUnknown)
            throw OpenFailure(step: "cut_aggregate")
        }
        var cutProcID: AudioDeviceIOProcID?
        guard AudioDeviceCreateIOProcID(cutDevice, dictationMuffleCutIOProc, nil, &cutProcID) == noErr,
              let cutProcID else {
            throw OpenFailure(step: "cut_ioproc")
        }
        cutProc = cutProcID
    }

    private func setCopyBufferFrames() {
        var range = AudioValueRange()
        var size = UInt32(MemoryLayout<AudioValueRange>.size)
        var rangeAddress = DictationMuffleHAL.address(kAudioDevicePropertyBufferFrameSizeRange)
        var frames = Self.copyBufferFrames
        if AudioObjectGetPropertyData(copyDevice, &rangeAddress, 0, nil, &size, &range) == noErr, range.mMaximum > 0 {
            frames = UInt32(min(max(Double(frames), range.mMinimum), range.mMaximum))
        }
        var address = DictationMuffleHAL.address(kAudioDevicePropertyBufferFrameSize)
        AudioObjectSetPropertyData(copyDevice, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)
        copyBufferFrames = Int(DictationMuffleHAL.uint32(copyDevice, kAudioDevicePropertyBufferFrameSize) ?? 0)
    }

    private func stopCut() {
        guard cutRunning, let cutProc else { return }
        AudioDeviceStop(cutDevice, cutProc)
        cutRunning = false
    }

    /// Route-ending changes are delivered to the muffler on the next queue
    /// turn, never inside the listener itself, so closing (which removes the
    /// listener) can't happen from within its own block.
    private func listen(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        reason: String,
        when condition: (@Sendable () -> Bool)? = nil
    ) {
        let onLost = onLost
        let queue = queue
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            queue.async {
                if let condition, !condition() { return }
                onLost(reason)
            }
        }
        var address = DictationMuffleHAL.address(selector)
        if AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr {
            listeners.append((object, address, block))
        }
    }
}
