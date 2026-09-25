import Foundation

@MainActor
func testDictationInputBindingSettle() async {
    let mic = DictationAudioDevice(id: 30, name: "Synthetic USB", transport: .usb, inputChannelCount: 1)
    let selection = DictationInputDeviceSelection(defaultInput: mic, selectedInput: mic,
        defaultOutput: nil, reason: .defaultIsSafe)
    // Synthetic driver: every write restarts an 800ms transition. This models
    // the failure mechanism, not evidence from a physical C920.
    var clock: UInt64 = 0
    var readyAt: UInt64 = .max
    var writes = 0
    let driverDelay: UInt64 = 800_000_000
    let set: (UInt32) -> Void = { _ in writes += 1; readyAt = clock + driverDelay }
    let read: () -> UInt32 = { clock >= readyAt ? mic.id : 0 }
    do {
        // Old 300ms single-check + 300ms retry never reaches this driver's ID.
        for _ in 0..<10 {
            try DictationInputDeviceBindingPolicy.apply(selection: selection, currentDeviceID: read, setDeviceID: set)
            clock += 300_000_000
            assertEqual(read(), 0, "control: resetting a pending command starves slow settling")
            clock += 300_000_000
        }
        clock = 0; readyAt = .max; writes = 0
        try DictationInputDeviceBindingPolicy.apply(selection: selection, currentDeviceID: read, setDeviceID: set)
        var budgets: [UInt64] = []
        let result = try await DictationInputDeviceBindingPolicy.waitForBinding(
            now: { clock }, sleep: { clock += $0 }, isCurrent: { true }
        ) { budget in
            budgets.append(budget)
            try DictationInputDeviceBindingPolicy.verify(selectedDeviceID: mic.id, boundDeviceID: read())
            return read()
        }
        assertEqual(result, mic.id, "slow binding eventually verifies the requested device")
        assertEqual(writes, 1, "polling must not reset the pending USB transition")
        assertEqual(clock, driverDelay, "finish when binding settles rather than waiting the entire budget")
        assertTrue(zip(budgets, budgets.dropFirst()).allSatisfy { $0 > $1 }, "native probes get shrinking timeouts")
    } catch { assertTrue(false, "slow-settle scenario failed: \(error)") }

    // An input that is already bound verifies on the first probe, with no
    // fixed settle delay in front of it.
    clock = 0
    do {
        let result: UInt32 = try await DictationInputDeviceBindingPolicy.waitForBinding(
            now: { clock }, sleep: { clock += $0 }, isCurrent: { true }
        ) { _ in
            try DictationInputDeviceBindingPolicy.verify(selectedDeviceID: mic.id, boundDeviceID: mic.id)
            return mic.id
        }
        assertEqual(result, mic.id, "an already-bound input verifies")
        assertEqual(clock, 0, "an already-bound input starts without a settle delay")
    } catch { assertTrue(false, "already-bound scenario failed: \(error)") }

    let airPods = DictationAudioDevice(id: 1, name: "AirPods Pro", transport: .bluetooth, inputChannelCount: 1)
    let skipsHeadset = DictationInputDeviceSelection(defaultInput: airPods, selectedInput: mic,
        defaultOutput: nil, reason: .preferredBuiltInForBluetoothHeadset)
    assertEqual(
        DictationInputDeviceBindingPolicy.initialSettleDelay(for: skipsHeadset),
        TranscriptedConstants.audioRecoveryDelay,
        "moving off a Bluetooth macOS input keeps the settle before the engine starts"
    )
    assertEqual(DictationInputDeviceBindingPolicy.initialSettleDelay(for: selection), 0, "a safe macOS input starts without a settle")

    for staleID in [UInt32(0), UInt32(10)] {
        clock = 0
        var probes = 0
        do {
            let _: UInt32 = try await DictationInputDeviceBindingPolicy.waitForBinding(
                now: { clock }, sleep: { clock += $0 }, isCurrent: { true }
            ) { _ in
                probes += 1
                try DictationInputDeviceBindingPolicy.verify(selectedDeviceID: mic.id, boundDeviceID: staleID)
                return staleID
            }
            assertTrue(false, "a stale or disconnected input must never become ready")
        } catch {
            assertEqual(error as? DictationInputDeviceBindingError, .selectedDeviceNotBound, "expired binding fails closed")
        }
        assertEqual(clock, TranscriptedConstants.audioInputBindingSettleTimeout, "invalid device polling has a hard limit")
        assertTrue(probes > 1 && probes < 15, "poll count stays bounded")
    }

    // A native read uses up its budget: even a late successful ID is rejected.
    clock = 0
    do {
        let _: UInt32 = try await DictationInputDeviceBindingPolicy.waitForBinding(
            now: { clock }, sleep: { clock += $0 }, isCurrent: { true }
        ) { remaining in clock += remaining; return mic.id }
        assertTrue(false, "late native completion must not publish readiness")
    } catch {
        assertEqual(error as? DictationInputDeviceBindingError, .selectedDeviceNotBound, "native work counts toward the same deadline")
    }

    clock = 0
    var probes = 0
    let nativeError = NSError(domain: "SyntheticHAL", code: 1)
    do {
        let _: UInt32 = try await DictationInputDeviceBindingPolicy.waitForBinding(
            now: { clock }, sleep: { clock += $0 }, isCurrent: { true }
        ) { _ in probes += 1; throw nativeError }
        assertTrue(false, "driver failure must propagate")
    } catch { assertEqual((error as NSError).domain, nativeError.domain, "do not retry unrelated native failures") }
    assertEqual(probes, 1, "driver error stops polling")

    for invalidateDuringProbe in [false, true] {
        clock = 0
        probes = 0
        var current = true
        do {
            let _: UInt32 = try await DictationInputDeviceBindingPolicy.waitForBinding(
                now: { clock }, sleep: { clock += $0; if !invalidateDuringProbe { current = false } },
                isCurrent: { current }
            ) { _ in probes += 1; current = false; return mic.id }
            assertTrue(false, "superseded queue or recovery must not publish readiness")
        } catch { assertTrue(error is CancellationError, "stale ownership exits as cancellation") }
        assertEqual(probes, invalidateDuringProbe ? 1 : 0, "check ownership both before and after native work")
    }

    let cancelled = Task { @MainActor in
        do {
            let _: UInt32 = try await DictationInputDeviceBindingPolicy.waitForBinding(
                sleep: { _ in throw CancellationError() }, isCurrent: { true }
            ) { _ in assertTrue(false, "cancelled sleep must not probe hardware"); return mic.id }
            return false
        } catch { return error is CancellationError }
    }
    let didCancel = await cancelled.value
    assertTrue(didCancel, "cancellation must escape the settling loop")

    do {
        _ = try DictationInputDeviceBindingPolicy.requireSelection(nil)
        assertTrue(false, "failed selection cannot validate a previously pinned input")
    } catch {
        assertEqual(error as? DictationInputDeviceBindingError, .selectionUnavailable, "selection lookup must fail closed")
    }
    assertTrue(
        TranscriptedConstants.dictationReadinessRefreshTimeout > Double(
            TranscriptedConstants.systemInputOperationTimeout + TranscriptedConstants.audioStartOperationTimeout
                + TranscriptedConstants.audioInputBindingSettleTimeout
        ) / 1_000_000_000,
        "outer refresh must allow selection, initial snapshot, and USB settling to complete"
    )
}
