// CameraActivityMonitor.swift
// Ad-hoc call detection — camera signal (docs/auto-call-detection-spec.md,
// camera phase). The complementary sensor to MicActivityMonitor: when a camera
// turns on and Transcripted is not already recording, that is strong evidence a
// meeting just started (a video call you joined camera-first, possibly muted).
//
// API choice (researched, not guessed): CoreMediaIO has NO public per-process
// camera-attribution API — there is no CMIO analog of Core Audio's
// kAudioHardwarePropertyProcessObjectList / kAudioProcessPropertyBundleID. The
// one public, on-device, metadata-only, TCC-free signal is the per-device
// boolean kCMIODevicePropertyDeviceIsRunningSomewhere ('gone') — the exact camera
// analog of kAudioDevicePropertyDeviceIsRunningSomewhere. Reading
// kCMIOHardwarePropertyDevices + that boolean enumerates and watches cameras
// without ever opening a stream, so it needs NO camera permission and NO
// NSCameraUsageDescription / com.apple.security.device.camera entitlement
// (same posture as the mic monitor; confirmed against OverSight/Guard, which
// detect camera-on exactly this way and read no frames). We never read video.
//
// Because the boolean has no attribution ("a camera is on" but not "which app"),
// the monitor emits only that boolean; MeetingPromptDetector attributes it to a
// provider using the concurrent mic signal and the frontmost app, and gates the
// camera-only case behind a known call app so a Photo Booth selfie stays quiet.
//
// Threading (root CLAUDE.md CoreAudio/CMIO rules): all CMIO reads, listeners, and
// mutable state are confined to one serial utility queue; listener callbacks only
// schedule a debounced re-scan; results hop to the main actor. `@unchecked
// Sendable` because mutable state is touched only on `queue`; assign `onChange`
// before `start()` and do not mutate it while running.
//
// Like the mic monitor we pair the listener edge with a periodic poll (CMIO
// running-somewhere listeners are documented to over- and under-fire) and pass
// every scan through `SustainedActivityConfirmer` so a momentary camera probe
// does not prompt.

import CoreMediaIO
import Foundation

@available(macOS 14.0, *)
final class CameraActivityMonitor: @unchecked Sendable {
    /// Delivered on the main actor: `true` when at least one camera has been
    /// running continuously for `sustainInterval`, `false` on the inactive edge.
    /// Assign before calling `start()` and do not mutate while running.
    var onChange: ((Bool) -> Void)?

    private let queue = DispatchQueue(label: "CameraActivityMonitor.cmio-devices", qos: .utility)
    private let debounceInterval: TimeInterval
    private let pollInterval: TimeInterval
    private let sustainInterval: TimeInterval

    /// Single key fed into the sustain confirmer: the camera signal is a boolean,
    /// so "in use" is modeled as the presence of one sentinel key.
    private static let cameraKey = "camera"

    // All of the following are touched only on `queue`.
    private var started = false
    private var systemListeners: [(address: CMIOObjectPropertyAddress, block: CMIOObjectPropertyListenerBlock)] = []
    private var deviceListeners: [(device: CMIOObjectID, address: CMIOObjectPropertyAddress, block: CMIOObjectPropertyListenerBlock)] = []
    private var backstopTimer: DispatchSourceTimer?
    private var debounceWorkItem: DispatchWorkItem?
    private var sustainWorkItem: DispatchWorkItem?
    private var activeSince: [String: Date] = [:]
    private var lastEmitted: Bool?

    init(
        debounceInterval: TimeInterval = 1.0,
        pollInterval: TimeInterval = 5.0,
        sustainInterval: TimeInterval = 3.0
    ) {
        self.debounceInterval = debounceInterval
        self.pollInterval = pollInterval
        self.sustainInterval = sustainInterval
    }

    // MARK: - Lifecycle (called on the main actor)

    func start() {
        queue.async { [weak self] in
            guard let self, !self.started else { return }
            self.started = true
            self.installSystemListener()
            self.reattachDeviceListeners()
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
            self.sustainWorkItem?.cancel()
            self.sustainWorkItem = nil
            self.activeSince = [:]
            self.lastEmitted = nil
        }
    }

    // MARK: - Pure decision helper (unit-tested; no CMIO)

    /// `true` when any enumerated camera reports running. Pulled out of the CMIO
    /// path so the aggregation rule is testable without live hardware. The
    /// "is this sustained, not a blip?" decision lives in
    /// `SustainedActivityConfirmer`; provider attribution lives in the detector.
    static func isCameraInUse(deviceRunningStates: [Bool]) -> Bool {
        deviceRunningStates.contains(true)
    }

    // MARK: - Scanning (on `queue`)

    private func scheduleDebouncedScan() {
        debounceWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.scanAndEmit() }
        debounceWorkItem = item
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: item)
    }

    private func scanAndEmit() {
        let inUse = Self.isCameraInUse(deviceRunningStates: cameraDeviceIDs().map(isRunningSomewhere))
        let now = Date()
        let outcome = SustainedActivityConfirmer.confirm(
            raw: inUse ? [Self.cameraKey] : [],
            activeSince: activeSince,
            now: now,
            sustain: sustainInterval
        )
        activeSince = outcome.activeSince
        scheduleSustainScan(at: outcome.nextDeadline, now: now)

        let confirmedInUse = !outcome.confirmed.isEmpty
        guard confirmedInUse != lastEmitted else { return }
        lastEmitted = confirmedInUse
        let callback = onChange
        DispatchQueue.main.async { callback?(confirmedInUse) }
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

    private func installSystemListener() {
        // The device list changes when a camera connects/disconnects (Continuity
        // Camera, an external webcam); re-enumerate and re-point per-device
        // listeners, then re-scan.
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.reattachDeviceListeners()
            self?.scheduleDebouncedScan()
        }
        let status = CMIOObjectAddPropertyListenerBlock(
            CMIOObjectID(kCMIOObjectSystemObject), &address, queue, block
        )
        if status == noErr {
            systemListeners.append((address, block))
        }
    }

    private func reattachDeviceListeners() {
        removeDeviceListeners()
        for device in cameraDeviceIDs() {
            var address = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
            )
            let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.scheduleDebouncedScan()
            }
            let status = CMIOObjectAddPropertyListenerBlock(device, &address, queue, block)
            if status == noErr {
                deviceListeners.append((device, address, block))
            }
        }
    }

    private func removeListeners() {
        for var listener in systemListeners {
            CMIOObjectRemovePropertyListenerBlock(
                CMIOObjectID(kCMIOObjectSystemObject), &listener.address, queue, listener.block
            )
        }
        systemListeners.removeAll()
        removeDeviceListeners()
    }

    private func removeDeviceListeners() {
        for var listener in deviceListeners {
            CMIOObjectRemovePropertyListenerBlock(listener.device, &listener.address, queue, listener.block)
        }
        deviceListeners.removeAll()
    }

    // MARK: - CMIO reads (on `queue`; read-only, no stored-state mutation)

    private func cameraDeviceIDs() -> [CMIOObjectID] {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(
            CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr else { return [] }

        let count = Int(dataSize) / MemoryLayout<CMIOObjectID>.size
        guard count > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: count)
        var used: UInt32 = 0
        let status = CMIOObjectGetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, dataSize, &used, &ids
        )
        return status == noErr ? ids : []
    }

    private func isRunningSomewhere(_ device: CMIOObjectID) -> Bool {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var value: UInt32 = 0
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        let status = CMIOObjectGetPropertyData(device, &address, 0, nil, size, &used, &value)
        return status == noErr && value != 0
    }
}
