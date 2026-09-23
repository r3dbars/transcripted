import Foundation
@preconcurrency import AVFoundation
import CoreAudio
import Synchronization

/// What a pinned microphone capture reports to its owner. Delivered on the
/// capture's serial queue, in order with the audio buffers.
public enum PinnedMicrophoneCaptureEvent: Equatable, Sendable {
    /// Audio resumed after a hole: a restart, a dropped callback, a device
    /// switch, or a wake. `paddedSeconds` of silence were delivered just
    /// before the next real buffer so the timeline stays continuous (zero
    /// when padding is off or the hole was too long to pad in full).
    case gap(seconds: TimeInterval, paddedSeconds: TimeInterval)
    /// The IOProc was rebuilt on the same pinned device.
    case restarted(PinnedMicrophoneRestartTrigger)
    /// The pinned device went away. Nothing is captured until the owner calls
    /// `switchDevice(to:)` or stops.
    case deviceLost
    /// Capture cannot continue on its own. The owner should stop.
    case failed(String)
}

public enum PinnedMicrophoneRestartTrigger: String, Sendable {
    case stall
    case formatChange = "format_change"
}

public struct PinnedMicrophoneCaptureDiagnostics: Equatable, Sendable {
    public let restarts: Int
    public let gaps: Int
    public let paddedSeconds: TimeInterval
    public let droppedCallbacks: Int
}

/// Records one specific input device through a Core Audio IOProc bound to
/// its `AudioDeviceID`, the same way `CoreAudioSystemAudioCapture` reads the
/// system-audio tap.
///
/// Why this exists: a fresh `AVAudioEngine.inputNode` binds the macOS
/// *default* input before `setDeviceID` can move it. When AirPods are the
/// default input, that first touch opens the AirPods mic and flips them into
/// call mode (HFP), which garbles music and can cut the AirPods out. An IOProc
/// on the pinned device never opens any other device, so pinning the Mac mic
/// leaves the AirPods alone at start, restart, recovery and wake.
///
/// Things it does not do: Apple voice processing (VPIO needs an audio unit;
/// owners keep the `AVAudioEngine` path for that) and choosing a device (the
/// owner's selection policy decides; this only records what it is given).
///
/// Threading: the IOProc only copies into a preallocated ring. Everything
/// else (HAL setup/teardown, format checks, conversion, callbacks, events)
/// runs on one serial queue. The recording format is fixed at the first
/// prepare; a later device format is resampled to it rather than relabeled.
public final class PinnedMicrophoneCapture: @unchecked Sendable {
    public struct Configuration: Sendable {
        /// Deliver silence for holes so the owner's timeline stays in step
        /// with wall-clock audio (meetings). Dictation can turn it off.
        public var padsGapsWithSilence: Bool
        /// Longest single hole padded with silence. Longer holes pad this much
        /// and report the rest in `.gap`.
        public var maxSilencePadSeconds: TimeInterval

        public init(padsGapsWithSilence: Bool = true, maxSilencePadSeconds: TimeInterval = 120) {
            self.padsGapsWithSilence = padsGapsWithSilence
            self.maxSilencePadSeconds = maxSilencePadSeconds
        }
    }

    /// Package-internal HAL seam: deterministic tests drive the same queue,
    /// ring, gap, restart and stop state machine without touching devices.
    struct HardwareHooks {
        var prepare: (AudioDeviceID) throws -> AVAudioFormat
        var start: (AudioDeviceID) throws -> Void
        var stop: () -> Void
        var currentFormat: (AudioDeviceID) throws -> AVAudioFormat
        var isAlive: (AudioDeviceID) -> Bool
    }

    public static let diagnosticBackendName = "pinned_ioproc"
    static let stallTimeoutSeconds: TimeInterval = 3
    static let maxConsecutiveRestarts = 5
    static let gapThresholdSeconds: TimeInterval = 0.05
    static let formatCheckIntervalSeconds: TimeInterval = 0.25
    static let sleepPendingAwakeLimitSeconds: TimeInterval = 30
    static let silenceChunkFrames: AVAudioFrameCount = 4096

