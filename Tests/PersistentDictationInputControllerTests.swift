// PersistentDictationInputControllerTests.swift
//
// The faster-start ("keep the recommended mic active") preference moves the
// Mac-wide default input off AirPods. These suites run the real
// PersistentDictationInputController against a fake HAL, a fake shared
// default-input monitor, and throwaway preferences, then check what it wrote
// and reported. Mocked route proof only: real AirPods still need
// `bash check.sh hardware`.

import CoreAudio
import Foundation

func testPersistentDictationInputController() async {
    await runPersistentDictationInputControllerSuites()
}

@MainActor
private func runPersistentDictationInputControllerSuites() async {
    await runSuite("Persistent input - startup listens for default-input and device changes, and stopping removes both") {
        let hal = FakePersistentInputHAL(defaultInput: persistentBuiltIn)
        let controller = hal.makeController()

        controller.start()
        controller.start()
        assertEqual(hal.monitor.startCount, 1, "the shared default-input monitor is started once")
        assertEqual(hal.monitor.observerCount, 1, "one default-input subscription, even when start runs twice")
        assertEqual(hal.deviceListAdds, 1, "one device-list listener, so USB reconnects are seen")
        await controller.pendingRefresh?.value

        controller.stopMonitoring()
        assertEqual(hal.monitor.observerCount, 0, "stopping drops the default-input subscription")
        assertEqual(hal.deviceListRemoves, 1, "stopping removes the device-list listener it installed")

        hal.fireDeviceListChanged()
        hal.monitor.fire(isSelfWrite: false)
        assertTrue(controller.pendingRefresh == nil, "a late callback after stopping schedules nothing")
        assertEqual(hal.writes, [], "and writes nothing")

        let refused = FakePersistentInputHAL(defaultInput: persistentBuiltIn)
        refused.deviceListListenerRefused = true
        let refusedController = refused.makeController()
        refusedController.start()
        assertTrue(
            refused.reports.contains { $0.event == "dictation_persistent_input_device_listener_failed" && $0.level == .warning },
            "a refused device-list listener is reported, not silently dropped"
        )
        refusedController.stopMonitoring()
        assertEqual(refused.deviceListRemoves, 0, "nothing to remove when the HAL refused the listener")
    }

    await runSuite("Persistent input - a reconnected USB mic is picked up again") {
        let hal = FakePersistentInputHAL(defaultInput: persistentAirPods, inputs: [persistentAirPods, persistentBuiltIn])
        hal.defaults.set(persistentUSB.uid, forKey: "dictationPreferredInputDeviceUID")
        let controller = hal.makeController()
        controller.start()
        await controller.pendingRefresh?.value
        assertEqual(hal.writes, [persistentBuiltIn.id], "with the saved USB mic unplugged, the built-in mic replaces AirPods")

        hal.inputs.append(persistentUSB)
        hal.fireDeviceListChanged()
        await controller.pendingRefresh?.value
        assertEqual(hal.writes, [persistentBuiltIn.id, persistentUSB.id], "plugging the saved mic back in selects it")
        assertEqual(
            hal.marker,
            .init(selectedUID: "usb", previousUID: "airpods"),
            "the marker still remembers the mic from before Transcripted"
        )
        controller.stopMonitoring()
    }

    await runSuite("Persistent input - a default-input change alone is the user's choice, a reconnect is not") {
        // The user picks AirPods themselves: no device came or went.
        let picked = FakePersistentInputHAL(defaultInput: persistentAirPods, inputs: [persistentAirPods, persistentBuiltIn])
        let pickedController = picked.makeController()
        pickedController.start()
        picked.monitor.fire(isSelfWrite: false)
        await pickedController.pendingRefresh?.value
        assertEqual(picked.writes, [], "a plain default-input change is not overridden")
        assertTrue(
            picked.reports.contains { $0.event == "dictation_persistent_input_external_selection_preserved" },
            "preserving the user's pick is reported"
        )
        assertNil(picked.marker, "no restore marker is left behind for a mic we don't own")

        picked.fireDeviceListChanged()
        await pickedController.pendingRefresh?.value
        assertEqual(picked.writes, [], "once relinquished, later reconnects leave the user's pick alone")

        NotificationCenter.default.post(name: .dictationPersistentInputPreferenceChanged, object: nil)
        let reapplied = await waitForPersistentInput { picked.writes == [persistentBuiltIn.id] }
        assertTrue(reapplied, "changing the preference again takes ownership back")
        pickedController.stopMonitoring()

        // AirPods connect: macOS moves the default input and the device list changes.
        let connected = FakePersistentInputHAL(defaultInput: persistentAirPods, inputs: [persistentAirPods, persistentBuiltIn])
        let connectedController = connected.makeController()
        connectedController.start()
        connected.monitor.fire(isSelfWrite: false)
        connected.fireDeviceListChanged()
        await connectedController.pendingRefresh?.value
        assertEqual(connected.writes, [persistentBuiltIn.id], "a reconnect moves the input back to the recommended mic")
        connectedController.stopMonitoring()
    }

    await runSuite("Persistent input - its own writes don't trigger another pass") {
        let hal = FakePersistentInputHAL(defaultInput: persistentAirPods, inputs: [persistentAirPods, persistentBuiltIn])
        let controller = hal.makeController()
        controller.start()
        await controller.pendingRefresh?.value
        let finished = controller.pendingRefresh
        let delaysBefore = hal.refreshDelays

        hal.monitor.fire(isSelfWrite: true)
        assertTrue(controller.pendingRefresh == finished, "the echo of our own write schedules nothing")
        assertEqual(hal.refreshDelays, delaysBefore, "and starts no maintenance wait")
        controller.stopMonitoring()
    }

    await runSuite("Persistent input - launch and preference changes wait for live capture") {
        let hal = FakePersistentInputHAL(defaultInput: persistentAirPods, inputs: [persistentAirPods, persistentBuiltIn])
        var dictationActive = true
        var meetingActive = false
        let controller = hal.makeController(
            isDictationActive: { dictationActive },
            isMeetingCaptureActive: { meetingActive }
        )

        controller.start()
        assertEqual(hal.writes, [], "start never writes the Mac-wide input directly")
        let deferredLaunch = await waitForPersistentInput { hal.refreshDelays >= 3 }
        assertTrue(deferredLaunch, "launch maintenance keeps waiting")
        assertEqual(hal.writes, [], "while dictation is recording")
        dictationActive = false
        await controller.pendingRefresh?.value
        assertEqual(hal.writes, [persistentBuiltIn.id], "the write lands after dictation ends")

        hal.inputs.append(persistentUSB)
        hal.defaults.set(persistentUSB.uid, forKey: "dictationPreferredInputDeviceUID")
        meetingActive = true
        let delaysBefore = hal.refreshDelays
        NotificationCenter.default.post(name: .dictationPersistentInputPreferenceChanged, object: nil)
        assertEqual(hal.writes, [persistentBuiltIn.id], "a preference change never writes directly")
        let deferredChange = await waitForPersistentInput { hal.refreshDelays >= delaysBefore + 3 }
        assertTrue(deferredChange, "the preference change keeps waiting")
        assertEqual(hal.writes, [persistentBuiltIn.id], "while a meeting is recording")
        meetingActive = false
        let applied = await waitForPersistentInput { hal.writes == [persistentBuiltIn.id, persistentUSB.id] }
        assertTrue(applied, "the new preference lands after the meeting ends")
        controller.stopMonitoring()
    }

    await runSuite("Persistent input - quitting puts the previous mic back when nothing is capturing") {
        let hal = FakePersistentInputHAL(defaultInput: persistentAirPods, inputs: [persistentAirPods, persistentBuiltIn])
        let controller = hal.makeController()
        controller.start()
        await controller.pendingRefresh?.value
        assertEqual(hal.marker, .init(selectedUID: "builtin", previousUID: "airpods"), "taking over AirPods leaves a crash-recovery marker")

        await controller.stopAndRestore()
        assertEqual(hal.writes, [persistentBuiltIn.id, persistentAirPods.id], "quitting restores AirPods")
        assertNil(hal.marker, "a clean restore clears the marker")
        assertEqual(hal.monitor.observerCount, 0, "quitting also stops listening")
        assertEqual(hal.deviceListRemoves, 1, "including the device-list listener")
    }

    await runSuite("Persistent input - app Quit waits for the restore before replying to AppKit") {
        let hal = FakePersistentInputHAL(defaultInput: persistentAirPods, inputs: [persistentAirPods, persistentBuiltIn])
        let controller = hal.makeController()
        controller.start()
        await controller.pendingRefresh?.value

        var writesAtReply: [UInt32] = []
        let quit = await AppTerminationSequence.run(AppTerminationSequence.Steps(
            finishDictationForTermination: { true },
            resetCleanupAdmission: {},
            prepareMeetingForTermination: {},
            shutDownAppState: {},
            stopAndRestorePersistentInput: { await controller.stopAndRestore() },
            flushLocalEvents: {},
            markCleanupFinished: {},
            replyToPendingRequests: { _ in writesAtReply = hal.writes }
        ))
        assertTrue(quit, "Quit goes ahead")
        assertEqual(writesAtReply, [persistentBuiltIn.id, persistentAirPods.id], "AirPods are back before AppKit is told to terminate")
    }

    await runSuite("Persistent input - quitting during another app's call leaves the input and keeps the marker") {
        let hal = FakePersistentInputHAL(defaultInput: persistentAirPods, inputs: [persistentAirPods, persistentBuiltIn])
        let controller = hal.makeController()
        controller.start()
        await controller.pendingRefresh?.value

        hal.external.setActive(true)
        await controller.stopAndRestore()
        assertEqual(hal.writes, [persistentBuiltIn.id], "another app's call is not disturbed on quit")
        assertEqual(hal.marker, .init(selectedUID: "builtin", previousUID: "airpods"), "the marker stays so a later idle launch can restore")
    }

    await runSuite("Persistent input - a blocked driver read can't stop the app from quitting") {
        let hal = FakePersistentInputHAL(defaultInput: persistentAirPods, inputs: [persistentAirPods, persistentBuiltIn])
        let controller = hal.makeController()
        controller.start()
        await controller.pendingRefresh?.value

        hal.external.blockReads()
        await controller.stopAndRestore()
        assertEqual(hal.writes, [persistentBuiltIn.id], "an unanswered activity read is not treated as idle")
        assertEqual(hal.marker, .init(selectedUID: "builtin", previousUID: "airpods"), "the skipped restore keeps its durable marker")
        hal.external.unblockReads()
    }

    await runSuite("Persistent input - quitting leaves a mic the user picked afterwards") {
        let hal = FakePersistentInputHAL(defaultInput: persistentAirPods, inputs: [persistentAirPods, persistentBuiltIn, persistentUSB])
        let controller = hal.makeController()
        controller.start()
        await controller.pendingRefresh?.value

        hal.defaultInputID = persistentUSB.id
        await controller.stopAndRestore()
        assertEqual(hal.writes, [persistentBuiltIn.id], "the user's later pick is not replaced by the old mic")
        assertNil(hal.marker, "and we no longer claim the input")
        assertTrue(
            hal.reports.contains { $0.event == "dictation_persistent_input_restore_skipped" },
            "the skipped restore is reported"
        )
    }
}

