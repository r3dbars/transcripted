// DefaultInputDeviceMonitorTests.swift
// Pure, CoreAudio-free coverage for the testable pieces of
// DefaultInputDeviceMonitor: ordered observer delivery (including the
// isSelfWrite flag every observer receives — codex review of PR #1640, P2)
// and self-write classification. The CoreAudio registration itself, and
// hardware-triggered behavior across the three migrated consumers, needs a
// local hardware pass — see the PR body's hardware checklist. The
// start→stop→start subscription race fix lives in MicActivityMonitor.swift;
// see Tests/MicActivityMonitorTests.swift for its coverage.

import CoreAudio
import Foundation

func testDefaultInputDeviceMonitor() {
    runSuite("DefaultInputDeviceObserverRegistry — delivers in registration order") {
        var registry = DefaultInputDeviceObserverRegistry()
        var order: [Int] = []
        _ = registry.add { _ in order.append(1) }
        _ = registry.add { _ in order.append(2) }
        _ = registry.add { _ in order.append(3) }

        registry.notifyAll(isSelfWrite: false)

        assertEqual(order, [1, 2, 3], "observers should fire in the order they were registered")
    }

    runSuite("DefaultInputDeviceObserverRegistry — removing a token stops future delivery") {
        var registry = DefaultInputDeviceObserverRegistry()
        var order: [Int] = []
        _ = registry.add { _ in order.append(1) }
        let middle = registry.add { _ in order.append(2) }
        _ = registry.add { _ in order.append(3) }

        registry.remove(middle)
        registry.notifyAll(isSelfWrite: false)

        assertEqual(order, [1, 3], "removed observer must not be notified, remaining order preserved")
        assertEqual(registry.count, 2, "registry should drop the removed observer")
    }

    runSuite("DefaultInputDeviceObserverRegistry — removing an unknown token is a no-op") {
        var registry = DefaultInputDeviceObserverRegistry()
        var fired = false
        _ = registry.add { _ in fired = true }
        let unrelated = DefaultInputDeviceObserverToken()

        registry.remove(unrelated)
        registry.notifyAll(isSelfWrite: false)

        assertTrue(fired, "unrelated removal must not disturb the real observer")
        assertEqual(registry.count, 1, "unrelated removal must not drop the real observer")
    }

    // MARK: - isSelfWrite delivery (codex review of PR #1640, P2)
    //
    // The monitor no longer decides who cares about a self-write — every
    // observer is notified on every change, and gets told whether it was a
    // self-write so it can decide for itself (see the per-consumer
    // isSelfWrite policy comments in PersistentDictationInputController.swift,
    // ParakeetDeviceRecovery.swift, and MicActivityMonitor.swift).

    runSuite("DefaultInputDeviceObserverRegistry — passes isSelfWrite=false through to every observer") {
        var registry = DefaultInputDeviceObserverRegistry()
        var seen: [Bool] = []
        _ = registry.add { seen.append($0) }
        _ = registry.add { seen.append($0) }

        registry.notifyAll(isSelfWrite: false)

        assertEqual(seen, [false, false], "a genuine external change must be flagged isSelfWrite=false for every observer")
    }

    runSuite("DefaultInputDeviceObserverRegistry — passes isSelfWrite=true through to every observer") {
        var registry = DefaultInputDeviceObserverRegistry()
        var seen: [Bool] = []
        _ = registry.add { seen.append($0) }
        _ = registry.add { seen.append($0) }

        registry.notifyAll(isSelfWrite: true)

        assertEqual(seen, [true, true], "a self-write must still reach every observer — the registry does not filter it")
    }

    runSuite("DefaultInputDeviceObserverRegistry — a consumer can ignore self-writes while another still reacts") {
        // Models the real split: PersistentDictationInputController/ParakeetEngine
        // ignore isSelfWrite, MicActivityMonitor always reacts.
        var registry = DefaultInputDeviceObserverRegistry()
        var ignoresSelfWriteCallCount = 0
        var alwaysReactsCallCount = 0
        _ = registry.add { isSelfWrite in
            guard !isSelfWrite else { return }
            ignoresSelfWriteCallCount += 1
        }
        _ = registry.add { _ in
            alwaysReactsCallCount += 1
        }

        registry.notifyAll(isSelfWrite: true)

        assertEqual(ignoresSelfWriteCallCount, 0, "the self-write-ignoring consumer must not react to its own echo")
        assertEqual(alwaysReactsCallCount, 1, "the always-reacting consumer must still see the notification")
    }

    // MARK: - DefaultInputDeviceSelfWriteTracker (self-write classification)

    runSuite("DefaultInputDeviceSelfWriteTracker — classifies the echo of its own write as a self-write") {
        var tracker = DefaultInputDeviceSelfWriteTracker()
        let deviceID: AudioDeviceID = 42
        tracker.beginWrite(deviceID: deviceID, now: 100, window: 0.5)

        let isSelfWrite = tracker.consumeIsSelfWrite(currentDeviceID: deviceID, now: 100.1)

        assertTrue(isSelfWrite, "a notification for the written device inside the window is our own echo")
    }

    runSuite("DefaultInputDeviceSelfWriteTracker — not a self-write once the window has passed") {
        var tracker = DefaultInputDeviceSelfWriteTracker()
        let deviceID: AudioDeviceID = 42
        tracker.beginWrite(deviceID: deviceID, now: 100, window: 0.5)

        let isSelfWrite = tracker.consumeIsSelfWrite(currentDeviceID: deviceID, now: 100.6)

        assertFalse(isSelfWrite, "a notification arriving after the window elapsed is not classified as our echo")
    }

    runSuite("DefaultInputDeviceSelfWriteTracker — not a self-write for a different device inside the window") {
        var tracker = DefaultInputDeviceSelfWriteTracker()
        tracker.beginWrite(deviceID: 42, now: 100, window: 0.5)

        let isSelfWrite = tracker.consumeIsSelfWrite(currentDeviceID: 99, now: 100.1)

        assertFalse(isSelfWrite, "a genuine external change to a different device must not be classified as our echo")
    }

    runSuite("DefaultInputDeviceSelfWriteTracker — is single-use, even when it classifies a match") {
        var tracker = DefaultInputDeviceSelfWriteTracker()
        let deviceID: AudioDeviceID = 42
        tracker.beginWrite(deviceID: deviceID, now: 100, window: 0.5)

        let first = tracker.consumeIsSelfWrite(currentDeviceID: deviceID, now: 100.1)
        let second = tracker.consumeIsSelfWrite(currentDeviceID: deviceID, now: 100.2)

        assertTrue(first, "the first notification after a write is the echo and should be classified as self-write")
        assertFalse(second, "a second notification must never be classified as self-write by a stale pending write")
    }

    runSuite("DefaultInputDeviceSelfWriteTracker — is single-use even when it does not match") {
        var tracker = DefaultInputDeviceSelfWriteTracker()
        tracker.beginWrite(deviceID: 42, now: 100, window: 0.5)

        let unrelated = tracker.consumeIsSelfWrite(currentDeviceID: 99, now: 100.1)
        let laterEcho = tracker.consumeIsSelfWrite(currentDeviceID: 42, now: 100.2)

        assertFalse(unrelated, "a mismatched notification is not classified as self-write")
        assertFalse(laterEcho, "the pending write was already consumed by the mismatched notification")
    }

    runSuite("DefaultInputDeviceSelfWriteTracker — cancelling a failed write clears classification") {
        var tracker = DefaultInputDeviceSelfWriteTracker()
        let deviceID: AudioDeviceID = 42
        tracker.beginWrite(deviceID: deviceID, now: 100, window: 0.5)

        tracker.cancelPendingWrite()
        let isSelfWrite = tracker.consumeIsSelfWrite(currentDeviceID: deviceID, now: 100.1)

        assertFalse(isSelfWrite, "a cancelled write (e.g. the CoreAudio set call itself failed) must not be classified as self-write")
    }

    runSuite("DefaultInputDeviceSelfWriteTracker — no pending write is never a self-write") {
        var tracker = DefaultInputDeviceSelfWriteTracker()

        let isSelfWrite = tracker.consumeIsSelfWrite(currentDeviceID: 7, now: 100)

        assertFalse(isSelfWrite, "with nothing pending, every notification is a genuine external change")
    }
}
