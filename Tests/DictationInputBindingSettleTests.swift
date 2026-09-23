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

    do {
        var setterCalls = 0
        let pinned = try DictationInputDeviceBindingPolicy.apply(
            selection: selection,
            currentDeviceID: { 0 },
            switchAlreadyPending: { true },
            setDeviceID: { _ in setterCalls += 1 }
        )
        assertTrue(pinned, "a pending switch is still verified by the settle wait")
        assertEqual(setterCalls, 0, "a pending switch must not be restarted")
        _ = try DictationInputDeviceBindingPolicy.apply(
            selection: selection,
            currentDeviceID: { 0 },
            switchAlreadyPending: { false },
            setDeviceID: { _ in setterCalls += 1 }
        )
        assertEqual(setterCalls, 1, "without a pending switch the setter runs")
    } catch {
        assertTrue(false, "apply must not throw for a valid selection: \(error)")
    }

    // Only the launch prebind gets the long window, and only for pinning the
    // Mac mic away from a Bluetooth default input.
    let airPods = DictationAudioDevice(id: 40, name: "AirPods Pro", transport: .bluetooth, inputChannelCount: 1)
    let macMic = DictationAudioDevice(id: 41, name: "MacBook Pro Microphone", transport: .builtIn, inputChannelCount: 1)
    let pinnedAwayFromAirPods = DictationInputDeviceSelection(defaultInput: airPods, selectedInput: macMic,
        defaultOutput: airPods, reason: .preferredBuiltInForBluetoothHeadset)
    let followsAirPods = DictationInputDeviceSelection(defaultInput: airPods, selectedInput: airPods,
        defaultOutput: airPods, reason: .defaultIsSafe)
    assertEqual(
        DictationInputDeviceBindingPolicy.settleTimeout(for: pinnedAwayFromAirPods, isLaunchPrebind: true),
        DictationInputDeviceBindingPolicy.launchBluetoothDefaultRebindSettleTimeout,
        "the launch prebind waits out a slow first rebind off AirPods"
    )
    assertEqual(
        DictationInputDeviceBindingPolicy.settleTimeout(for: pinnedAwayFromAirPods, isLaunchPrebind: false),
        TranscriptedConstants.audioInputBindingSettleTimeout,
        "a press keeps the window its readiness refresh timeout is sized for"
    )
    assertEqual(
        DictationInputDeviceBindingPolicy.settleTimeout(for: followsAirPods, isLaunchPrebind: true),
        TranscriptedConstants.audioInputBindingSettleTimeout,
        "no override, no long window"
    )
    assertEqual(
        DictationInputDeviceBindingPolicy.settleTimeout(for: selection, isLaunchPrebind: true),
        TranscriptedConstants.audioInputBindingSettleTimeout,
        "USB defaults keep the ordinary window"
    )
    assertEqual(
        DictationInputDeviceBindingPolicy.snapshotTimeout(for: pinnedAwayFromAirPods, isLaunchPrebind: true),
        DictationInputDeviceBindingPolicy.launchBluetoothDefaultSnapshotTimeout,
        "the launch prebind's first pin off AirPods may outrun the ordinary engine-work timeout"
    )
    assertEqual(
        DictationInputDeviceBindingPolicy.snapshotTimeout(for: pinnedAwayFromAirPods, isLaunchPrebind: false),
        TranscriptedConstants.audioStartOperationTimeout,
        "a press keeps the engine-work timeout its refresh is sized for"
    )
    assertEqual(
        DictationInputDeviceBindingPolicy.snapshotTimeout(for: selection, isLaunchPrebind: true),
        TranscriptedConstants.audioStartOperationTimeout,
        "USB defaults keep the ordinary engine-work timeout"
    )
}
