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
// "is running somewhere" edge for low latency on the common path, and run a small
// slower periodic scan as a correctness guarantee for any edge a listener
// doesn't catch (e.g. capture on a non-default device). The listener gives the
// fast common path; the poll is intentionally slower for idle battery life.

import CoreAudio
import Foundation

@available(macOS 14.0, *)
final class MicActivityMonitor: @unchecked Sendable {
    /// Delivered on the main actor with the set of non-self bundle IDs currently
    /// holding the mic input. An empty set is the explicit "inactive" edge (the
    /// last mic user stopped). Assign before calling `start()` and do not mutate
    /// while running.
    var onChange: ((Set<String>) -> Void)?

    private let ownBundleID: String
    private let queue = DispatchQueue(label: "MicActivityMonitor.process-objects", qos: .utility)
    private let debounceInterval: TimeInterval
    private let pollInterval: TimeInterval

    // All of the following are touched only on `queue`.
    private var started = false
    private var systemListeners: [(address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []
    private var deviceListener: (device: AudioObjectID, address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)?
    private var backstopTimer: DispatchSourceTimer?
    private var debounceWorkItem: DispatchWorkItem?
    private var lastEmitted: Set<String>?

    init(
        ownBundleID: String = Bundle.main.bundleIdentifier ?? "",
        debounceInterval: TimeInterval = 1.0,
        pollInterval: TimeInterval = 60.0
    ) {
        self.ownBundleID = ownBundleID
        self.debounceInterval = debounceInterval
        self.pollInterval = pollInterval
    }

    // MARK: - Lifecycle (called on the main actor)

    func start() {
        queue.async { [weak self] in
            guard let self, !self.started else { return }
            self.started = true
            self.installListeners()
            self.startBackstopTimer()
            self.scanAndEmit()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self, self.started else { return }
            self.started = false
            self.removeListeners()
            self.backstopTimer?.cancel()
            self.backstopTimer = nil
            self.debounceWorkItem?.cancel()
            self.debounceWorkItem = nil
            self.lastEmitted = nil
        }
    }

    // MARK: - Pure decision helpers (unit-tested; no CoreAudio)

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

    // MARK: - Scanning (on `queue`)

    private func scheduleDebouncedScan() {
        debounceWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.scanAndEmit() }
        debounceWorkItem = item
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: item)
    }

    private func scanAndEmit() {
        let users = Self.micUsingBundleIDs(from: currentProcessInputState(), ownBundleID: ownBundleID)
        guard users != lastEmitted else { return }
        lastEmitted = users
        let callback = onChange
        DispatchQueue.main.async { callback?(users) }
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
        addSystemListener(kAudioHardwarePropertyDefaultInputDevice) { [weak self] in
            self?.reattachDeviceListener()
        }
        reattachDeviceListener()
    }

    private func addSystemListener(
        _ selector: AudioObjectPropertySelector,
        extra: (() -> Void)? = nil
    ) {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            extra?()
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
    }

    private func removeDeviceListener() {
        guard var listener = deviceListener else { return }
        AudioObjectRemovePropertyListenerBlock(listener.device, &listener.address, queue, listener.block)
        deviceListener = nil
    }

    // MARK: - CoreAudio reads (on `queue`; read-only, no stored-state mutation)

    private func currentProcessInputState() -> [(bundleID: String?, isRunningInput: Bool)] {
        processObjectIDs().map { object in
            (bundleID: bundleIDProperty(object), isRunningInput: isRunningInputProperty(object))
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
