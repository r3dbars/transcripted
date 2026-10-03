// HALListenerRegistrationTests.swift
//
// The app's first CoreAudio call pays for HAL client init, which once froze
// launch for 5 s+ on the main thread. The two launch-time listener adds
// (default input, device list) now run on one serial queue off main. These
// suites check the promises that move keeps: one add per registration, a stop
// while the add is pending removes the same block, a failed add retries, the
// caller never waits on the add, and the faster-start controller runs no
// reconcile or Mac-wide write until both listeners are live. Fakes only; real
// AirPods still need `bash check.sh hardware`.

import CoreAudio
import Foundation

func testHALListenerRegistration() async {
    await runHALListenerRegistrationSuites()
}

@MainActor
private func runHALListenerRegistrationSuites() async {
    runSuite("HAL registration - a second start while the add is pending queues nothing") {
        let fake = FakeListenerRegistrar()
        let registrar = fake.makeRegistrar()

        assertTrue(registrar.start(HALToken(), onFailure: { _ in }), "the first start queues the add")
        assertFalse(registrar.start(HALToken(), onFailure: { _ in }), "a start while pending is a no-op")
        assertEqual(fake.adds.count, 1, "only one HAL add goes out")
        assertTrue(registrar.isActive, "a pending add counts as active")
        assertFalse(registrar.isRegistered, "but not yet registered")

        fake.complete(0, status: noErr)
        assertTrue(registrar.isRegistered, "a successful add is registered")
        assertFalse(registrar.start(HALToken(), onFailure: { _ in }), "a start once registered is a no-op too")
        assertEqual(fake.adds.count, 1, "still one add")
    }

    runSuite("HAL registration - observers added while pending are notified in order") {
        let fake = FakeListenerRegistrar()
        let registrar = fake.makeRegistrar()
        var registry = DefaultInputDeviceObserverRegistry()
        var order: [String] = []

        registrar.start(HALToken(), onFailure: { _ in })
        registry.add { _ in order.append("A") }
        registry.add { _ in order.append("B") }
        fake.complete(0, status: noErr)
        registry.notifyAll(isSelfWrite: false)

        assertEqual(order, ["A", "B"], "the persistent controller (first) still hears first")
    }

    runSuite("HAL registration - a stop while pending removes the same block once the add lands") {
        let fake = FakeListenerRegistrar()
        let registrar = fake.makeRegistrar()
        let token = HALToken()
        let generationBefore = registrar.generation

        registrar.start(token, onFailure: { _ in })
        assertTrue(registrar.stop(), "stop while pending tears down")
        assertFalse(registrar.isActive, "and goes idle")
        assertTrue(registrar.generation != generationBefore, "late results from the old registration are stale")
        assertTrue(fake.removes.isEmpty, "nothing to remove before the add returns")

        fake.complete(0, status: noErr)
        assertEqual(fake.removes.count, 1, "the late add is undone exactly once")
        assertTrue(fake.removes.first === token, "with the same block it added")
        assertFalse(registrar.isActive, "still idle")

        registrar.start(HALToken(), onFailure: { _ in })
        assertEqual(fake.adds.count, 2, "a later start adds again")
    }

    runSuite("HAL registration - a stop while pending, then a new start, only undoes the old add") {
        let fake = FakeListenerRegistrar()
        let registrar = fake.makeRegistrar()
        let first = HALToken()
        let second = HALToken()

        registrar.start(first, onFailure: { _ in })
        registrar.stop()
        registrar.start(second, onFailure: { _ in })
        fake.complete(0, status: noErr)
        assertEqual(fake.removes.count, 1, "the stale add is removed")
        assertTrue(fake.removes.first === first, "and only the stale one")
        assertTrue(registrar.isActive, "the new registration is still pending")

        fake.complete(1, status: noErr)
        assertTrue(registrar.isRegistered, "the new add is adopted")
        assertEqual(fake.removes.count, 1, "and not removed")
    }

    runSuite("HAL registration - a refused add reports its status once and a later start retries") {
        let fake = FakeListenerRegistrar()
        let registrar = fake.makeRegistrar()
        var failures: [OSStatus] = []

        registrar.start(HALToken(), onFailure: { failures.append($0) })
        fake.complete(0, status: -50)
        assertEqual(failures, [-50], "one failure, carrying only the status code")
        assertFalse(registrar.isActive, "a failed add goes back to idle")
        assertTrue(fake.removes.isEmpty, "nothing to remove for a refused add")

        registrar.start(HALToken(), onFailure: { failures.append($0) })
        assertEqual(fake.adds.count, 2, "the next start retries")
        fake.complete(1, status: noErr)
        assertTrue(registrar.isRegistered, "and the retry can succeed")
        assertEqual(failures, [-50], "with no extra failure")
    }

    runSuite("HAL registration - stopping a live listener removes it, and a refused remove keeps it") {
        let fake = FakeListenerRegistrar()
        let registrar = fake.makeRegistrar()
        let token = HALToken()
        registrar.start(token, onFailure: { _ in })
        fake.complete(0, status: noErr)

        fake.removeStatus = -1
        assertFalse(registrar.stop(), "a refused remove reports nothing torn down")
        assertTrue(registrar.isRegistered, "and keeps the registration, as before")

        fake.removeStatus = noErr
        assertTrue(registrar.stop(), "a successful remove tears down")
        assertTrue(fake.removes.last === token, "with the block that was added")
        assertFalse(registrar.isActive, "and goes idle")
        assertFalse(registrar.stop(), "stopping again does nothing")
    }

    await runSuite("HAL registration - the caller never waits on a blocked add") {
        let gate = DispatchSemaphore(value: 0)
        let progress = RegistrationProgress()

        HALListenerRegistrationQueue.run({ () -> Int in
            progress.mark("work started")
            gate.wait()
            return 7
        }, then: { value in
            progress.mark("completed \(value) on main=\(Thread.isMainThread)")
        })
        HALListenerRegistrationQueue.run({ () -> Int in 8 }, then: { value in
            progress.mark("completed \(value) on main=\(Thread.isMainThread)")
        })
        progress.mark("caller moved on")

        let started = await waitForRegistration { progress.contains("work started") }
        assertTrue(started, "the add runs off the caller's thread")
        assertFalse(progress.contains("completed 7 on main=true"), "and has not finished while the HAL is blocked")
        assertTrue(progress.contains("caller moved on"), "while the caller already moved on to its next launch step")

        gate.signal()
        let finished = await waitForRegistration { progress.contains("completed 8 on main=true") }
        assertTrue(finished, "results come back on main once the HAL answers")
        assertEqual(
            progress.entries.filter { $0.hasPrefix("completed") },
            ["completed 7 on main=true", "completed 8 on main=true"],
            "in the order the adds were queued"
        )
    }

    await runSuite("Persistent input - nothing reconciles or writes until the device-list add lands") {
        let hal = HeldRegistrationHAL(defaultInput: heldAirPods, inputs: [heldAirPods, heldBuiltIn])
        let controller = hal.makeController()

        controller.start()
        assertEqual(hal.monitor.startCount, 1, "the shared monitor is started right away")
        assertEqual(hal.monitor.observerCount, 1, "and subscribed synchronously, so delivery order is unchanged")
        assertEqual(hal.deviceListAdds, 0, "the device-list add has not run on the caller's thread")
        assertTrue(controller.pendingRefresh == nil, "no reconcile is scheduled yet")
        assertEqual(hal.writes, [], "and nothing is written")

        hal.releaseRegistrations()
        assertEqual(hal.deviceListAdds, 1, "the device-list add ran")
        assertTrue(controller.pendingRefresh != nil, "the first reconcile is scheduled once both listeners are live")
        await controller.pendingRefresh?.value
        assertEqual(hal.writes, [heldBuiltIn.id], "and AirPods are replaced as before")
        controller.stopMonitoring()
        assertEqual(hal.deviceListRemoves, 1, "stopping removes the adopted listener")
    }

    await runSuite("Persistent input - a default-input change after registration is still the user's choice") {
        let hal = HeldRegistrationHAL(defaultInput: heldAirPods, inputs: [heldAirPods, heldBuiltIn])
        let controller = hal.makeController()

        controller.start()
        hal.releaseRegistrations()
        hal.monitor.fire(isSelfWrite: false)
        await controller.pendingRefresh?.value
        assertEqual(hal.writes, [], "a plain default-input change is not overridden")
        assertTrue(
            hal.reports.contains { $0.event == "dictation_persistent_input_external_selection_preserved" },
            "preserving the user's pick is reported"
        )
        controller.stopMonitoring()
    }

    runSuite("Persistent input - stopping while the device-list add is pending undoes it") {
        let hal = HeldRegistrationHAL(defaultInput: heldAirPods, inputs: [heldAirPods, heldBuiltIn])
        let controller = hal.makeController()

        controller.start()
        controller.stopMonitoring()
        assertEqual(hal.deviceListRemoves, 0, "nothing to remove before the add returns")
        hal.releaseRegistrations()
        assertEqual(hal.deviceListAdds, 1, "the queued add still ran")
        assertEqual(hal.deviceListRemoves, 1, "and is removed as soon as it lands")
        assertTrue(controller.pendingRefresh == nil, "a stopped controller schedules nothing")
        hal.fireDeviceListChanged()
        assertTrue(controller.pendingRefresh == nil, "and ignores a late device-list callback")
        assertEqual(hal.writes, [], "and writes nothing")
    }

    await runSuite("Persistent input - a refused device-list add is reported once it returns") {
        let hal = HeldRegistrationHAL(defaultInput: heldBuiltIn)
        hal.deviceListListenerRefused = true
        let controller = hal.makeController()

        controller.start()
        assertFalse(
            hal.reports.contains { $0.event == "dictation_persistent_input_device_listener_failed" },
            "no verdict before the HAL answers"
        )
        hal.releaseRegistrations()
        assertTrue(
            hal.reports.contains { $0.event == "dictation_persistent_input_device_listener_failed" && $0.level == .warning },
            "the refusal keeps its warning"
        )
        assertTrue(controller.pendingRefresh != nil, "the first reconcile still runs")
        await controller.pendingRefresh?.value
        controller.stopMonitoring()
        assertEqual(hal.deviceListRemoves, 0, "nothing to remove when the HAL refused the listener")
    }
}

