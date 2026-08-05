// MicActivityMonitor.swift
// Ad-hoc call detection (docs/auto-call-detection-spec.md, Phase 1).
//
// Watches which processes are *currently holding the mic input* using the modern
// Core Audio process-object API (macOS 14.2+) and emits the set of non-self
// bundle IDs in a call. This reads metadata only — no audio is tapped and no
// NSAudioCaptureUsageDescription TCC permission is required (confirmed by the
// Phase 0 spike). The detector turns that set into a prompt.
//
// Threading (root CLAUDE.md CoreAudio rules): all CoreAudio reads, listeners,
// and mutable state are confined to a single serial utility queue. We never do
// heavy work in a property-listener callback beyond scheduling a scan, and we
// hop to the main actor to deliver results. The class is `@unchecked Sendable`
// because mutable runtime state is touched only on `queue`; assign `onChange`
// before `start()` and do not mutate it while the monitor is running.
//
// Why a backstop poll on top of listeners: the Phase 0 spike found that a call
// starting does NOT change kAudioHardwarePropertyProcessObjectList — the browser
// helper process already exists; only its IsRunningInput flag flips. So a pure
// process-list listener would miss the start. We listen on the input device's
// "is running somewhere" edge for low latency on the common path, and run a
// periodic process-object scan as a correctness guarantee for any edge a listener
// doesn't catch. That second case is more common than it sounds: the edge fires
// only on a 0→1 transition of the *default* input device's aggregate running
// state, so a call that starts while the device is already running (another app
// holds the mic, our own warmup touched it) or on a non-default device never
// trips the listener and falls entirely to the poll. The original 60s poll meant
// such calls surfaced up to a minute late — or, for a short call, never. The poll
// is now a few seconds (`pollInterval`); the process-object reads it performs are
// cheap, so this is the high-value reliability fix for "spontaneous browser calls
// feel invisible."
//
// Why a sustain gate: with a fast poll the raw signal would also fire on
// momentary mic access (a voice search, a permission probe). We pass every scan
// through `SustainedActivityConfirmer` and only emit a bundle once it has held
// the mic continuously for `sustainInterval`, re-scanning at the confirmation
// deadline so a genuine call still surfaces within a couple of seconds. This is
// the on-device "is this really a call?" check that lets us be aggressive on
// latency without prompting on every blip.
//
// Output side (listen-only call detection): the same process objects also expose
// kAudioProcessPropertyIsRunningOutput, so each scan additionally collects which
// *native conferencing apps* are playing audio output. That is the signal for
// the call the mic and camera both miss — a listen-only or hard-muted join where
// remote people are talking but nothing on this Mac holds the mic. Output is
// scoped to native conferencing families only (`MeetingPromptProvider
// .audioOutputProvider`): browser/media output is dominated by non-call playback
// and never enters the confirmer, so Spotify or YouTube cannot churn emissions.
// Output uses a longer sustain than the mic because conferencing apps also play
// short notification sounds (message dings, join chimes) that must not prompt.

import CoreAudio
import Foundation

@available(macOS 14.0, *)
final class MicActivityMonitor: @unchecked Sendable {
    /// Delivered on the main actor with the set of non-self bundle IDs currently
    /// holding the mic input. An empty set is the explicit "inactive" edge (the
    /// last mic user stopped). Assign before calling `start()` and do not mutate
    /// while running.
    var onChange: ((Set<String>) -> Void)?
    /// Delivered on the main actor with the set of native conferencing bundle IDs
    /// confirmed to be playing audio output (the listen-only call signal). An
    /// empty set is the explicit "inactive" edge. Assign before calling `start()`
    /// and do not mutate while running.
    var onOutputChange: ((Set<String>) -> Void)?
    /// Injected accessor for the shared `DefaultInputDeviceMonitor` facade
    /// (start/addObserver/removeObserver over the single
    /// `kAudioHardwarePropertyDefaultInputDevice` registration — see that
    /// file's header). Assign before calling `start()`, same contract as
    /// `onChange`/`onOutputChange` above; wired up in TranscriptedApp.swift.
    /// Kept as an injected protocol dependency rather than a direct
    /// `DefaultInputDeviceMonitor.shared` reference so this file — compiled
    /// standalone by the fast-test runner for the pure attribution helpers
    /// below (`Tests/MicActivityMonitorTests.swift`) — never has to pull in
    /// `DefaultInputDeviceMonitor.swift`'s EventReporter/CoreAudioInputDeviceLookup
    /// dependency graph. If left unset, this monitor keeps working — it just
    /// loses the fast device-reattach path and falls back to catching a mic
    /// switch on the next backstop poll (`pollInterval`, a few seconds).
    var defaultInputDeviceMonitor: DefaultInputDeviceSubscribing?