// MARK: - Fakes

private let persistentAirPods = DictationAudioDevice(id: 1, name: "AirPods Pro", transport: .bluetooth, inputChannelCount: 1, uid: "airpods")
private let persistentAirPodsOutput = DictationAudioDevice(id: 2, name: "AirPods Pro", transport: .bluetooth, inputChannelCount: 0, uid: "airpods-out")
private let persistentBuiltIn = DictationAudioDevice(id: 3, name: "MacBook Pro Microphone", transport: .builtIn, inputChannelCount: 1, uid: "builtin")
private let persistentUSB = DictationAudioDevice(id: 4, name: "USB Mic", transport: .usb, inputChannelCount: 1, uid: "usb")

/// Waits for an outcome, giving up after a generous number of short sleeps.
/// Callers assert on the outcome, never on elapsed time.
@MainActor
private func waitForPersistentInput(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<5_000 {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return condition()
}

@MainActor
private final class FakeDefaultInputMonitor: DefaultInputDeviceSubscribing, @unchecked Sendable {
    private var registry = DefaultInputDeviceObserverRegistry()
    private(set) var startCount = 0

    var observerCount: Int { registry.count }

    func start() { startCount += 1 }

    @discardableResult
    func addObserver(_ handler: @escaping (Bool) -> Void) -> DefaultInputDeviceObserverToken {
        registry.add(handler)
    }

    func removeObserver(_ token: DefaultInputDeviceObserverToken) {
        registry.remove(token)
    }

    func fire(isSelfWrite: Bool) {
        registry.notifyAll(isSelfWrite: isSelfWrite)
    }
}

/// Another app's mic activity, read off the main actor like the real HAL call.
private final class FakeExternalInputActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false
    private var gate: DispatchSemaphore?

    func setActive(_ value: Bool) {
        lock.lock(); active = value; lock.unlock()
    }

    func blockReads() {
        lock.lock(); gate = DispatchSemaphore(value: 0); lock.unlock()
    }

    func unblockReads() {
        lock.lock(); let gate = self.gate; self.gate = nil; lock.unlock()
        gate?.signal()
    }

    func read() -> Bool {
        lock.lock(); let gate = self.gate; let active = self.active; lock.unlock()
        gate?.wait()
        return active
    }
}