    private let queue = DispatchQueue(label: "Transcripted.PinnedMicrophoneCapture", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<Bool>()
    private let listenerQueue = DispatchQueue(label: "Transcripted.PinnedMicrophoneCapture.listeners", qos: .userInitiated)
    private let configuration: Configuration
    private let hardwareHooks: HardwareHooks?
    private let clock: () -> TimeInterval

    private var pinnedDeviceID: AudioDeviceID
    /// The device the live IOProc and listeners belong to. Differs from
    /// `pinnedDeviceID` only between a switch and its hardware rebuild.
    private var hardwareDeviceID: AudioDeviceID = kAudioObjectUnknown
    private var proc: AudioDeviceIOProcID?
    private var ioContext: UnsafeMutableRawPointer?
    private var ring: PinnedMicrophoneBufferRing?
    private var listeners: [(address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []
    /// The recording's format, fixed at the first prepare: owners size their
    /// files and sample timelines from it.
    private var format: AVAudioFormat?
    /// The live device format. Differs from `format` after the device changed
    /// rate or channels; `converter` then resamples back.
    private var deviceFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var callback: ((AVAudioPCMBuffer) -> Void)?
    private var eventHandler: ((PinnedMicrophoneCaptureEvent) -> Void)?
    private var timer: DispatchSourceTimer?
    /// Hardware is running (IOProc started).
    private var running = false
    /// Between a successful start and stop/finish, including while waiting
    /// for the owner to replace a lost device.
    private var active = false
    private var tearingDown = false
    private var waitingForDevice = false
    private var generation: UInt64 = 0
    private var lastBufferClock: TimeInterval = 0
    private var lastFormatCheck: TimeInterval = 0
    private var expectedNextHostSeconds: TimeInterval?
    private var consecutiveRestarts = 0
    private var sleepPendingSince: TimeInterval?
    private var restartCount = 0
    private var gapCount = 0
    private var paddedSecondsTotal: TimeInterval = 0
    private var retiredDroppedCallbacks = 0

    public init(deviceID: AudioDeviceID, configuration: Configuration = Configuration()) {
        pinnedDeviceID = deviceID
        self.configuration = configuration
        hardwareHooks = nil
        clock = PinnedMicrophoneBufferRing.hostSecondsNow
        queue.setSpecific(key: queueKey, value: true)
    }

    init(
        deviceID: AudioDeviceID,
        configuration: Configuration = Configuration(),
        hardwareHooks: HardwareHooks,
        clock: @escaping () -> TimeInterval
    ) {
        pinnedDeviceID = deviceID
        self.configuration = configuration
        self.hardwareHooks = hardwareHooks
        self.clock = clock
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit { stop() }

    public var deviceID: AudioDeviceID { serialized { pinnedDeviceID } }
    public var recordingFormat: AVAudioFormat? { serialized { format } }
    public var isActive: Bool { serialized { active } }
    public var diagnostics: PinnedMicrophoneCaptureDiagnostics {
        serialized {
            PinnedMicrophoneCaptureDiagnostics(
                restarts: restartCount,
                gaps: gapCount,
                paddedSeconds: paddedSecondsTotal,
                droppedCallbacks: retiredDroppedCallbacks + (ring?.dropped.load(ordering: .relaxed) ?? 0)
            )
        }
    }

    private func serialized<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) == true { return try body() }
        return try queue.sync(execute: body)
    }

    // MARK: - Lifecycle

    /// Opens the IOProc (not started) and returns the recording format. The
    /// only HAL object touched is the pinned device.
    @discardableResult
    public func prepare() throws -> AVAudioFormat {
        try serialized {
            if ring == nil {
                do { try createHardware(on: pinnedDeviceID) } catch { destroyHardware(); throw error }
            }
            guard let format else { throw Self.error(-1, "Microphone format unavailable.") }
            return format
        }
    }

    public func start(
        bufferCallback: @escaping (AVAudioPCMBuffer) -> Void,
        eventHandler: @escaping (PinnedMicrophoneCaptureEvent) -> Void
    ) throws {
        try serialized {
            guard !tearingDown else { throw Self.error(-4, "Microphone is stopping.") }
            guard !active else { return }
            generation &+= 1
            let startGeneration = generation
            if ring == nil {
                do { try createHardware(on: pinnedDeviceID) } catch { destroyHardware(); throw error }
            }
            guard generation == startGeneration else {
                destroyHardware()
                throw Self.error(-4, "Microphone start was cancelled.")
            }
            callback = bufferCallback
            self.eventHandler = eventHandler
            active = true
            waitingForDevice = false
            consecutiveRestarts = 0
            expectedNextHostSeconds = nil
            sleepPendingSince = nil
            do { try startHardware() } catch { destroyHardware(); endSession(); throw error }
        }
    }

    /// Moves capture to another device, keeping the recording format, the
    /// callbacks and the timeline (the hole is padded like any other gap).
    public func switchDevice(to newDeviceID: AudioDeviceID) throws {
        try serialized {
            guard active, !tearingDown else { throw Self.error(-4, "Microphone is not recording.") }
            generation &+= 1
            destroyHardware()
            pinnedDeviceID = newDeviceID
            waitingForDevice = false
            consecutiveRestarts = 0
            do {
                try createHardware(on: newDeviceID)
                try startHardware()
            } catch {
                destroyHardware()
                waitingForDevice = true
                throw error
            }
        }
    }

    /// Stops the device and delivers every buffer it already captured, so
    /// the words said just before Stop reach the owner. No callback runs
    /// after this returns.
    public func finishAndDrain() {
        serialized {
            guard !tearingDown else { return }
            tearingDown = true
            defer { tearingDown = false }
            generation &+= 1
            let finishGeneration = generation
            // Keep the ring alive across teardown. No HAL callback can add
            // PCM after the IOProc is destroyed.
            let tail = ring
            let tailFormat = deviceFormat
            destroyHardware()
            if active, let tail, let tailFormat {
                for _ in 0..<tail.capacity {
                    guard generation == finishGeneration, let popped = tail.pop(format: tailFormat) else { break }
                    deliver(popped.buffer, hostSeconds: popped.hostSeconds)
                }
            }
            endSession()
        }
    }

    /// Cancels capture and discards anything not yet delivered.
    public func stop() {
        serialized {
            generation &+= 1
            destroyHardware()
            endSession()
        }
    }

    public func prepareForSystemSleep() {
        queue.async { [weak self] in
            guard let self, self.active else { return }
            self.sleepPendingSince = self.clock()
        }
    }

    /// Gives a mic that is still running a grace period after wake instead of
    /// rebuilding it. If it really stopped, the stall check restarts it on the
    /// same device a few seconds later.
    public func recoverAfterSystemWake() {
        queue.async { [weak self] in
            guard let self, self.active else { return }
            self.sleepPendingSince = nil
            self.lastBufferClock = self.clock()
        }
    }

    /// Owner-driven health check (for example, a watchdog that saw no buffers).
    /// Restarts only when this capture has also seen no buffers for the stall
    /// timeout, so a flowing mic is never rebuilt.
    public func restartIfStalled() {
        queue.async { [weak self] in
            guard let self, self.active, self.running, self.sleepPendingSince == nil else { return }
            if self.clock() - self.lastBufferClock > Self.stallTimeoutSeconds {
                self.restartInPlace(.stall)
            }
        }
    }

    private func endSession() {
        active = false
        waitingForDevice = false
        callback = nil
        eventHandler = nil
        format = nil
        deviceFormat = nil
        converter = nil
        expectedNextHostSeconds = nil
        sleepPendingSince = nil
    }

    // MARK: - Hardware

    private func createHardware(on deviceID: AudioDeviceID) throws {
        if let hardwareHooks {
            let current = try hardwareHooks.prepare(deviceID)
            try acceptFormat(current)
            ring = PinnedMicrophoneBufferRing(format: current)
            hardwareDeviceID = deviceID
            return
        }
        let current = try Self.inputFormat(of: deviceID)
        try acceptFormat(current)
        let frameSize = Int(Self.bufferFrameSize(of: deviceID) ?? 512)
        let ring = PinnedMicrophoneBufferRing(
            format: current,
            maximumFrames: max(4096, min(32768, frameSize * 2))
        )
        self.ring = ring
        hardwareDeviceID = deviceID
        installListeners(on: deviceID, ring: ring)
        let context = Unmanaged.passRetained(ring).toOpaque()
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcID(deviceID, { _, _, input, inputTime, _, _, context in
            if let context {
                Unmanaged<PinnedMicrophoneBufferRing>.fromOpaque(context).takeUnretainedValue()
                    .push(input, inputTime: inputTime)
            }
            return noErr
        }, context, &procID)
        if status != noErr { Unmanaged<PinnedMicrophoneBufferRing>.fromOpaque(context).release() }
        try Self.check(status, "callback creation")
        proc = procID
        ioContext = context
    }

    private func startHardware() throws {
        let startGeneration = generation
        if let hardwareHooks { try hardwareHooks.start(hardwareDeviceID) }
        else {
            guard let proc else { throw Self.error(-2, "Microphone callback missing.") }
            try Self.check(AudioDeviceStart(hardwareDeviceID, proc), "start")
        }
        guard generation == startGeneration else { throw Self.error(-4, "Microphone start was cancelled.") }
        running = true
        lastBufferClock = clock()
        lastFormatCheck = lastBufferClock
        guard hardwareHooks == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.drainAndCheck() }
        self.timer = timer
        timer.resume()
    }

    private func destroyHardware() {
        timer?.cancel(); timer = nil
        running = false
        if ring != nil { hardwareHooks?.stop() }
        if let proc, hardwareDeviceID != kAudioObjectUnknown {
            _ = AudioDeviceStop(hardwareDeviceID, proc)
            // If the HAL refuses teardown, keep the callback context alive
            // rather than turn an OS failure into a use-after-free.
            if AudioDeviceDestroyIOProcID(hardwareDeviceID, proc) == noErr, let ioContext {
                Unmanaged<PinnedMicrophoneBufferRing>.fromOpaque(ioContext).release()
            }
        }
        proc = nil
        ioContext = nil
        removeListeners()
        if let ring { retiredDroppedCallbacks += ring.dropped.load(ordering: .relaxed) }
        ring = nil
        hardwareDeviceID = kAudioObjectUnknown
    }

    /// HAL notifications only flag the ring; the consumer decides what they
    /// mean. Listeners run on their own queue, so removing them from the
    /// capture queue can never wait on the capture queue.
    private func installListeners(on deviceID: AudioDeviceID, ring: PinnedMicrophoneBufferRing) {
        let addresses = [
            AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain),
            AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain),
            AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain),
        ]
        for address in addresses {
            var mutableAddress = address
            let block: AudioObjectPropertyListenerBlock = { [weak ring] _, _ in
                ring?.formatInvalidated.store(true, ordering: .releasing)
            }
            if AudioObjectAddPropertyListenerBlock(deviceID, &mutableAddress, listenerQueue, block) == noErr {
                listeners.append((address: address, block: block))
            }
        }
    }

    private func removeListeners() {
        guard hardwareDeviceID != kAudioObjectUnknown else { listeners.removeAll(); return }
        for listener in listeners {
            var address = listener.address
            _ = AudioObjectRemovePropertyListenerBlock(hardwareDeviceID, &address, listenerQueue, listener.block)
        }
        listeners.removeAll()
    }

    // MARK: - Consumer

    private func drainAndCheck() {
        guard running, let ring, let deviceFormat else { return }
        let drainGeneration = generation
        let now = clock()
        // Bound work per tick even if a slow owner lets the producer refill.
        for _ in 0..<ring.capacity {
            guard let popped = ring.pop(format: deviceFormat) else { break }
            lastBufferClock = now
            consecutiveRestarts = 0
            deliver(popped.buffer, hostSeconds: popped.hostSeconds)
            guard running, generation == drainGeneration else { return }
        }
        if ring.formatInvalidated.load(ordering: .acquiring) {
            handleFormatInvalidation()
            return
        }
        if now - lastFormatCheck >= Self.formatCheckIntervalSeconds {
            lastFormatCheck = now
            guard isAlive(pinnedDeviceID) else { handleDeviceLost(); return }
            guard let current = try? currentFormat(of: pinnedDeviceID), current.isEqual(deviceFormat) else {
                restartInPlace(.formatChange)
                return
            }
        }
        // Buffers stop while the Mac falls asleep. That is not a stall, but a
        // sleep that never reaches a wake must not switch stall checks off for
        // the rest of the recording.
        if let since = sleepPendingSince, now - since > Self.sleepPendingAwakeLimitSeconds {
            sleepPendingSince = nil
        }
        if now - lastBufferClock > Self.stallTimeoutSeconds, sleepPendingSince == nil {
            restartInPlace(.stall)
        }
    }

    /// A listener fired (liveness, rate or channel layout) or a callback's
    /// layout stopped matching. These are rare, and rebuilding the IOProc on
    /// the same device is cheap and touches nothing else, so always rebuild.
    /// Callbacks dropped meanwhile come back as a padded gap.
    private func handleFormatInvalidation() {
        guard isAlive(pinnedDeviceID) else { handleDeviceLost(); return }
        restartInPlace(.formatChange)
    }

    private func restartInPlace(_ trigger: PinnedMicrophoneRestartTrigger) {
        guard active, !tearingDown else { return }
        consecutiveRestarts += 1
        guard consecutiveRestarts <= Self.maxConsecutiveRestarts else {
            fail("The microphone stopped delivering audio and could not be restarted.")
            return
        }
        let restartGeneration = generation
        destroyHardware()
        do {
            try createHardware(on: pinnedDeviceID)
            guard generation == restartGeneration else { destroyHardware(); return }
            try startHardware()
            restartCount += 1
            emit(.restarted(trigger))
        } catch {
            destroyHardware()
            guard generation == restartGeneration else { return }
            if !isAlive(pinnedDeviceID) {
                handleDeviceLost()
            } else {
                fail("The microphone could not be restarted.")
            }
        }
    }

    private func handleDeviceLost() {
        guard active, !waitingForDevice else { return }
        destroyHardware()
        waitingForDevice = true
        emit(.deviceLost)
    }

    private func fail(_ message: String) {
        let failureGeneration = generation
        destroyHardware()
        waitingForDevice = true
        guard generation == failureGeneration else { return }
        emit(.failed(message))
    }

    private func emit(_ event: PinnedMicrophoneCaptureEvent) {
        eventHandler?(event)
    }

    private func deliver(_ buffer: AVAudioPCMBuffer, hostSeconds: TimeInterval) {
        let deliveryGeneration = generation
        if hostSeconds > 0 {
            if let expected = expectedNextHostSeconds {
                let hole = hostSeconds - expected
                if hole > Self.gapThresholdSeconds {
                    reportGap(seconds: hole)
                    guard generation == deliveryGeneration, callback != nil else { return }
                }
            }
            let rate = buffer.format.sampleRate
            expectedNextHostSeconds = hostSeconds + (rate > 0 ? Double(buffer.frameLength) / rate : 0)
        } else {
            // No timestamp: never measure the next hole from a stale one.
            expectedNextHostSeconds = nil
        }
        if let converted = convertToRecordingFormat(buffer) { callback?(converted) }
    }

    private func reportGap(seconds: TimeInterval) {
        let gapGeneration = generation
        var padded: TimeInterval = 0
        if configuration.padsGapsWithSilence, let format {
            let target = min(seconds, configuration.maxSilencePadSeconds)
            var remaining = AVAudioFrameCount((target * format.sampleRate).rounded())
            while remaining > 0 {
                let chunk = min(remaining, Self.silenceChunkFrames)
                guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { break }
                silence.frameLength = chunk
                for item in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) {
                    if let data = item.mData { memset(data, 0, Int(item.mDataByteSize)) }
                }
                callback?(silence)
                guard generation == gapGeneration else { return }
                remaining -= chunk
                padded += Double(chunk) / format.sampleRate
            }
        }
        gapCount += 1
        paddedSecondsTotal += padded
        emit(.gap(seconds: seconds, paddedSeconds: padded))
    }

    // MARK: - Format

    /// A later device format (another app changed the mic's rate, or a
    /// replacement device) keeps the recording's format and is resampled.
    private func acceptFormat(_ current: AVAudioFormat) throws {
        guard let format, !format.isEqual(current) else {
            if format == nil { format = current }
            deviceFormat = current
            converter = nil
            return
        }
        guard let converter = AVAudioConverter(from: current, to: format) else {
            throw Self.error(-3, "Microphone format changed and could not be converted.")
        }
        converter.downmix = current.channelCount > format.channelCount
        deviceFormat = current
        self.converter = converter
    }

    /// Runs on the capture queue, never the IOProc thread.
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

    private func currentFormat(of deviceID: AudioDeviceID) throws -> AVAudioFormat {
        if let hardwareHooks { return try hardwareHooks.currentFormat(deviceID) }
        return try Self.inputFormat(of: deviceID)
    }

    private func isAlive(_ deviceID: AudioDeviceID) -> Bool {
        if let hardwareHooks { return hardwareHooks.isAlive(deviceID) }
        return Self.deviceIsAlive(deviceID)
    }

    // MARK: - HAL reads (no side effects)

    /// The PCM layout the IOProc delivers for `deviceID`'s input streams, or
    /// an error when this backend cannot record it (owners then fall back to
    /// `AVAudioEngine`). Reads properties of that device only.
    public static func inputFormat(of deviceID: AudioDeviceID) throws -> AVAudioFormat {
        let streams = try inputStreams(of: deviceID)
        var descriptions: [AudioStreamBasicDescription] = []
        for stream in streams {
            var asbd = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            var address = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyVirtualFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            try check(AudioObjectGetPropertyData(stream, &address, 0, nil, &size, &asbd), "stream format query")
            descriptions.append(asbd)
        }
        return try deviceFormat(streamDescriptions: descriptions)
    }

    public static func canRecord(deviceID: AudioDeviceID) -> Bool {
        deviceID != kAudioObjectUnknown && (try? inputFormat(of: deviceID)) != nil
    }

    /// Pure mapping from the device's input stream formats to the buffer
    /// layout the ring copies: one interleaved stream, or several mono streams
    /// as non-interleaved channels. Anything else is unsupported.
    static func deviceFormat(streamDescriptions: [AudioStreamBasicDescription]) throws -> AVAudioFormat {
        guard let first = streamDescriptions.first else {
            throw error(-5, "The microphone has no input streams.")
        }
        let rate = first.mSampleRate
        guard rate.isFinite, rate >= 8000, rate <= 384_000 else {
            throw error(-5, "Unsupported microphone sample rate.")
        }
        for description in streamDescriptions {
            let flags = description.mFormatFlags
            guard description.mFormatID == kAudioFormatLinearPCM,
                  flags & kAudioFormatFlagIsFloat != 0,
                  flags & kAudioFormatFlagIsBigEndian == 0,
                  flags & kAudioFormatFlagIsNonInterleaved == 0,
                  description.mBitsPerChannel == 32,
                  description.mChannelsPerFrame >= 1,
                  description.mBytesPerFrame == 4 * description.mChannelsPerFrame,
                  description.mSampleRate == rate else {
                throw error(-5, "Unsupported microphone format.")
            }
        }
        let channels: AVAudioChannelCount
        let interleaved: Bool
        if streamDescriptions.count == 1 {
            channels = first.mChannelsPerFrame
            interleaved = channels > 1
        } else {
            guard streamDescriptions.allSatisfy({ $0.mChannelsPerFrame == 1 }) else {
                throw error(-5, "Unsupported microphone stream layout.")
            }
            channels = AVAudioChannelCount(streamDescriptions.count)
            interleaved = false
        }
        guard channels <= 64 else { throw error(-5, "Unsupported microphone channel count.") }
        let result: AVAudioFormat?
        if channels <= 2 {
            result = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: interleaved)
        } else if let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels) {
            result = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, interleaved: interleaved, channelLayout: layout)
        } else {
            result = nil
        }
        guard let result else { throw error(-5, "Unsupported microphone format.") }
        return result
    }

    private static func inputStreams(of deviceID: AudioDeviceID) throws -> [AudioStreamID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size), "stream list size")
        let count = Int(size) / MemoryLayout<AudioStreamID>.size
        guard count > 0 else { throw error(-5, "The microphone has no input streams.") }
        var streams = [AudioStreamID](repeating: kAudioObjectUnknown, count: count)
        try check(AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &streams), "stream list")
        return Array(streams.prefix(Int(size) / MemoryLayout<AudioStreamID>.size))
    }

    static func bufferFrameSize(of deviceID: AudioDeviceID) -> UInt32? {
        var frames: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &frames) == noErr, frames > 0 else { return nil }
        return frames
    }

    static func deviceIsAlive(_ deviceID: AudioDeviceID) -> Bool {
        guard deviceID != kAudioObjectUnknown else { return false }
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &alive) == noErr else { return false }
        return alive != 0
    }

    private static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            throw NSError(domain: "PinnedMicrophoneCapture", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Microphone \(operation) failed (\(status))."])
        }
    }

    private static func error(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "PinnedMicrophoneCapture", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: - Test seams

    func receiveForTesting(_ buffer: AVAudioPCMBuffer, hostSeconds: TimeInterval) {
        serialized { ring?.push(buffer.audioBufferList, hostSeconds: hostSeconds) }
    }
    func drainForTesting() { serialized { drainAndCheck() } }
    func invalidateFormatForTesting() {
        serialized { ring?.formatInvalidated.store(true, ordering: .releasing) }
    }
}