    private let ownBundleID: String
    private let queue = DispatchQueue(label: "MicActivityMonitor.process-objects", qos: .utility)
    private let debounceInterval: TimeInterval
    private let pollInterval: TimeInterval
    private let sustainInterval: TimeInterval
    private let outputSustainInterval: TimeInterval

    // All of the following are touched only on `queue`.
    private var started = false
    private var systemListeners: [(address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []
    private var deviceListener: (device: AudioObjectID, address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)?
    /// Subscription on the shared `DefaultInputDeviceMonitor` (see that
    /// file's header) that replaces this monitor's former direct
    /// `kAudioHardwarePropertyDefaultInputDevice` registration. Set/cleared
    /// only on `queue`, same as every other listener handle here, even
    /// though the subscribe/unsubscribe calls themselves have to hop to the
    /// main actor — see `subscribeToDefaultInputDeviceChanges`.
    private var defaultInputObserverToken: DefaultInputDeviceObserverToken?
    /// Bumped on every `start()`/`stop()` transition. The cross-actor hop in
    /// `subscribeToDefaultInputDeviceChanges` captures the generation at the
    /// moment it's kicked off; if `startGeneration` has moved on by the time
    /// the hop completes (a `stop()` — or a `stop()` then `start()` — ran in
    /// between), that subscription belongs to a superseded cycle and must be
    /// unsubscribed immediately instead of stored (codex review of PR #1640,
    /// P2: without this, a stale subscription from a superseded `start()`
    /// could win a race against the current one and get stored over it,
    /// leaking the current cycle's subscription so it keeps firing after
    /// `stop()`). See `MicActivityMonitorSubscriptionOutcome`.
    private var startGeneration = 0
    private var backstopTimer: DispatchSourceTimer?
    private var debounceWorkItem: DispatchWorkItem?
    private var sustainWorkItem: DispatchWorkItem?
    private var activeSince: [String: Date] = [:]
    private var outputActiveSince: [String: Date] = [:]
    private var lastEmitted: Set<String>?
    private var lastEmittedOutput: Set<String>?

    init(
        ownBundleID: String = Bundle.main.bundleIdentifier ?? "",
        debounceInterval: TimeInterval = 1.0,
        pollInterval: TimeInterval = 5.0,
        sustainInterval: TimeInterval = 3.0,
        outputSustainInterval: TimeInterval = 10.0
    ) {
        self.ownBundleID = ownBundleID
        self.debounceInterval = debounceInterval
        self.pollInterval = pollInterval
        self.sustainInterval = sustainInterval
        self.outputSustainInterval = outputSustainInterval
    }

    // MARK: - Lifecycle (called on the main actor)

    func start() {
        queue.async { [weak self] in
            guard let self, !self.started else { return }
            self.started = true
            self.startGeneration += 1
            self.installListeners()
            self.startBackstopTimer()
            self.scanAndEmit()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self, self.started else { return }
            self.started = false
            self.startGeneration += 1
            self.removeListeners()
            self.backstopTimer?.cancel()
            self.backstopTimer = nil
            self.debounceWorkItem?.cancel()
            self.debounceWorkItem = nil
            self.sustainWorkItem?.cancel()
            self.sustainWorkItem = nil
            self.activeSince = [:]
            self.outputActiveSince = [:]
            self.lastEmitted = nil
            self.lastEmittedOutput = nil
        }
    }

    // MARK: - Pure decision helpers (unit-tested; no CoreAudio)

    /// Whether an in-flight `DefaultInputDeviceMonitor` subscription (kicked
    /// off from `subscribeToDefaultInputDeviceChanges` during some `start()`
    /// call) should be stored once its cross-actor hop finishes, or dropped
    /// as stale. Split out as a pure decision so the start→stop→start race
    /// fix is unit-testable without touching CoreAudio or `Task` timing —
    /// see `startGeneration`'s doc comment for the scenario this guards
    /// against.
    enum SubscriptionOutcome: Equatable {
        case store
        case dropStale

        static func decide(isStarted: Bool, currentGeneration: Int, capturedGeneration: Int) -> SubscriptionOutcome {
            (isStarted && currentGeneration == capturedGeneration) ? .store : .dropStale
        }
    }

    /// Bundle IDs of processes that hold the mic input, minus our own. Pulled out
    /// of the CoreAudio path so the attribution + self-exclusion logic is testable
    /// without a live device.
    static func micUsingBundleIDs(
        from processes: [(bundleID: String?, isRunningInput: Bool)],
        ownBundleID: String
    ) -> Set<String> {
        let active = processes.compactMap { $0.isRunningInput ? $0.bundleID : nil }
        return nonSelfBundleIDs(Set(active), ownBundleID: ownBundleID)
    }

    /// Drops our own bundle ID (and any helper child of it) so we never treat our
    /// own capture as a detected call. Belt-and-suspenders with the detector's
    /// `isOwnCaptureActive` gate.
    static func nonSelfBundleIDs(_ bundleIDs: Set<String>, ownBundleID: String) -> Set<String> {
        guard !ownBundleID.isEmpty else { return bundleIDs }
        return bundleIDs.filter { !$0.matchesBundleFamily(ownBundleID) }
    }

    /// Bundle IDs of *native conferencing* processes currently playing audio
    /// output, minus our own. Deliberately narrower than the mic side: only
    /// bundles that map to a native provider via
    /// `MeetingPromptProvider.audioOutputProvider` count, so browsers and media
    /// apps never enter the sustain confirmer and cannot churn emissions. This is
    /// the listen-only / hard-muted call signal.
    static func callOutputBundleIDs(
        from processes: [(bundleID: String?, isRunningOutput: Bool)],
        ownBundleID: String
    ) -> Set<String> {
        let active = processes.compactMap { process -> String? in
            guard process.isRunningOutput, let bundleID = process.bundleID else { return nil }
            guard MeetingPromptProvider.audioOutputProvider(forBundleID: bundleID) != nil else { return nil }
            return bundleID
        }
        return nonSelfBundleIDs(Set(active), ownBundleID: ownBundleID)
    }

    // MARK: - Scanning (on `queue`)

    private func scheduleDebouncedScan() {
        debounceWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.scanAndEmit() }
        debounceWorkItem = item
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: item)
    }