@MainActor
private final class FakePersistentInputHAL {
    let defaults: UserDefaults
    let monitor = FakeDefaultInputMonitor()
    let external = FakeExternalInputActivity()
    var inputs: [DictationAudioDevice]
    var defaultInputID: UInt32
    var writes: [UInt32] = []
    var reports: [PersistentDictationInputSystem.Report] = []
    var deviceListListenerRefused = false
    var deviceListAdds = 0
    var deviceListRemoves = 0
    var refreshDelays = 0
    private var deviceListHandler: (@MainActor () -> Void)?

    init(defaultInput: DictationAudioDevice, inputs: [DictationAudioDevice]? = nil) {
        let suiteName = "PersistentDictationInputControllerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        // The opt-in is on and the Mac mic recorder is off, so the toggle owns the input.
        defaults.set(true, forKey: "dictationKeepRecommendedMicrophoneActive")
        defaults.set(false, forKey: PinnedMicrophoneCapturePreferences.userDefaultsKey)
        self.inputs = inputs ?? [defaultInput]
        self.defaultInputID = defaultInput.id
    }

    var marker: DictationPersistentInputPreferences.RecoveryMarker? {
        DictationPersistentInputPreferences.recoveryMarker(userDefaults: defaults)
    }

    func fireDeviceListChanged() {
        deviceListHandler?()
    }

