import Foundation
@preconcurrency import AVFoundation
import CoreAudio
import Synchronization

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
    enum PendingOutput {
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
    /// A device that keeps announcing changes still gets rebuilt this long
    /// after the burst began, so it can never hold capture "settling" forever.
    static let maxFormatSettleSeconds: TimeInterval = 3
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
    /// meeting past that, so a 120 s hole (23 MB of mono 48 kHz) must not
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
    let configuration: Configuration
    let hardwareHooks: HardwareHooks?
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
    var format: AVAudioFormat?
    /// The live device format. Differs from `format` after the device changed
    /// rate or channels; `converter` then resamples back.
    var deviceFormat: AVAudioFormat?
    var converter: AVAudioConverter?
    var callback: ((AVAudioPCMBuffer) -> Void)?
    var eventHandler: ((PinnedMicrophoneCaptureEvent) -> Void)?
    private var timer: DispatchSourceTimer?
    /// Hardware is running (IOProc started).
    private var running = false
    /// Between a successful start and stop/finish, including while waiting
    /// for the owner to replace a lost device.
    private var active = false
    var tearingDown = false
    private var waitingForDevice = false
    /// Set by `fail`: waiting for nothing, the owner should stop.
    private var hasFailed = false
    var generation: UInt64 = 0
    private var lastBufferClock: TimeInterval = 0
    private var lastFormatCheck: TimeInterval = 0
    var expectedNextHostSeconds: TimeInterval?
    private var consecutiveRestarts = 0
    private var consecutiveFormatSettleRebuilds = 0
    private var sleepPendingSince: TimeInterval?
    private var wakeGraceUntil: TimeInterval?
    /// `ring.halNotifications` as last seen by the consumer.
    private var observedHALNotifications = 0
    /// When the current format change was last seen moving (a notification,
    /// a poll mismatch, or a producer invalidation). Nil while settled.
    private var formatSettleSince: TimeInterval?
    /// When the current format change was first seen.
    private var formatSettleStartedAt: TimeInterval?
    /// A HAL notification or poll mismatch, not only a producer layout
    /// mismatch, is behind the pending rebuild.
    private var formatSettleIsHALDriven = false
    /// Hardware is down between failed rebuild attempts on a live device.
    private var rebuildRetryAt: TimeInterval?
    private var rebuildRetryAttempt = 0
    private var rebuildRetryTrigger: PinnedMicrophoneRestartTrigger = .formatChange
    var pendingOutput: [PendingOutput] = []
    var silentInputRunSeconds: TimeInterval = 0
    var silentInputReported = false
    private var restartCount = 0
    var gapCount = 0
    var paddedSecondsTotal: TimeInterval = 0
    private var retiredDroppedCallbacks = 0
    /// Owner-facing copies, so main-thread readers never wait on `queue`
    /// while it is inside a slow HAL call. Written only from `queue`.
    private let snapshotLock = NSLock()
    private var snapshotDeviceID: AudioDeviceID
    private var snapshotDiagnostics = PinnedMicrophoneCaptureDiagnostics(
        restarts: 0,
        gaps: 0,
        paddedSeconds: 0,
        droppedCallbacks: 0
    )

    public init(deviceID: AudioDeviceID, configuration: Configuration = Configuration()) {
        pinnedDeviceID = deviceID
        snapshotDeviceID = deviceID
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
        snapshotDeviceID = deviceID
        self.configuration = configuration
        self.hardwareHooks = hardwareHooks
        self.clock = clock
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit { stop() }

    public var deviceID: AudioDeviceID { snapshotLock.withLock { snapshotDeviceID } }
    public var recordingFormat: AVAudioFormat? { serialized { format } }
    public var isActive: Bool { serialized { active } }
    /// True after `.deviceLost` (or a failed `switchDevice(to:)`) until the
    /// owner switches to another device or stops. False after `.failed`.
    public var isWaitingForDevice: Bool { serialized { active && waitingForDevice && !hasFailed } }
    /// As of the last timer tick, device switch or stop.
    public var diagnostics: PinnedMicrophoneCaptureDiagnostics { snapshotLock.withLock { snapshotDiagnostics } }

    /// Runs on `queue`.
    private func publishSnapshot() {
        let diagnostics = PinnedMicrophoneCaptureDiagnostics(
            restarts: restartCount,
            gaps: gapCount,
            paddedSeconds: paddedSecondsTotal,
            droppedCallbacks: retiredDroppedCallbacks + (ring?.dropped.load(ordering: .relaxed) ?? 0)
        )
        let deviceID = pinnedDeviceID
        snapshotLock.withLock {
            snapshotDiagnostics = diagnostics
            snapshotDeviceID = deviceID
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
            defer { publishSnapshot() }
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
        defer { publishSnapshot() }
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
        formatSettleStartedAt = nil
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
        defer { publishSnapshot() }
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
        if formatSettleSince != nil, formatSettleStartedAt == nil {
            formatSettleStartedAt = now
        }
        if let since = formatSettleSince {
            // Rebuild once, after the last notification of a burst, or once
            // the burst has run `maxFormatSettleSeconds`. Sleep and the wake
            // grace hold it off the same way they hold off a stall.
            let settled = now - since >= Self.formatSettleSeconds
            let settleCapped = now - (formatSettleStartedAt ?? since) >= Self.maxFormatSettleSeconds
            guard !deferred, settled || settleCapped else { return }
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