    private func scanAndEmit() {
        let processes = currentProcessAudioState()
        let now = Date()

        let micRaw = Self.micUsingBundleIDs(
            from: processes.map { (bundleID: $0.bundleID, isRunningInput: $0.isRunningInput) },
            ownBundleID: ownBundleID
        )
        let micOutcome = SustainedActivityConfirmer.confirm(
            raw: micRaw,
            activeSince: activeSince,
            now: now,
            sustain: sustainInterval
        )
        activeSince = micOutcome.activeSince

        let outputRaw = Self.callOutputBundleIDs(
            from: processes.map { (bundleID: $0.bundleID, isRunningOutput: $0.isRunningOutput) },
            ownBundleID: ownBundleID
        )
        let outputOutcome = SustainedActivityConfirmer.confirm(
            raw: outputRaw,
            activeSince: outputActiveSince,
            now: now,
            sustain: outputSustainInterval
        )
        outputActiveSince = outputOutcome.activeSince

        // Re-scan exactly when the next pending bundle (either side) would cross
        // its sustain threshold, so a real call surfaces ~sustain after it starts
        // rather than waiting for the next backstop poll.
        let nextDeadline = [micOutcome.nextDeadline, outputOutcome.nextDeadline].compactMap { $0 }.min()
        scheduleSustainScan(at: nextDeadline, now: now)

        if micOutcome.confirmed != lastEmitted {
            lastEmitted = micOutcome.confirmed
            let callback = onChange
            let users = micOutcome.confirmed
            DispatchQueue.main.async { callback?(users) }
        }

        if outputOutcome.confirmed != lastEmittedOutput {
            lastEmittedOutput = outputOutcome.confirmed
            let callback = onOutputChange
            let users = outputOutcome.confirmed
            DispatchQueue.main.async { callback?(users) }
        }
    }

    private func scheduleSustainScan(at deadline: Date?, now: Date) {
        sustainWorkItem?.cancel()
        guard let deadline else {
            sustainWorkItem = nil
            return
        }
        let item = DispatchWorkItem { [weak self] in self?.scanAndEmit() }
        sustainWorkItem = item
        queue.asyncAfter(deadline: .now() + max(0, deadline.timeIntervalSince(now)), execute: item)
    }

