import Foundation
@preconcurrency import AVFoundation
import CoreAudio
import Synchronization

/// What a pinned microphone capture reports to its owner. Delivered on the
/// capture's serial queue. `.gap` and `.silentInput` are in order with the
/// audio buffers; the state events (`.restarted`, `.deviceLost`, `.failed`)
/// are reported as soon as they happen.
public enum PinnedMicrophoneCaptureEvent: Equatable, Sendable {
    /// Audio resumed after a hole: a restart, a dropped callback, a device
    /// switch, or a wake. `paddedSeconds` of silence follow this event, ahead
    /// of the next real buffer, so the timeline stays continuous (zero when
    /// padding is off; less than `seconds` when the hole was longer than
    /// `maxSilencePadSeconds`). Long pads are paced across timer ticks so the
    /// owner's writer never takes them in one burst.
    case gap(seconds: TimeInterval, paddedSeconds: TimeInterval)
    /// The IOProc was rebuilt on the same pinned device.
    case restarted(PinnedMicrophoneRestartTrigger)
    /// The pinned device went away. Nothing is captured until the owner calls
    /// `switchDevice(to:)` or stops. `isWaitingForDevice` stays true until then.
    case deviceLost
    /// The device has delivered `silentInputDetectionSeconds` of samples that
    /// are all exactly 0.0 (a closed MacBook lid, a digitally muted input).
    /// Reported once per device; `switchDevice(to:)` re-arms it. Capture keeps
    /// running; the owner decides whether to move to another input.
    case silentInput
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
        /// The device's IO buffer size, which sizes the ring. Nil means the
        /// same 512-frame guess the HAL path uses when the read fails.
        var bufferFrameSize: (AudioDeviceID) -> UInt32? = { _ in nil }
    }

    /// Why a queued item waits: silence padding is paced, and real buffers and
    /// in-order events queued behind it must not overtake it.
    private enum PendingOutput {
        case audio(AVAudioPCMBuffer)
        case silence(frames: Int)
        case event(PinnedMicrophoneCaptureEvent)
    }

    public static let diagnosticBackendName = "pinned_ioproc"
    static let stallTimeoutSeconds: TimeInterval = 3
    /// Counted rebuilds (stalls, layout mismatches, rebuilds past
    /// `maxFormatSettleRebuilds`) allowed before audio flows again.
    static let maxConsecutiveRestarts = 5
    static let gapThresholdSeconds: TimeInterval = 0.05
    static let formatCheckIntervalSeconds: TimeInterval = 0.25
    static let sleepPendingAwakeLimitSeconds: TimeInterval = 30
    static let silenceChunkFrames: AVAudioFrameCount = 4096
    /// A HAL notification burst (the AirPods call-mode switch, wake) must be
    /// quiet this long before the IOProc is rebuilt, so the burst costs one
    /// rebuild. A new notification restarts the wait.
    static let formatSettleSeconds: TimeInterval = 0.3
    /// Rebuilds driven by fresh HAL notifications (the format is still
    /// moving) are free up to this many in a row without audio; after that
    /// they count toward `maxConsecutiveRestarts` so a device that never
    /// settles still fails instead of rebuilding forever.
    static let maxFormatSettleRebuilds = 20
    /// Waits before retrying a rebuild that failed on a device that is still
    /// alive. When the last retry fails too, the capture reports `.failed`.
    static let rebuildRetryDelays: [TimeInterval] = [1, 2, 4, 8]
    /// After wake a mic that may still be running is left alone this long:
    /// no stall restart, no format poll, no notification-driven rebuild.
    static let postWakeGraceSeconds: TimeInterval = 3
    /// Silence padding delivered per timer tick is the smaller of these two.
    /// The owner's mic writer admits at most 8 MB in flight and ends the
    /// meeting past that, so a 120 s hole (23 MB of stereo 48 kHz) must not
    /// arrive in one burst.
    static let maxPadSecondsPerTick: TimeInterval = 1
    static let maxPadBytesPerTick = 1 * 1_024 * 1_024
    /// `finishAndDrain` cannot pace: it delivers at most this much of a
    /// pending pad synchronously, then the tail audio behind it.
    static let maxPadBytesAtFinish = 4 * 1_024 * 1_024
    /// A run of real (not padded) audio this long in which every sample is
    /// exactly 0.0 reports `.silentInput`. Live mics never hold digital zero
    /// that long; a closed lid or a hardware mute does.
    static let silentInputDetectionSeconds: TimeInterval = 1.5

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
    /// Set by `fail`: waiting for nothing, the owner should stop.
    private var hasFailed = false
    private var generation: UInt64 = 0
    private var lastBufferClock: TimeInterval = 0
    private var lastFormatCheck: TimeInterval = 0
    private var expectedNextHostSeconds: TimeInterval?
    private var consecutiveRestarts = 0
    private var consecutiveFormatSettleRebuilds = 0
    private var sleepPendingSince: TimeInterval?
    private var wakeGraceUntil: TimeInterval?
    /// `ring.halNotifications` as last seen by the consumer.
    private var observedHALNotifications = 0
    /// When the current format change was last seen moving (a notification,
    /// a poll mismatch, or a producer invalidation). Nil while settled.
    private var formatSettleSince: TimeInterval?
    /// A HAL notification or poll mismatch, not only a producer layout
    /// mismatch, is behind the pending rebuild.
    private var formatSettleIsHALDriven = false
    /// Hardware is down between failed rebuild attempts on a live device.
    private var rebuildRetryAt: TimeInterval?
    private var rebuildRetryAttempt = 0
    private var rebuildRetryTrigger: PinnedMicrophoneRestartTrigger = .formatChange
    private var pendingOutput: [PendingOutput] = []
    private var silentInputRunSeconds: TimeInterval = 0
    private var silentInputReported = false
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
    /// True after `.deviceLost` (or a failed `switchDevice(to:)`) until the
    /// owner switches to another device or stops. False after `.failed`.
    public var isWaitingForDevice: Bool { serialized { active && waitingForDevice && !hasFailed } }
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
            hasFailed = false
            consecutiveRestarts = 0
            consecutiveFormatSettleRebuilds = 0
            expectedNextHostSeconds = nil
            sleepPendingSince = nil
            wakeGraceUntil = nil
            rebuildRetryAt = nil
            rebuildRetryAttempt = 0
            pendingOutput.removeAll()
            resetSilentInputDetection()
            do { try startHardware() } catch { destroyHardware(); endSession(); throw error }
            startTimerIfNeeded()
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
            hasFailed = false
            consecutiveRestarts = 0
            consecutiveFormatSettleRebuilds = 0
            rebuildRetryAt = nil
            rebuildRetryAttempt = 0
            resetSilentInputDetection()
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
    /// the words said just before Stop reach the owner. A pad still pending
    /// is delivered up to `maxPadBytesAtFinish`, and the rest of it is
    /// dropped rather than burst into the owner. No callback runs after this
    /// returns.
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
            if active {
                if let tail, let tailFormat {
                    for _ in 0..<tail.capacity {
                        guard generation == finishGeneration, let popped = tail.pop(format: tailFormat) else { break }
                        deliver(popped.buffer, hostSeconds: popped.hostSeconds)
                    }
                }
                if generation == finishGeneration, let recording = format {
                    flushPendingOutput(
                        padFrameBudget: Self.padFrameBudget(format: recording, seconds: nil, bytes: Self.maxPadBytesAtFinish),
                        dropsSilenceOverBudget: true
                    )
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

    /// While sleep is pending, a stall, a format poll, a HAL notification or
    /// a rebuild retry starts no rebuild: buffers and notifications stop and
    /// fire as the Mac goes down without the mic being broken.
    public func prepareForSystemSleep() {
        queue.async { [weak self] in
            guard let self, self.active else { return }
            self.sleepPendingSince = self.clock()
        }
    }

    /// Gives a mic that is still running a grace period after wake instead of
    /// rebuilding it. If it really stopped, the stall check restarts it on the
    /// same device a few seconds later; a format change seen meanwhile is
    /// rebuilt once, when the grace ends.
    public func recoverAfterSystemWake() {
        queue.async { [weak self] in
            guard let self, self.active else { return }
            let now = self.clock()
            self.sleepPendingSince = nil
            self.lastBufferClock = now
            self.wakeGraceUntil = now + Self.postWakeGraceSeconds
        }
    }

    /// Owner-driven health check (for example, a watchdog that saw no buffers).
    /// Restarts only when this capture has also seen no buffers for the stall
    /// timeout, so a flowing mic is never rebuilt.
    public func restartIfStalled() {
        queue.async { [weak self] in
            guard let self, self.active, self.running else { return }
            let now = self.clock()
            // A format rebuild is already on its way once the change settles.
            guard !self.recoveryDeferred(at: now), self.formatSettleSince == nil,
                  self.ring?.formatInvalidated.load(ordering: .acquiring) != true else { return }
            if now - self.lastBufferClock > Self.stallTimeoutSeconds {
                self.restartInPlace(.stall, counted: true)
            }
        }
    }

    private func endSession() {
        timer?.cancel(); timer = nil
        active = false
        waitingForDevice = false
        hasFailed = false
        callback = nil
        eventHandler = nil
        format = nil
        deviceFormat = nil
        converter = nil
        expectedNextHostSeconds = nil
        sleepPendingSince = nil
        wakeGraceUntil = nil
        rebuildRetryAt = nil
        rebuildRetryAttempt = 0
        pendingOutput.removeAll()
        resetSilentInputDetection()
    }

    /// True while the Mac is falling asleep or just woke. A sleep that never
    /// reaches a wake must not switch recovery off for the rest of the
    /// recording, so sleep-pending expires after `sleepPendingAwakeLimitSeconds`.
    private func recoveryDeferred(at now: TimeInterval) -> Bool {
        if let since = sleepPendingSince {
            if now - since > Self.sleepPendingAwakeLimitSeconds {
                sleepPendingSince = nil
            } else {
                return true
            }
        }
        if let until = wakeGraceUntil {
            if now < until { return true }
            wakeGraceUntil = nil
        }
        return false
    }

    // MARK: - Hardware

    private func createHardware(on deviceID: AudioDeviceID) throws {
        resetFormatSettle()
        if let hardwareHooks {
            let current = try hardwareHooks.prepare(deviceID)
            let fakeRing = try Self.makeRing(format: current, deviceFrameSize: hardwareHooks.bufferFrameSize(deviceID))
            try acceptFormat(current)
            ring = fakeRing
            hardwareDeviceID = deviceID
            return
        }
        let current = try Self.inputFormat(of: deviceID)
        let ring = try Self.makeRing(format: current, deviceFrameSize: Self.bufferFrameSize(of: deviceID))
        try acceptFormat(current)
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

    /// The ring's storage is capped (`PinnedMicrophoneBufferRing.storageByteLimit`).
    /// A device too wide to fit a sane ring under it is refused, so owners
    /// fall back to the audio engine instead of reserving hundreds of MB.
    static func makeRing(format: AVAudioFormat, deviceFrameSize: UInt32?) throws -> PinnedMicrophoneBufferRing {
        let frameSize = Int(deviceFrameSize ?? 512)
        guard let layout = PinnedMicrophoneBufferRing.layout(format: format, deviceFrameSize: frameSize) else {
            throw error(-6, "The microphone has too many channels or too large an IO buffer for the pinned recorder.")
        }
        return PinnedMicrophoneBufferRing(format: format, capacity: layout.capacity, maximumFrames: layout.maximumFrames)
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
    }

    /// One timer per session, not per IOProc: it keeps ticking while the
    /// hardware is down (rebuild retries, a lost device) so retries fire and
    /// paced padding keeps flowing. `endSession` cancels it.
    private func startTimerIfNeeded() {
        guard hardwareHooks == nil, timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.drainAndCheck() }
        self.timer = timer
        timer.resume()
    }

    private func destroyHardware() {
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
        resetFormatSettle()
    }

    private func resetFormatSettle() {
        observedHALNotifications = 0
        formatSettleSince = nil
        formatSettleIsHALDriven = false
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
                ring?.noteHALNotification()
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
        guard active, !tearingDown else { return }
        let tickGeneration = generation
        let now = clock()
        let deferred = recoveryDeferred(at: now)
        if running, let drainRing = ring, let drainFormat = deviceFormat {
            // Bound work per tick even if a slow owner lets the producer refill.
            for _ in 0..<drainRing.capacity {
                guard let popped = drainRing.pop(format: drainFormat) else { break }
                lastBufferClock = now
                consecutiveRestarts = 0
                consecutiveFormatSettleRebuilds = 0
                deliver(popped.buffer, hostSeconds: popped.hostSeconds)
                guard running, generation == tickGeneration else { return }
            }
        }
        // Paced padding, then whatever real audio and events wait behind it.
        // Runs while the hardware is down too, so a lost device or a retry
        // wait never strands audio that was already captured.
        if !pendingOutput.isEmpty, let recording = format {
            flushPendingOutput(
                padFrameBudget: Self.padFrameBudget(format: recording, seconds: Self.maxPadSecondsPerTick, bytes: Self.maxPadBytesPerTick),
                dropsSilenceOverBudget: false
            )
            guard active, generation == tickGeneration else { return }
        }
        if let retryAt = rebuildRetryAt {
            // Retries wait out a pending sleep but not the wake grace: the
            // hardware is already down, so waiting only loses audio.
            if sleepPendingSince == nil, now >= retryAt {
                rebuildRetryAt = nil
                attemptRebuild(rebuildRetryTrigger)
            }
            return
        }
        guard running, let liveRing = ring, let liveFormat = deviceFormat else { return }
        let invalidated = liveRing.formatInvalidated.load(ordering: .acquiring)
        let notifications = liveRing.halNotifications.load(ordering: .relaxed)
        if notifications != observedHALNotifications {
            observedHALNotifications = notifications
            formatSettleSince = now
            formatSettleIsHALDriven = true
        }
        if invalidated, formatSettleSince == nil {
            formatSettleSince = now
        }
        if let since = formatSettleSince {
            // Rebuild once, after the last notification of a burst. Sleep and
            // the wake grace hold it off the same way they hold off a stall.
            guard !deferred, now - since >= Self.formatSettleSeconds else { return }
            handleFormatInvalidation()
            return
        }
        // Buffers stop while the Mac falls asleep and may pause just after
        // wake. That is not a stall, and the format poll waits too.
        guard !deferred else { return }
        if now - lastFormatCheck >= Self.formatCheckIntervalSeconds {
            lastFormatCheck = now
            guard isAlive(pinnedDeviceID) else { handleDeviceLost(); return }
            let current = try? currentFormat(of: pinnedDeviceID)
            if current?.isEqual(liveFormat) != true {
                // Same path as a HAL notification: stop taking audio in the
                // old layout and rebuild once the change settles.
                liveRing.formatInvalidated.store(true, ordering: .releasing)
                formatSettleSince = now
                formatSettleIsHALDriven = true
                return
            }
        }
        if now - lastBufferClock > Self.stallTimeoutSeconds {
            restartInPlace(.stall, counted: true)
        }
    }

    /// A listener fired (liveness, rate or channel layout), the poll saw a
    /// new format, or a callback's layout stopped matching, and nothing new
    /// arrived for `formatSettleSeconds`. Rebuilding the IOProc on the same
    /// device is cheap and touches nothing else. Callbacks dropped meanwhile
    /// come back as a padded gap.
    private func handleFormatInvalidation() {
        guard isAlive(pinnedDeviceID) else { handleDeviceLost(); return }
        restartInPlace(.formatChange, counted: !formatSettleIsHALDriven)
    }

    /// `counted` rebuilds spend `maxConsecutiveRestarts`. A rebuild while the
    /// HAL is still announcing changes does not, up to `maxFormatSettleRebuilds`
    /// in a row: a notification burst must not use up the budget before audio
    /// flows. Audio refills both.
    private func restartInPlace(_ trigger: PinnedMicrophoneRestartTrigger, counted: Bool) {
        guard active, !tearingDown else { return }
        if counted || consecutiveFormatSettleRebuilds >= Self.maxFormatSettleRebuilds {
            consecutiveRestarts += 1
            guard consecutiveRestarts <= Self.maxConsecutiveRestarts else {
                fail("The microphone stopped delivering audio and could not be restarted.")
                return
            }
        } else {
            consecutiveFormatSettleRebuilds += 1
        }
        rebuildRetryAttempt = 0
        rebuildRetryAt = nil
        attemptRebuild(trigger)
    }

    /// One rebuild attempt. If it throws while the device is still alive, the
    /// hardware stays down and the attempt is retried after the next
    /// `rebuildRetryDelays` wait; only when those run out does the capture
    /// fail. A device that is gone is reported lost instead.
    private func attemptRebuild(_ trigger: PinnedMicrophoneRestartTrigger) {
        guard active, !tearingDown else { return }
        let restartGeneration = generation
        destroyHardware()
        do {
            try createHardware(on: pinnedDeviceID)
            guard generation == restartGeneration else { destroyHardware(); return }
            try startHardware()
            rebuildRetryAttempt = 0
            rebuildRetryAt = nil
            restartCount += 1
            emit(.restarted(trigger))
        } catch {
            destroyHardware()
            guard generation == restartGeneration else { return }
            guard isAlive(pinnedDeviceID) else {
                rebuildRetryAt = nil
                rebuildRetryAttempt = 0
                handleDeviceLost()
                return
            }
            guard rebuildRetryAttempt < Self.rebuildRetryDelays.count else {
                fail("The microphone could not be restarted.")
                return
            }
            rebuildRetryAt = clock() + Self.rebuildRetryDelays[rebuildRetryAttempt]
            rebuildRetryAttempt += 1
            rebuildRetryTrigger = trigger
        }
    }

    private func handleDeviceLost() {
        guard active, !waitingForDevice else { return }
        destroyHardware()
        rebuildRetryAt = nil
        rebuildRetryAttempt = 0
        waitingForDevice = true
        emit(.deviceLost)
    }

    private func fail(_ message: String) {
        let failureGeneration = generation
        destroyHardware()
        rebuildRetryAt = nil
        rebuildRetryAttempt = 0
        waitingForDevice = true
        hasFailed = true
        guard generation == failureGeneration else { return }
        emit(.failed(message))
    }

    private func emit(_ event: PinnedMicrophoneCaptureEvent) {
        eventHandler?(event)
    }

    /// Hands `item` to the owner now when nothing waits ahead of it, else
    /// queues it behind the pending pad so order is kept. Silence is always
    /// queued: it is only ever delivered by `flushPendingOutput`, paced.
    private func deliverInOrder(_ item: PendingOutput) {
        guard pendingOutput.isEmpty else {
            pendingOutput.append(item)
            return
        }
        switch item {
        case let .audio(buffer):
            callback?(buffer)
        case let .event(event):
            emit(event)
        case .silence:
            pendingOutput.append(item)
        }
    }

    private func deliver(_ buffer: AVAudioPCMBuffer, hostSeconds: TimeInterval) {
        let deliveryGeneration = generation
        if hostSeconds > 0 {
            if let expected = expectedNextHostSeconds {
                let hole = hostSeconds - expected
                if hole > Self.gapThresholdSeconds {
                    scheduleGap(seconds: hole)
                    guard generation == deliveryGeneration, callback != nil else { return }
                }
            }
            let rate = buffer.format.sampleRate
            expectedNextHostSeconds = hostSeconds + (rate > 0 ? Double(buffer.frameLength) / rate : 0)
        } else {
            // No timestamp: never measure the next hole from a stale one.
            expectedNextHostSeconds = nil
        }
        if let converted = convertToRecordingFormat(buffer) { deliverInOrder(.audio(converted)) }
        guard generation == deliveryGeneration else { return }
        trackSilentInput(buffer)
    }

    /// Reports the hole and queues its silence. The silence goes out paced by
    /// `flushPendingOutput`, always ahead of the buffer that revealed the hole.
    private func scheduleGap(seconds: TimeInterval) {
        let gapGeneration = generation
        var paddedFrames = 0
        var paddedSeconds: TimeInterval = 0
        if configuration.padsGapsWithSilence, let format, format.sampleRate > 0 {
            let target = min(seconds, configuration.maxSilencePadSeconds)
            if target.isFinite, target > 0 {
                paddedFrames = Int((target * format.sampleRate).rounded())
                paddedSeconds = Double(paddedFrames) / format.sampleRate
            }
        }
        gapCount += 1
        deliverInOrder(.event(.gap(seconds: seconds, paddedSeconds: paddedSeconds)))
        guard generation == gapGeneration, paddedFrames > 0 else { return }
        pendingOutput.append(.silence(frames: paddedFrames))
    }

    /// Delivers queued output in order. Silence is limited to
    /// `padFrameBudget` frames per call; when the budget runs out mid-pad the
    /// rest waits for the next tick, or is dropped when
    /// `dropsSilenceOverBudget` (finishing: keep the tail audio, not the pad).
    private func flushPendingOutput(padFrameBudget: Int, dropsSilenceOverBudget: Bool) {
        let flushGeneration = generation
        var budget = padFrameBudget
        while let item = pendingOutput.first {
            switch item {
            case let .audio(buffer):
                pendingOutput.removeFirst()
                callback?(buffer)
            case let .event(event):
                pendingOutput.removeFirst()
                emit(event)
            case let .silence(frames):
                let wanted = min(frames, max(0, budget))
                let delivered = wanted > 0 ? deliverSilence(frames: wanted) : 0
                // The owner stopped the capture from inside a callback.
                guard !pendingOutput.isEmpty else { return }
                let stillCurrent = generation == flushGeneration
                budget -= delivered
                if delivered == frames || (stillCurrent && (delivered < wanted || dropsSilenceOverBudget)) {
                    // Done; or silence could not be allocated; or finishing.
                    pendingOutput.removeFirst()
                } else {
                    // Out of budget (or the owner switched devices from a
                    // callback): the rest goes out on a later tick.
                    pendingOutput[0] = .silence(frames: frames - delivered)
                    return
                }
            }
            guard generation == flushGeneration else { return }
        }
    }

    /// Returns the frames handed to the owner (fewer than asked only when a
    /// buffer cannot be allocated or the owner stopped the capture).
    private func deliverSilence(frames: Int) -> Int {
        guard let format, format.sampleRate > 0 else { return 0 }
        let silenceGeneration = generation
        var delivered = 0
        while delivered < frames {
            let chunk = min(frames - delivered, Int(Self.silenceChunkFrames))
            guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk)) else { break }
            silence.frameLength = AVAudioFrameCount(chunk)
            for item in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) {
                if let data = item.mData { memset(data, 0, Int(item.mDataByteSize)) }
            }
            callback?(silence)
            delivered += chunk
            paddedSecondsTotal += Double(chunk) / format.sampleRate
            guard generation == silenceGeneration else { break }
        }
        return delivered
    }

    /// Frames of padding one delivery may carry: `seconds` of the recording
    /// format (no time cap when nil) and never more than `bytes`.
    static func padFrameBudget(format: AVAudioFormat, seconds: TimeInterval?, bytes: Int) -> Int {
        let frameBytes = max(1, Int(format.channelCount)) * MemoryLayout<Float>.size
        var frames = max(1, bytes / frameBytes)
        if let seconds, seconds.isFinite, format.sampleRate > 0 {
            let bySeconds = seconds * format.sampleRate
            if bySeconds < Double(frames) { frames = max(1, Int(bySeconds.rounded(.down))) }
        }
        return frames
    }

    // MARK: - Silent input

    /// Runs on the serial queue on each real buffer, in the device format,
    /// before conversion. Padding never counts. Stops looking once reported.
    private func trackSilentInput(_ buffer: AVAudioPCMBuffer) {
        guard !silentInputReported, !tearingDown, buffer.frameLength > 0 else { return }
        let rate = buffer.format.sampleRate
        guard rate > 0 else { return }
        guard Self.isDigitalSilence(buffer) else {
            silentInputRunSeconds = 0
            return
        }
        silentInputRunSeconds += Double(buffer.frameLength) / rate
        // A hair of tolerance so 1.5 s summed from buffer lengths counts.
        guard silentInputRunSeconds + 1e-9 >= Self.silentInputDetectionSeconds else { return }
        silentInputReported = true
        deliverInOrder(.event(.silentInput))
    }

    private func resetSilentInputDetection() {
        silentInputRunSeconds = 0
        silentInputReported = false
    }

    /// Every sample is exactly 0.0 (negative zero included). Exits at the
    /// first non-zero sample, which for a live mic is almost always the first.
    static func isDigitalSilence(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              let channels = buffer.floatChannelData else { return false }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return false }
        let channelCount = Int(buffer.format.channelCount)
        let interleaved = buffer.format.isInterleaved
        let pointerCount = interleaved ? 1 : channelCount
        let samplesPerPointer = interleaved ? frames * channelCount : frames
        for index in 0..<pointerCount {
            let data = channels[index]
            for sample in 0..<samplesPerPointer where data[sample] != 0 {
                return false
            }
        }
        return true
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
    /// Same as a HAL property listener firing.
    func invalidateFormatForTesting() {
        serialized { ring?.noteHALNotification() }
    }
    var ringStorageBytesForTesting: Int? { serialized { ring?.storageByteCount } }
    var ringCapacityForTesting: Int? { serialized { ring?.capacity } }
}