    func makeController(
        isDictationActive: @escaping () -> Bool = { false },
        isMeetingCaptureActive: @escaping () -> Bool = { false }
    ) -> PersistentDictationInputController {
        PersistentDictationInputController(
            isDictationActive: isDictationActive,
            isMeetingCaptureActive: isMeetingCaptureActive,
            system: system()
        )
    }

    private func currentInput() throws -> DictationAudioDevice {
        guard let device = inputs.first(where: { $0.id == defaultInputID }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return device
    }

    private func system() -> PersistentDictationInputSystem {
        let external = self.external
        return PersistentDictationInputSystem(
            userDefaults: defaults,
            defaultInputMonitor: monitor,
            setDefaultInput: { [weak self] id in
                self?.writes.append(id)
                self?.defaultInputID = id
            },
            addDeviceListListener: { [weak self] handler in
                guard let self, !self.deviceListListenerRefused else { return nil }
                self.deviceListAdds += 1
                self.deviceListHandler = handler
                return { _, _ in }
            },
            removeDeviceListListener: { [weak self] _ in
                self?.deviceListRemoves += 1
                self?.deviceListHandler = nil
            },
            recommendedSelection: { [weak self] in
                guard let self else { throw CancellationError() }
                return DictationInputDeviceSelectionPolicy.selection(
                    defaultInput: try self.currentInput(),
                    defaultOutput: persistentAirPodsOutput,
                    availableInputs: self.inputs,
                    prefersBuiltInBluetoothInput: true
                )
            },
            availableInputs: { [weak self] in self?.inputs ?? [] },
            currentDefaultInputID: { [weak self] in
                guard let self else { throw CancellationError() }
                return self.defaultInputID
            },
            hasExternalInputActivity: { external.read() },
            report: { [weak self] in self?.reports.append($0) },
            refreshDelay: { [weak self] in
                self?.refreshDelays += 1
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
        )
    }
}