    private func startBackstopTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        timer.setEventHandler { [weak self] in self?.scanAndEmit() }
        backstopTimer = timer
        timer.resume()
    }

    // MARK: - Listeners (on `queue`)

    private func installListeners() {
        // Process list changes catch a new conferencing app registering audio
        // (e.g. Zoom.app launching). The device "running somewhere" edge catches a
        // call starting/stopping on the default input. Default-device changes let
        // us re-point the running-somewhere listener when the user switches mics.
        addSystemListener(kAudioHardwarePropertyProcessObjectList)
        subscribeToDefaultInputDeviceChanges()
        reattachDeviceListener()
    }

    // Migrated to the shared `DefaultInputDeviceMonitor` (codebase audit
    // 2026-08 — see that file's header). This class's own former
    // `kAudioHardwarePropertyDefaultInputDevice` registration ran directly on
    // `queue`, matching its documented threading contract (CoreAudio
    // reads/listeners/mutable state confined to one serial queue). The shared
    // monitor is `@MainActor` and delivers on the main actor instead, so the
    // subscription closure re-hops onto `queue` before touching anything —
    // preserving that contract at the cost of one extra dispatch-queue
    // turnaround (sub-millisecond) ahead of the existing 1s
    // `scheduleDebouncedScan` debounce, which is not observable.
    //
    // isSelfWrite policy: handle unconditionally (ignore the flag). This
    // consumer never writes kAudioHardwarePropertyDefaultInputDevice, and
    // pre-migration it saw *every* notification — including
    // PersistentDictationInputController's self-reassertion writes — and
    // always ran `reattachDeviceListener()` in reaction (codex review of PR
    // #1640, P2: an earlier version of this migration had the monitor
    // globally swallow self-write notifications, which silently starved this
    // consumer of events it relied on and degraded call detection to the
    // multi-second backstop poll). Reacting to a self-write here is,
    // and always was, harmless read-only housekeeping — it just re-points
    // the "running somewhere" listener at whatever the current default input
    // is.
    private func subscribeToDefaultInputDeviceChanges() {
        guard let monitor = defaultInputDeviceMonitor else { return }
        let capturedGeneration = startGeneration
        Task { @MainActor [weak self, monitor] in
            guard let self else { return }
            monitor.start()
            let token = monitor.addObserver { [weak self] _ in
                self?.queue.async {
                    self?.reattachDeviceListener()
                    self?.scheduleDebouncedScan()
                }
            }
            self.queue.async {
                switch SubscriptionOutcome.decide(
                    isStarted: self.started,
                    currentGeneration: self.startGeneration,
                    capturedGeneration: capturedGeneration
                ) {
                case .store:
                    self.defaultInputObserverToken = token
                case .dropStale:
                    // Either stop() ran before this hop finished, or a
                    // stop()-then-start() cycle did — either way this
                    // subscription belongs to a superseded `start()` and must
                    // not be stored (it would either dangle past `stop()` or
                    // clobber the current cycle's token and leak this one).
                    Task { @MainActor in
                        monitor.removeObserver(token)
                    }
                }
            }
        }
    }

    private func unsubscribeFromDefaultInputDeviceChanges() {
        guard let token = defaultInputObserverToken, let monitor = defaultInputDeviceMonitor else {
            defaultInputObserverToken = nil
            return
        }
        defaultInputObserverToken = nil
        Task { @MainActor [monitor] in
            monitor.removeObserver(token)
        }
    }

    private func addSystemListener(_ selector: AudioObjectPropertySelector) {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleDebouncedScan()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue, block
        )
        if status == noErr {
            systemListeners.append((address, block))
        }
    }

    private func reattachDeviceListener() {
        removeDeviceListener()
        guard let device = defaultInputDeviceID() else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleDebouncedScan()
        }
        let status = AudioObjectAddPropertyListenerBlock(device, &address, queue, block)
        if status == noErr {
            deviceListener = (device, address, block)
        }
    }

    private func removeListeners() {
        for var listener in systemListeners {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &listener.address, queue, listener.block
            )
        }
        systemListeners.removeAll()
        removeDeviceListener()
        unsubscribeFromDefaultInputDeviceChanges()
    }

    private func removeDeviceListener() {
        guard var listener = deviceListener else { return }
        AudioObjectRemovePropertyListenerBlock(listener.device, &listener.address, queue, listener.block)
        deviceListener = nil
    }

    // MARK: - CoreAudio reads (on `queue`; read-only, no stored-state mutation)

    private func currentProcessAudioState() -> [(bundleID: String?, isRunningInput: Bool, isRunningOutput: Bool)] {
        processObjectIDs().map { object in
            (
                bundleID: bundleIDProperty(object),
                isRunningInput: isRunningInputProperty(object),
                isRunningOutput: isRunningOutputProperty(object)
            )
        }
    }

    private func processObjectIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: count)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &ids
        )
        return status == noErr ? ids : []
    }

    private func isRunningInputProperty(_ object: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        return status == noErr && value != 0
    }

    private func isRunningOutputProperty(_ object: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        return status == noErr && value != 0
    }

    private func bundleIDProperty(_ object: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var unmanaged: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &unmanaged)
        guard status == noErr, let unmanaged else { return nil }
        let bundleID = unmanaged.takeRetainedValue() as String
        return bundleID.isEmpty ? nil : bundleID
    }

    private func defaultInputDeviceID() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }
}