// MARK: - Fakes

private final class HALToken {}

@MainActor
private final class FakeListenerRegistrar {
    private(set) var adds: [(token: HALToken, completion: @MainActor (OSStatus) -> Void)] = []
    private(set) var removes: [HALToken] = []
    var removeStatus: OSStatus = noErr

    func makeRegistrar() -> DefaultInputDeviceListenerRegistrar<HALToken> {
        DefaultInputDeviceListenerRegistrar<HALToken>(
            add: { [unowned self] token, completion in
                self.adds.append((token, completion))
            },
            remove: { [unowned self] token in
                self.removes.append(token)
                return self.removeStatus
            }
        )
    }

    func complete(_ index: Int, status: OSStatus) {
        adds[index].completion(status)
    }
}

private final class RegistrationProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []

    func mark(_ entry: String) {
        lock.withLock { log.append(entry) }
    }

    func contains(_ entry: String) -> Bool {
        lock.withLock { log.contains(entry) }
    }

    var entries: [String] { lock.withLock { log } }
}

/// Waits for an outcome, giving up after a generous number of short sleeps.
/// Callers assert on the outcome, never on elapsed time.
@MainActor
private func waitForRegistration(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<5_000 {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return condition()
}

private let heldAirPods = DictationAudioDevice(id: 1, name: "AirPods Pro", transport: .bluetooth, inputChannelCount: 1, uid: "airpods")
private let heldAirPodsOutput = DictationAudioDevice(id: 2, name: "AirPods Pro", transport: .bluetooth, inputChannelCount: 0, uid: "airpods-out")
private let heldBuiltIn = DictationAudioDevice(id: 3, name: "MacBook Pro Microphone", transport: .builtIn, inputChannelCount: 1, uid: "builtin")

@MainActor
private final class HeldMonitor: DefaultInputDeviceSubscribing, @unchecked Sendable {
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

/// A HAL whose listener adds sit on the registration queue until the test
/// releases them, like a launch where HAL client init is slow.
@MainActor
private final class HeldRegistrationHAL {
    let defaults: UserDefaults
    let monitor = HeldMonitor()
    var inputs: [DictationAudioDevice]
    var defaultInputID: UInt32
    var writes: [UInt32] = []
    var reports: [PersistentDictationInputSystem.Report] = []
    var deviceListListenerRefused = false
    var deviceListAdds = 0
    var deviceListRemoves = 0
    private var deviceListHandler: (@MainActor () -> Void)?
    private var held: [@MainActor () -> Void] = []

    init(defaultInput: DictationAudioDevice, inputs: [DictationAudioDevice]? = nil) {
        let suiteName = "HALListenerRegistrationTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: "dictationKeepRecommendedMicrophoneActive")
        defaults.set(false, forKey: PinnedMicrophoneCapturePreferences.userDefaultsKey)
        self.inputs = inputs ?? [defaultInput]
        self.defaultInputID = defaultInput.id
    }

    func releaseRegistrations() {
        let pending = held
        held = []
        for registration in pending { registration() }
    }

    func fireDeviceListChanged() {
        deviceListHandler?()
    }

    func makeController() -> PersistentDictationInputController {
        PersistentDictationInputController(system: system())
    }

    private func currentInput() throws -> DictationAudioDevice {
        guard let device = inputs.first(where: { $0.id == defaultInputID }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return device
    }

    private func system() -> PersistentDictationInputSystem {
        PersistentDictationInputSystem(
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
                    defaultOutput: heldAirPodsOutput,
                    availableInputs: self.inputs,
                    prefersBuiltInBluetoothInput: true
                )
            },
            availableInputs: { [weak self] in self?.inputs ?? [] },
            currentDefaultInputID: { [weak self] in
                guard let self else { throw CancellationError() }
                return self.defaultInputID
            },
            hasExternalInputActivity: { false },
            report: { [weak self] in self?.reports.append($0) },
            refreshDelay: { try? await Task.sleep(nanoseconds: 1_000_000) },
            registerListener: { [weak self] work, completion in
                self?.held.append {
                    let listener = work()
                    completion(listener)
                }
            }
        )
    }
}
