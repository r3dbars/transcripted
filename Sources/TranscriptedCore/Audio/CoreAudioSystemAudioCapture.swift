import Foundation
@preconcurrency import AVFoundation
import Synchronization
import CoreAudio
import Combine

/// A private, global process tap. Requires System Audio Recording Only, never
/// enumerates displays/windows and never requests ScreenCaptureKit access.
/// HAL ownership and the non-realtime consumer are confined to `queue`.
public final class CoreAudioSystemAudioCapture: SystemAudioCaptureEngine, @unchecked Sendable {
    /// Package-internal HAL seam: deterministic tests exercise the same queue,
    /// ring, recovery and stop state machine without touching TCC or devices.
    struct HardwareHooks {
        var prepare: () throws -> AVAudioFormat
        var start: () throws -> Void
        var stop: () -> Void
        var currentFormat: () throws -> AVAudioFormat
        var otherAudioIsPlaying: () -> Bool = { false }
    }
    public let diagnosticBackendName = "core_audio_tap"
    public let deliversOwnedAudioBuffers = true
    private let queue = DispatchQueue(label: "Transcripted.CoreAudioSystemAudioCapture", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<Bool>()
    private let errors = CurrentValueSubject<String?, Never>(nil)
    private let recovery = PassthroughSubject<SystemAudioRecoveryEvent, Never>()
    private var tap: AudioObjectID = 0
    private var device: AudioObjectID = 0
    private var proc: AudioDeviceIOProcID?
    private var ring: CoreAudioTapBufferRing?
    /// The recording's format: fixed at the first tap of a recording, since
    /// the host sizes its WAV from it.
    private var format: AVAudioFormat?
    /// The live tap's format. Differs from `format` after the output route
    /// changed rate mid-recording; `converter` then resamples back.
    private var tapFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var formatReconnects = 0
    static let maxFormatReconnects = 5
    private var callback: ((AVAudioPCMBuffer) -> Void)?
    private var timer: DispatchSourceTimer?
    private var running = false
    private var tearingDown = false
    private var generation: UInt64 = 0
    private var recoveryUsed = false
    private var recoveryStarted: TimeInterval?
    private var sleepPendingSince: TimeInterval?
    /// The tap and aggregate were released for sleep and wait for the wake
    /// reconnect. Nothing stays attached to the output device while asleep.
    private var releasedForSleep = false
    /// Checks for a missing wake notice while the tap is released.
    private var sleepTimer: DispatchSourceTimer?
    /// The tap can come back attached but delivering digital zeros (seen
    /// after a wake with AirPods as the output). Buffers still arrive, so the
    /// stall check never fires; this watch reconnects instead, and reports
    /// when the tap still hears nothing while another app plays.
    private var silenceWatch: SystemAudioSilenceWatch?
    /// Set once the silence watch gives up on a tap that hears nothing while
    /// another app plays; cleared by real signal or the next start. Read
    /// lock-free from the main thread, which must never wait on this queue.
    private let unheardPlayback = Atomic<Bool>(false)
    /// Block registered for default-output changes while recording.
    private var defaultOutputListener: AudioObjectPropertyListenerBlock?
    /// Failed wake/route rebuilds retried since the last delivered buffer.
    private var rebuildRetries = 0
    private var pendingRebuildRetry: (trigger: RecoveryTrigger, at: TimeInterval)?
    private var lastBuffer: TimeInterval = 0
    private var lastFormatCheck: TimeInterval = 0
    private var formatListenerInstalled = false
    private var ioContext: UnsafeMutableRawPointer?
    private var listenerContext: UnsafeMutableRawPointer?
    private var lastSuccessRate: Double = 1
    private var continuityFailed = false
    private var producerStoppedSafely = true
    private let hardwareHooks: HardwareHooks?
    private let clock: () -> TimeInterval
    private static let formatListener: AudioObjectPropertyListenerProc = { _, _, _, context in
        if let context {
            Unmanaged<CoreAudioTapBufferRing>.fromOpaque(context).takeUnretainedValue()
                .formatInvalidated.store(true, ordering: .releasing)
        }
        return noErr
    }

    public init() {
        hardwareHooks = nil
        clock = { ProcessInfo.processInfo.systemUptime }
        queue.setSpecific(key: queueKey, value: true)
    }
    init(hardwareHooks: HardwareHooks, clock: @escaping () -> TimeInterval) {
        self.hardwareHooks = hardwareHooks
        self.clock = clock
        queue.setSpecific(key: queueKey, value: true)
    }
    deinit { stopSync() }
    public var audioFormat: AVAudioFormat? { serialized { format } }
    public var errorMessagePublisher: AnyPublisher<String?, Never> { errors.eraseToAnyPublisher() }
    public var recoveryEventPublisher: AnyPublisher<SystemAudioRecoveryEvent, Never> { recovery.eraseToAnyPublisher() }
    public var bufferSuccessRate: Double {
        serialized {
            if continuityFailed { return 0 }
            guard let ring else { return lastSuccessRate }
            let count = ring.received.load(ordering: .relaxed)
            return count == 0 ? 1 : max(0, 1 - Double(ring.dropped.load(ordering: .relaxed)) / Double(count))
        }
    }

    /// The last HAL step that refused, for start-failure and health
    /// diagnostics. A fresh capture object backs each recording attempt, so
    /// this never carries over from an earlier meeting.
    private var lastFailure: SystemAudioTapFailure?
    public var lastHardwareFailure: SystemAudioTapFailure? { serialized { lastFailure } }
    /// Reconnect counts and end reason for this recording. Written and read
    /// only on `queue`, never from the IOProc.
    private var tapDiagnostics = SystemAudioTapDiagnostics()
    public var diagnostics: SystemAudioTapDiagnostics { serialized { tapDiagnostics } }

    private func serialized<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) == true { return try body() }
        return try queue.sync(execute: body)
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            lastFailure = SystemAudioTapFailure(operation: operation, status: status)
            throw NSError(domain: "CoreAudioSystemAudioCapture", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "System audio \(operation) failed (\(status))."])
        }
    }

    public func prepare() throws {
        try serialized {
            guard device == 0, ring == nil else { return }
            do { try createHardware() } catch { destroyHardware(); throw error }
        }
    }

    private func readTapFormat() throws -> AVAudioFormat {
        if let hardwareHooks { return try hardwareHooks.currentFormat() }
        var asbd = AudioStreamBasicDescription()
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd), "format query")
        guard let result = AVAudioFormat(streamDescription: &asbd), result.commonFormat == .pcmFormatFloat32,
              result.channelCount == 2, result.sampleRate.isFinite, result.sampleRate >= 8000,
              result.sampleRate <= 384000 else {
            lastFailure = SystemAudioTapFailure(operation: "unsupported format", status: nil)
            throw NSError(domain: "CoreAudioSystemAudioCapture", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unsupported system audio format."])
        }
        return result
    }

    private func createHardware() throws {
        if let hardwareHooks {
            let current = try hardwareHooks.prepare()
            try acceptFormat(current)
            ring = CoreAudioTapBufferRing(format: current)
            return
        }
        var pid = getpid()
        var process: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &process), "own-process lookup")
        guard process != kAudioObjectUnknown else {
            lastFailure = SystemAudioTapFailure(operation: "own-process exclusion", status: nil)
            throw NSError(domain: "CoreAudioSystemAudioCapture", code: -2, userInfo: [NSLocalizedDescriptionKey: "Could not exclude Transcripted from system audio."])
        }
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [process])
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(description, &tap), "tap creation")
        let current = try readTapFormat()
        // The host creates its WAV from the first format. Never silently relabel
        // a changed route's samples with that original format during recovery.
        try acceptFormat(current)
        let properties = Self.aggregateProperties(tapUID: description.uuid.uuidString)
        try check(AudioHardwareCreateAggregateDevice(properties as CFDictionary, &device), "aggregate creation")
        // Pin the aggregate's input clock. Do not rewrite the tap ASBD using a
        // hardware output rate (that would relabel rather than resample PCM).
        var rate = current.sampleRate
        var rateAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectSetPropertyData(device, &rateAddress, 0, nil, UInt32(MemoryLayout<Double>.size), &rate), "aggregate clock setup")
        let ring = CoreAudioTapBufferRing(format: current)
        self.ring = ring
        var formatAddress = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let listenerContext = Unmanaged.passRetained(ring).toOpaque()
        let listenerStatus = AudioObjectAddPropertyListener(tap, &formatAddress, Self.formatListener, listenerContext)
        if listenerStatus != noErr { Unmanaged<CoreAudioTapBufferRing>.fromOpaque(listenerContext).release() }
        try check(listenerStatus, "format listener setup")
        self.listenerContext = listenerContext
        formatListenerInstalled = true
        let ioContext = Unmanaged.passRetained(ring).toOpaque()
        let ioStatus = AudioDeviceCreateIOProcID(device, { _, _, input, _, _, _, context in
            if let context {
                Unmanaged<CoreAudioTapBufferRing>.fromOpaque(context).takeUnretainedValue().push(input)
            }
            return noErr
        }, ioContext, &proc)
        if ioStatus != noErr { Unmanaged<CoreAudioTapBufferRing>.fromOpaque(ioContext).release() }
        try check(ioStatus, "callback creation")
        self.ioContext = ioContext
    }

    /// Shared by the real HAL path and configuration regression tests.
    static func aggregateProperties(tapUID: String, aggregateUID: String = UUID().uuidString) -> [String: Any] {
        [
            kAudioAggregateDeviceNameKey: "Transcripted System Audio",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            // AudioHardware.h: nonzero waits for a tapped application to emit
            // audio. A meeting must start on a quiet Mac without playback.
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]]
        ]
    }

    /// A later tap may run at a different rate (e.g. the output moved to a
    /// Bluetooth headset). Keep the recording's format and resample to it
    /// rather than relabel samples or end system audio for the meeting.
    private func acceptFormat(_ current: AVAudioFormat) throws {
        guard let format, !format.isEqual(current) else {
            if format == nil { format = current }
            tapFormat = current
            converter = nil
            return
        }
        guard let converter = AVAudioConverter(from: current, to: format) else {
            throw NSError(domain: "CoreAudioSystemAudioCapture", code: -3, userInfo: [NSLocalizedDescriptionKey: "System audio format changed. Start a new recording."])
        }
        tapFormat = current
        self.converter = converter
    }

    /// Runs on the consumer queue, never the IOProc thread.
    private func convertToRecordingFormat(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter, let format else { return buffer }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, conversionError == nil, output.frameLength > 0 else { return nil }
        return output
    }

    public func start(bufferCallback: @escaping (AVAudioPCMBuffer) -> Void) throws {
        try serialized {
            guard !tearingDown else {
                throw NSError(domain: "CoreAudioSystemAudioCapture", code: -4, userInfo: [NSLocalizedDescriptionKey: "System audio is stopping."])
            }
            guard !running else { return }
            generation &+= 1
            let startGeneration = generation
            try prepare()
            guard generation == startGeneration else {
                destroyHardware()
                throw NSError(domain: "CoreAudioSystemAudioCapture", code: -4, userInfo: [NSLocalizedDescriptionKey: "System audio start was cancelled."])
            }
            callback = bufferCallback
            tapDiagnostics = SystemAudioTapDiagnostics()
            recoveryUsed = false
            formatReconnects = 0
            sleepPendingSince = nil
            releasedForSleep = false
            silenceWatch = nil
            unheardPlayback.store(false, ordering: .releasing)
            clearRebuildRetryState()
            lastSuccessRate = 1
            continuityFailed = false
            do { try startHardware() } catch { callback = nil; destroyHardware(); throw error }
            silenceWatch = .armed(.start, at: clock())
            installDefaultOutputListener()
            errors.send(nil)
        }
    }

    private func startHardware() throws {
        let startGeneration = generation
        if let hardwareHooks { try hardwareHooks.start() }
        else { try check(AudioDeviceStart(device, proc), "start") }
        guard generation == startGeneration else {
            throw NSError(domain: "CoreAudioSystemAudioCapture", code: -4, userInfo: [NSLocalizedDescriptionKey: "System audio start was cancelled."])
        }
        running = true
        lastBuffer = clock()
        lastFormatCheck = lastBuffer
        guard hardwareHooks == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.drainAndCheck() }
        self.timer = timer
        timer.resume()
    }

    private func drainAndCheck() {
        if releasedForSleep {
            // A retry never runs between a sleep notice and its wake; the
            // wake reconnect covers it.
            if let retry = pendingRebuildRetry, sleepPendingSince == nil, clock() >= retry.at {
                pendingRebuildRetry = nil
                recover(retry.trigger, isRetry: true)
                return
            }
            // `clock` only counts awake time. If no wake notice ever comes,
            // rebuild anyway rather than leave system audio off for the meeting.
            if let since = sleepPendingSince, clock() - since > Self.sleepPendingAwakeLimit {
                sleepPendingSince = nil
                recover(.systemWake)
            }
            return
        }
        guard running, let ring, let tapFormat else { return }
        let drainGeneration = generation
        let now = clock()
        // The HAL listener invalidates admission without waiting for this
        // consumer queue; polling also catches a missing notification.
        // Checked before overflow: a route change must reconnect, not fail.
        guard !ring.formatInvalidated.load(ordering: .acquiring) else {
            reconnectAfterFormatChange()
            return
        }
        guard !ring.overflowed.load(ordering: .acquiring) else {
            // A buffer shaped for the new route can arrive before the
            // format listener fires. That is a route change, not a hole.
            if let current = try? readTapFormat(), !current.isEqual(tapFormat) {
                reconnectAfterFormatChange()
                return
            }
            continuityFailed = true
            fail("System audio failed - capture buffer overflow; audio before the interruption was retained.", reason: "buffer_overflow")
            return
        }
        if now - lastFormatCheck >= 0.25 {
            lastFormatCheck = now
            guard let current = try? readTapFormat(), current.isEqual(tapFormat) else {
                reconnectAfterFormatChange()
                return
            }
        }
        // Bound work per tick even if a slow host lets the producer fill again.
        for _ in 0..<ring.capacity {
            guard let buffer = ring.pop(format: tapFormat) else { break }
            guard !ring.formatInvalidated.load(ordering: .acquiring) else {
                reconnectAfterFormatChange()
                return
            }
            lastBuffer = now
            rebuildRetries = 0
            if silenceWatch != nil { noteSilenceWatchBuffer(buffer, at: now) }
            if let started = recoveryStarted {
                recoveryStarted = nil
                recovery.send(.gap(duration: max(0, now - started)))
                guard generation == drainGeneration else { return }
                errors.send(nil)
                guard generation == drainGeneration else { return }
            }
            if let converted = convertToRecordingFormat(buffer) { callback?(converted) }
            guard running, generation == drainGeneration else { return }
        }
        // `clock` is system uptime, which stops while the Mac is asleep, so
        // only awake time counts: a sleep that never reaches a wake cannot
        // switch off stall recovery for the rest of the meeting.
        if let since = sleepPendingSince, now - since > Self.sleepPendingAwakeLimit {
            sleepPendingSince = nil
        }
        // Zero-valued PCM is valid audio. Only absent callbacks trigger recovery.
        // Buffers also stop while the Mac falls asleep. The wake reconnect
        // covers that, so it must not spend the one stall reconnect: on
        // hardware, two sleeps in a meeting otherwise end system audio.
        if now - lastBuffer > 3, sleepPendingSince == nil { recover(); return }
        if silenceWatch != nil { checkSilenceWatch(at: now) }
    }

    static let sleepPendingAwakeLimit: TimeInterval = 30

    static var maxWakeSilenceReconnects: Int { SystemAudioSilenceWatch.maxWakeReconnects }

    private func noteSilenceWatchBuffer(_ buffer: AVAudioPCMBuffer, at now: TimeInterval) {
        guard var watch = silenceWatch else { return }
        guard watch.noteBuffer(hasSignal: Self.containsSignal(buffer), at: now) else {
            silenceWatch = nil
            if unheardPlayback.exchange(false, ordering: .acquiringAndReleasing) {
                AppLogger.audioSystem.info("System audio signal returned after the tap heard nothing")
            } else if watch.reason == .wake {
                AppLogger.audioSystem.info("System audio signal confirmed after wake")
            }
            return
        }
        silenceWatch = watch
    }

    private func checkSilenceWatch(at now: TimeInterval) {
        guard var watch = silenceWatch else { return }
        guard !watch.isExpired(at: now) else {
            silenceWatch = nil
            return
        }
        guard watch.wantsPlaybackCheck(at: now) else { return }
        // Zeros are normal on a quiet Mac. Only act when another app is
        // actually playing and the tap still hears nothing.
        let wasExhausted = watch.exhausted
        let action = watch.evaluate(otherAudioPlaying: otherAudioIsPlaying(), at: now)
        silenceWatch = watch
        if watch.exhausted, !wasExhausted {
            if watch.reason == .wake { tapDiagnostics.silentAfterWakeUnresolved = true }
            AppLogger.audioSystem.warning("System audio still silent after reconnects while other audio plays", [
                "watch": watch.reason.rawValue
            ])
        }
        switch action {
        case .none:
            return
        case .reconnect:
            recover(watch.reason == .wake ? .silentAfterWake : .silentWhilePlaying)
        case .reportUnheard:
            tapDiagnostics.unheardPlayback = true
            unheardPlayback.store(true, ordering: .releasing)
            AppLogger.audioSystem.warning("System audio hears nothing while another app plays", [
                "watch": watch.reason.rawValue
            ])
        }
    }

    /// True once the tap has heard only digital silence for a while, after
    /// its reconnects, while another app kept playing audio. The call is
    /// probably not being recorded. Cleared when real signal returns.
    public var isNotHearingPlayback: Bool { unheardPlayback.load(ordering: .acquiring) }

    /// The Mac's default output changed. A tap that followed it keeps
    /// working; one that did not goes silent, which the watch catches.
    private func defaultOutputDidChange() {
        guard running || releasedForSleep else { return }
        AppLogger.audioSystem.info("Default output changed during recording")
        if var watch = silenceWatch {
            watch.restartSilence()
            silenceWatch = watch
        } else {
            silenceWatch = .armed(.outputChange, at: clock())
        }
    }

    private func installDefaultOutputListener() {
        guard hardwareHooks == nil, defaultOutputListener == nil else { return }
        var address = Self.defaultOutputAddress
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.defaultOutputDidChange()
        }
        // Runs the block on `queue`, so the watch stays single-threaded.
        guard AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener) == noErr else { return }
        defaultOutputListener = listener
    }

    private func removeDefaultOutputListener() {
        guard let listener = defaultOutputListener else { return }
        var address = Self.defaultOutputAddress
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
        defaultOutputListener = nil
    }

    private static let defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    static func containsSignal(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard buffer.format.commonFormat == .pcmFormatFloat32 else { return true }
        for item in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            guard let data = item.mData else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            for index in 0..<(Int(item.mDataByteSize) / MemoryLayout<Float>.size) where samples[index] != 0 {
                return true
            }
        }
        return false
    }

    private func otherAudioIsPlaying() -> Bool {
        if let hardwareHooks { return hardwareHooks.otherAudioIsPlaying() }
        return Self.anotherProcessIsPlayingAudio(excluding: getpid())
    }

    /// True when any other process is running audio output. Read-only Core
    /// Audio process objects; nothing is attached or started.
    static func anotherProcessIsPlayingAudio(excluding ownPID: pid_t) -> Bool {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var listAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &listAddress, 0, nil, &size) == noErr, size > 0 else { return false }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &listAddress, 0, nil, &size, &processes) == noErr else { return false }
        for process in processes.prefix(Int(size) / MemoryLayout<AudioObjectID>.size) {
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            var runningAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningOutput, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(process, &runningAddress, 0, nil, &runningSize, &running) == noErr,
                  running != 0 else { continue }
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            if AudioObjectGetPropertyData(process, &pidAddress, 0, nil, &pidSize, &pid) == noErr, pid == ownPID { continue }
            return true
        }
        return false
    }

    private enum RecoveryTrigger: String { case stall, systemWake, formatChange, silentAfterWake, silentWhilePlaying }

    /// A new output route (e.g. AirPods switching to their call profile) can
    /// change the tap's rate. 1.1.61's ScreenCaptureKit path resampled for
    /// us; here the tap is rebuilt and resampled to the recording's format.
    /// Bounded so a route that keeps flapping still ends cleanly.
    private func reconnectAfterFormatChange() {
        guard formatReconnects < Self.maxFormatReconnects else {
            fail("System audio failed - audio format changed; start a new recording.", reason: "format_change_limit")
            return
        }
        formatReconnects += 1
        recover(.formatChange)
    }

    /// Stalls get one reconnect per recording. A system wake is a separate
    /// interruption the user caused, so it reconnects without spending (or
    /// needing) that budget; otherwise a second lid-close ends system audio.
    /// A wake and a format change are explained interruptions, so they
    /// reconnect quietly: the user only hears about it if the reconnect fails
    /// or the tap then stalls.
    private func recover(_ trigger: RecoveryTrigger = .stall, isRetry: Bool = false) {
        guard running || releasedForSleep else { return }
        releasedForSleep = false
        pendingRebuildRetry = nil
        // The rebuilt tap gets a fresh silence window.
        silenceWatch?.restartSilence()
        if trigger == .stall {
            guard !recoveryUsed else { fail("System audio failed - no audio buffers after reconnecting.", reason: "no_buffers_after_reconnect"); return }
            recoveryUsed = true
        }
        let recoveryGeneration = generation
        // A retry keeps the write-hold and event its first attempt sent.
        if !isRetry {
            rebuildRetries = 0
            // A reconnect still waiting for its first buffer armed one write-hold.
            // Release it before this attempt arms its own, and keep its start so
            // the eventual pad covers the whole interruption.
            let interruptionStart = recoveryStarted ?? lastBuffer
            if recoveryStarted != nil {
                recoveryStarted = nil
                recovery.send(.recoveryAbandoned)
                guard generation == recoveryGeneration else { return }
            }
            recoveryStarted = interruptionStart
            switch trigger {
            case .stall: tapDiagnostics.stallReconnects += 1
            case .systemWake: tapDiagnostics.wakeReconnects += 1
            case .formatChange: tapDiagnostics.formatReconnects += 1
            case .silentAfterWake: tapDiagnostics.silentAfterWakeReconnects += 1
            case .silentWhilePlaying: tapDiagnostics.silentPlaybackReconnects += 1
            }
            AppLogger.audioSystem.info("System audio reconnecting", ["trigger": trigger.rawValue])
            // A silent tap is not a route change: it holds writes like a wake
            // but does not count toward device switches.
            recovery.send(trigger == .stall || trigger == .formatChange ? .deviceSwitch : .systemWake)
            guard generation == recoveryGeneration else { return }
            if trigger == .stall {
                errors.send("System audio reconnecting after capture interruption.")
                guard generation == recoveryGeneration else { return }
            }
        }
        destroyHardware()
        do {
            try createHardware()
            guard generation == recoveryGeneration else { destroyHardware(); return }
            try startHardware()
            // A route or stall rebuild is a new tap with no proof it hears
            // anything yet. A wake arms its own watch; silent-tap reconnects
            // keep the watch (and budget) that asked for them.
            if silenceWatch == nil, trigger == .stall || trigger == .formatChange {
                silenceWatch = .armed(.rebuild, at: clock())
            }
        }
        catch {
            // Right after a wake or route change the output can still be
            // coming back (e.g. a 0 Hz rate). That is worth another try.
            guard trigger != .stall, generation == recoveryGeneration else {
                fail("System audio failed - could not reconnect. Start a new recording.", reason: "reconnect_failed")
                return
            }
            retryRebuild(trigger)
        }
    }

    static let maxRebuildRetries = 4

    /// 1, 2, 4, then 8 seconds of awake time.
    static func rebuildRetryDelay(attempt: Int) -> TimeInterval {
        min(8, TimeInterval(1 << max(0, min(attempt - 1, 3))))
    }

    /// Releases the hardware and schedules another rebuild of the same kind,
    /// or ends system audio once the retries are spent.
    private func retryRebuild(_ trigger: RecoveryTrigger) {
        guard rebuildRetries < Self.maxRebuildRetries else {
            fail("System audio failed - could not reconnect. Start a new recording.", reason: "reconnect_failed")
            return
        }
        rebuildRetries += 1
        tapDiagnostics.rebuildRetries += 1
        destroyHardware()
        releasedForSleep = true
        pendingRebuildRetry = (trigger, clock() + Self.rebuildRetryDelay(attempt: rebuildRetries))
        AppLogger.audioSystem.info("System audio rebuild retry scheduled", [
            "trigger": trigger.rawValue,
            "attempt": "\(rebuildRetries)"
        ])
        armReleasedTimer()
    }

    /// While released, a slow timer covers a missing wake notice and any
    /// scheduled rebuild retry. Tests drive `drainForTesting` instead.
    private func armReleasedTimer() {
        guard releasedForSleep, hardwareHooks == nil, sleepTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: .seconds(1), leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.drainAndCheck() }
        sleepTimer = timer
        timer.resume()
    }

    private func clearRebuildRetryState() {
        rebuildRetries = 0
        pendingRebuildRetry = nil
    }

    private func fail(_ message: String, reason: String) {
        let failureGeneration = generation
        tapDiagnostics.endReason = reason
        releasedForSleep = false
        silenceWatch = nil
        removeDefaultOutputListener()
        clearRebuildRetryState()
        AppLogger.audioSystem.warning("System audio capture ended", ["reason": message])
        destroyHardware()
        if recoveryStarted != nil { recoveryStarted = nil; recovery.send(.recoveryAbandoned) }
        guard generation == failureGeneration else { return }
        errors.send(message)
    }

    private func destroyHardware() {
        producerStoppedSafely = true
        let alreadyTearingDown = tearingDown
        tearingDown = true
        defer { tearingDown = alreadyTearingDown }
        timer?.cancel(); timer = nil
        sleepTimer?.cancel(); sleepTimer = nil
        running = false
        if ring != nil { hardwareHooks?.stop() }
        if let proc, device != 0 {
            let stopStatus = AudioDeviceStop(device, proc)
            // If HAL refuses teardown, retain the detached callback context
            // rather than turn an OS teardown failure into use-after-free.
            let status = AudioDeviceDestroyIOProcID(device, proc)
            producerStoppedSafely = stopStatus == noErr && status == noErr
            if status == noErr, let ioContext {
                Unmanaged<CoreAudioTapBufferRing>.fromOpaque(ioContext).release()
            }
        }
        ioContext = nil
        proc = nil
        if formatListenerInstalled, let listenerContext {
            var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            let status = AudioObjectRemovePropertyListener(tap, &address, Self.formatListener, listenerContext)
            if status == noErr { Unmanaged<CoreAudioTapBufferRing>.fromOpaque(listenerContext).release() }
            formatListenerInstalled = false
        }
        listenerContext = nil
        if let ring {
            let count = ring.received.load(ordering: .relaxed)
            lastSuccessRate = count == 0 ? 1 : max(0, 1 - Double(ring.dropped.load(ordering: .relaxed)) / Double(count))
        }
        if device != 0 { AudioHardwareDestroyAggregateDevice(device); device = 0 }
        if tap != 0 { AudioHardwareDestroyProcessTap(tap); tap = 0 }
        ring = nil
    }

    public func stop() { stopSync() }
    public func finishAndDrain() {
        serialized {
            guard !tearingDown else { return }
            tearingDown = true
            defer { tearingDown = false }
            generation &+= 1
            let finishGeneration = generation
            // Retain the immutable ring/format across producer teardown. No HAL
            // callback can add PCM after successful teardown returns.
            let tail = ring
            let tailFormat = tapFormat
            destroyHardware()
            if let tail, let tailFormat {
                if tail.overflowed.load(ordering: .acquiring) {
                    continuityFailed = true
                    errors.send("System audio failed - capture buffer overflow; audio before the interruption was retained.")
                } else if !producerStoppedSafely || tail.formatInvalidated.load(ordering: .acquiring) {
                    continuityFailed = true
                    errors.send("System audio failed - capture could not finalize safely; earlier audio was retained.")
                } else {
                    for _ in 0..<tail.capacity {
                        guard generation == finishGeneration,
                              let buffer = tail.pop(format: tailFormat) else { break }
                        if let converted = convertToRecordingFormat(buffer) { callback?(converted) }
                    }
                    if tail.overflowed.load(ordering: .acquiring) {
                        continuityFailed = true
                        errors.send("System audio failed - could not preserve the final audio buffers.")
                    }
                }
            }
            callback = nil
            format = nil
            tapFormat = nil
            converter = nil
            releasedForSleep = false
            silenceWatch = nil
            removeDefaultOutputListener()
            clearRebuildRetryState()
            if recoveryStarted != nil { recoveryStarted = nil; recovery.send(.recoveryAbandoned) }
        }
    }
    public func stopSync() {
        serialized {
            generation &+= 1
            callback = nil
            // Explicit cancellation discards queued PCM. Normal recording
            // completion uses finishAndDrain and its exact-writer handoff.
            destroyHardware()
            format = nil
            tapFormat = nil
            converter = nil
            releasedForSleep = false
            silenceWatch = nil
            removeDefaultOutputListener()
            clearRebuildRetryState()
            if recoveryStarted != nil { recoveryStarted = nil; recovery.send(.recoveryAbandoned) }
        }
    }
    /// Releases the tap and aggregate before the Mac sleeps. A tap left
    /// attached to AirPods output across sleep came back delivering zeros and
    /// garbled their playback until they were reconnected. The wake reconnect
    /// then builds a fresh tap on whatever output the Mac woke up with.
    public func prepareForSystemSleep() {
        queue.async { [weak self] in
            guard let self, self.running || self.releasedForSleep else { return }
            self.tapDiagnostics.sleeps += 1
            self.sleepPendingSince = self.clock()
            // Already released: a second lid-close before the last wake's
            // reconnect ran, or a pending rebuild retry. Stay released; this
            // sleep's wake reconnect takes over.
            guard self.running else {
                self.pendingRebuildRetry = nil
                return
            }
            self.releaseForSleep()
        }
    }
    public func recoverAfterSystemWake() {
        queue.async { [weak self] in
            guard let self else { return }
            self.sleepPendingSince = nil
            let wasRunning = self.running || self.releasedForSleep
            self.recover(.systemWake)
            // Also covers a rebuild that failed and is waiting to retry.
            guard wasRunning, self.running || self.releasedForSleep else { return }
            self.silenceWatch = .armed(.wake, at: self.clock())
        }
    }

    private func releaseForSleep() {
        let releaseGeneration = generation
        // Keep the queued tail: it is audio from just before the sleep.
        let tail = ring
        let tailFormat = tapFormat
        destroyHardware()
        releasedForSleep = true
        silenceWatch = nil
        AppLogger.audioSystem.info("System audio released for sleep")
        if let tail, let tailFormat,
           !tail.formatInvalidated.load(ordering: .acquiring),
           !tail.overflowed.load(ordering: .acquiring) {
            for _ in 0..<tail.capacity {
                guard generation == releaseGeneration,
                      let buffer = tail.pop(format: tailFormat) else { break }
                lastBuffer = clock()
                if let converted = convertToRecordingFormat(buffer) { callback?(converted) }
            }
        }
        // The host may have stopped from inside the tail callback.
        guard generation == releaseGeneration else { return }
        armReleasedTimer()
    }

    func receiveForTesting(_ buffer: AVAudioPCMBuffer) {
        serialized { ring?.push(buffer.audioBufferList) }
    }
    func drainForTesting() { serialized { drainAndCheck() } }
    func defaultOutputChangedForTesting() { serialized { defaultOutputDidChange() } }
    func invalidateFormatForTesting() {
        serialized { ring?.formatInvalidated.store(true, ordering: .releasing) }
    }
}
