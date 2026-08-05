// DefaultInputDeviceMonitorTests.swift
// Pure, CoreAudio-free coverage for the two testable pieces of
// DefaultInputDeviceMonitor: ordered observer delivery and self-write
// suppression. The CoreAudio registration itself, and hardware-triggered
// behavior across the three migrated consumers, needs a local hardware pass
// — see the PR body's hardware checklist.

import CoreAudio
import Foundation

func testDefaultInputDeviceMonitor() {
    runSuite("DefaultInputDeviceObserverRegistry — delivers in registration order") {
        var registry = DefaultInputDeviceObserverRegistry()
        var order: [Int] = []
        _ = registry.add { order.append(1) }
        _ = registry.add { order.append(2) }
        _ = registry.add { order.append(3) }

        registry.notifyAll()

        assertEqual(order, [1, 2, 3], "observers should fire in the order they were registered")
    }

    runSuite("DefaultInputDeviceObserverRegistry — removing a token stops future delivery") {
        var registry = DefaultInputDeviceObserverRegistry()
        var order: [Int] = []
        _ = registry.add { order.append(1) }
        let middle = registry.add { order.append(2) }
        _ = registry.add { order.append(3) }

        registry.remove(middle)
        registry.notifyAll()

        assertEqual(order, [1, 3], "removed observer must not be notified, remaining order preserved")
        assertEqual(registry.count, 2, "registry should drop the removed observer")
    }

    runSuite("DefaultInputDeviceObserverRegistry — removing an unknown token is a no-op") {
        var registry = DefaultInputDeviceObserverRegistry()
        var fired = false
        _ = registry.add { fired = true }
        let unrelated = DefaultInputDeviceObserverToken()

        registry.remove(unrelated)
        registry.notifyAll()

        assertTrue(fired, "unrelated removal must not disturb the real observer")
        assertEqual(registry.count, 1, "unrelated removal must not drop the real observer")
    }

    runSuite("DefaultInputDeviceSelfWriteTracker — suppresses the echo of its own write") {
        var tracker = DefaultInputDeviceSelfWriteTracker()
        let deviceID: AudioDeviceID = 42
        tracker.beginWrite(deviceID: deviceID, now: 100, window: 0.5)

        let suppressed = tracker.consumeSuppression(currentDeviceID: deviceID, now: 100.1)

        assertTrue(suppressed, "a notification for the written device inside the window should be swallowed")
    }

    runSuite("DefaultInputDeviceSelfWriteTracker — does not suppress once the window has passed") {
        var tracker = DefaultInputDeviceSelfWriteTracker()
        let deviceID: AudioDeviceID = 42
        tracker.beginWrite(deviceID: deviceID, now: 100, window: 0.5)

        let suppressed = tracker.consumeSuppression(currentDeviceID: deviceID, now: 100.6)

        assertFalse(suppressed, "a notification arriving after the window elapsed must be delivered")
    }

    runSuite("DefaultInputDeviceSelfWriteTracker — does not suppress a different device inside the window") {
        var tracker = DefaultInputDeviceSelfWriteTracker()
        tracker.beginWrite(deviceID: 42, now: 100, window: 0.5)

        let suppressed = tracker.consumeSuppression(currentDeviceID: 99, now: 100.1)

        assertFalse(suppressed, "a genuine external change to a different device must not be swallowed")
    }

    runSuite("DefaultInputDeviceSelfWriteTracker — is single-use, even when it swallows") {
        var tracker = DefaultInputDeviceSelfWriteTracker()
        let deviceID: AudioDeviceID = 42
        tracker.beginWrite(deviceID: deviceID, now: 100, window: 0.5)

        let first = tracker.consumeSuppression(currentDeviceID: deviceID, now: 100.1)
        let second = tracker.consumeSuppression(currentDeviceID: deviceID, now: 100.2)

        assertTrue(first, "the first notification after a write is the echo and should be swallowed")
        assertFalse(second, "a second notification must never be swallowed by a stale pending write")
    }

    runSuite("DefaultInputDeviceSelfWriteTracker — is single-use even when it does not match") {
        var tracker = DefaultInputDeviceSelfWriteTracker()
        tracker.beginWrite(deviceID: 42, now: 100, window: 0.5)

        let unrelated = tracker.consumeSuppression(currentDeviceID: 99, now: 100.1)
        let laterEcho = tracker.consumeSuppression(currentDeviceID: 42, now: 100.2)

        assertFalse(unrelated, "a mismatched notification is delivered, not swallowed")
        assertFalse(laterEcho, "the pending write was already consumed by the mismatched notification")
    }

    runSuite("DefaultInputDeviceSelfWriteTracker — cancelling a failed write clears suppression") {
        var tracker = DefaultInputDeviceSelfWriteTracker()
        let deviceID: AudioDeviceID = 42
        tracker.beginWrite(deviceID: deviceID, now: 100, window: 0.5)

        tracker.cancelPendingWrite()
        let suppressed = tracker.consumeSuppression(currentDeviceID: deviceID, now: 100.1)

        assertFalse(suppressed, "a cancelled write (e.g. the CoreAudio set call itself failed) must not suppress")
    }

    runSuite("DefaultInputDeviceSelfWriteTracker — no pending write never suppresses") {
        var tracker = DefaultInputDeviceSelfWriteTracker()

        let suppressed = tracker.consumeSuppression(currentDeviceID: 7, now: 100)

        assertFalse(suppressed, "with nothing pending, every notification is a genuine external change")
    }
}
