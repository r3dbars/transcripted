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

    runSuite("DefaultInputDeviceSelfWriteTracker — only a pending in-window echo needs HAL classification") {
        var tracker = DefaultInputDeviceSelfWriteTracker()
        assertFalse(tracker.needsDeviceIDForClassification(at: 100),
                    "an ordinary external route event needs no monitor HAL read")
        tracker.beginWrite(deviceID: 42, now: 100, window: 0.5)
        assertTrue(tracker.needsDeviceIDForClassification(at: 100.1),
                   "a possible self-write echo needs an ID comparison")
        assertFalse(tracker.needsDeviceIDForClassification(at: 100.6),
                    "an expired marker cannot classify a later external event")
        assertFalse(tracker.consumeIsSelfWrite(currentDeviceID: nil, now: 100.6),
                    "the expired marker is consumed when immediately notifying observers")
        assertFalse(tracker.needsDeviceIDForClassification(at: 100.7),
                    "no future event inherits a stale marker")
    }

    runSuite("DefaultInputDeviceNotificationMailbox — first echo is reserved before worker starts") {
        let mailbox = DefaultInputDeviceNotificationMailbox()
        let first = DefaultInputDeviceNotificationRequest(notificationAt: 100, pendingSelfWrite: nil)
        let second = DefaultInputDeviceNotificationRequest(notificationAt: 101, pendingSelfWrite: nil)
        assertTrue(mailbox.submit(first), "first callback schedules a worker")
        assertFalse(mailbox.submit(second), "second callback reuses the reserved worker")
        assertEqual(mailbox.takeNext(), first, "the first echo must not be overwritten before the worker starts")
        assertEqual(mailbox.takeNext(), second, "the second callback remains pending")
        assertTrue(mailbox.takeNext() == nil, "the bounded mailbox drains")
    }

    runSuite("DefaultInputDeviceSelfWriteTracker — delayed A result cannot consume B write marker") {
        var tracker = DefaultInputDeviceSelfWriteTracker()
        tracker.beginWrite(deviceID: 42, now: 100, window: 0.5)
        let tokenA = tracker.takePendingWriteForNotification(at: 100.1)
        tracker.beginWrite(deviceID: 43, now: 100.2, window: 0.5)
        assertFalse(tokenA?.matches(currentDeviceID: 43, notificationAt: 100.1) ?? true,
                    "late A callback cannot be mislabeled from the current B device")
        let tokenB = tracker.takePendingWriteForNotification(at: 100.3)
        assertTrue(tokenB?.matches(currentDeviceID: 43, notificationAt: 100.3) ?? false,
                   "B retains its own one-use marker after A's delayed classification")
    }

    runSuite("DefaultInputDeviceNotificationLookupDispatcher — callback time preserves self-write order") {
        var tracker = DefaultInputDeviceSelfWriteTracker()
        tracker.beginWrite(deviceID: 42, now: 100, window: 0.5)
        let token = tracker.takePendingWriteForNotification(at: 100.1)
        var registry = DefaultInputDeviceObserverRegistry()
        let lock = NSLock()
        var delivered: [String] = []
        let callback = DispatchSemaphore(value: 0)
        _ = registry.add { isSelfWrite in delivered.append("first:\(isSelfWrite)") }
        _ = registry.add { isSelfWrite in delivered.append("second:\(isSelfWrite)") }
        let dispatcher = DefaultInputDeviceNotificationLookupDispatcher(
            label: "test.default-input-order",
            timeoutNanoseconds: 250_000_000,
            lookup: {
                Thread.sleep(forTimeInterval: 0.05)
                return 42
            },
            deliver: { deviceID, request in
                lock.withLock {
                    let isSelfWrite = request.pendingSelfWrite?.matches(
                        currentDeviceID: deviceID,
                        notificationAt: request.notificationAt
                    ) ?? false
                    registry.notifyAll(isSelfWrite: isSelfWrite)
                }
                callback.signal()
            }
        )

        dispatcher.submit(at: 100.1, pendingSelfWrite: token)
        assertTrue(callback.wait(timeout: .now() + 2) == .success, "lookup must deliver")
        assertEqual(lock.withLock { delivered }, ["first:true", "second:true"],
                    "all observers must receive the self-write flag in registration order despite async completion")
        dispatcher.close()
    }

    runSuite("DefaultInputDeviceNotificationLookupDispatcher — delayed A then new B keeps each token") {
        var tracker = DefaultInputDeviceSelfWriteTracker()
        tracker.beginWrite(deviceID: 42, now: 100, window: 0.5)
        let tokenA = tracker.takePendingWriteForNotification(at: 100.1)
        let releaseA = DispatchSemaphore(value: 0)
        let startedA = DispatchSemaphore(value: 0)
        let callback = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var reads = 0
        var seen: [Bool] = []
        let dispatcher = DefaultInputDeviceNotificationLookupDispatcher(
            label: "test.default-input-two-writes",
            timeoutNanoseconds: 250_000_000,
            lookup: {
                let readNumber = lock.withLock { () -> Int in
                    reads += 1
                    return reads
                }
                if readNumber == 1 {
                    startedA.signal()
                    releaseA.wait()
                }
                // The system default may already be B when A's delayed HAL
                // lookup completes. Tokens, not current tracker state, decide.
                return 43
            },
            deliver: { deviceID, request in
                let isSelfWrite = request.pendingSelfWrite?.matches(
                    currentDeviceID: deviceID,
                    notificationAt: request.notificationAt
                ) ?? false
                lock.withLock { seen.append(isSelfWrite) }
                callback.signal()
            }
        )

        dispatcher.submit(at: 100.1, pendingSelfWrite: tokenA)
        assertTrue(startedA.wait(timeout: .now() + 2) == .success, "A lookup starts")
        tracker.beginWrite(deviceID: 43, now: 100.2, window: 0.5)
        releaseA.signal()
        assertTrue(callback.wait(timeout: .now() + 2) == .success, "A delivers")
        let tokenB = tracker.takePendingWriteForNotification(at: 100.3)
        dispatcher.submit(at: 100.3, pendingSelfWrite: tokenB)
        assertTrue(callback.wait(timeout: .now() + 2) == .success, "B delivers")
        assertEqual(lock.withLock { seen }, [false, true],
                    "A is not misclassified as B, and B still receives its self-write flag in callback order")
        dispatcher.close()
    }

    runSuite("DefaultInputDeviceNotificationLookupDispatcher — blocked HAL cannot block submission or deliver late") {
        let blocker = DispatchSemaphore(value: 0)
        let callback = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var delivered: [(AudioDeviceID?, CFAbsoluteTime)] = []
        var recoveryNotifications = 0
        var registry = DefaultInputDeviceObserverRegistry()
        _ = registry.add { isSelfWrite in
            if !isSelfWrite { recoveryNotifications += 1 }
        }
        let dispatcher = DefaultInputDeviceNotificationLookupDispatcher(
            label: "test.default-input-blocked",
            timeoutNanoseconds: 30_000_000,
            lookup: {
                blocker.wait()
                return 42
            },
            deliver: { deviceID, request in
                lock.withLock {
                    delivered.append((deviceID, request.notificationAt))
                    // Unknown is conservatively external, so an observer
                    // such as Parakeet must request route recovery.
                    registry.notifyAll(isSelfWrite: false)
                }
                callback.signal()
            }
        )

        let submittedAt = Date()
        dispatcher.submit(at: 123)
        assertTrue(Date().timeIntervalSince(submittedAt) < 0.1,
                   "listener-queue submission must not await a blocked HAL read")
        assertTrue(callback.wait(timeout: .now() + 2) == .success,
                   "a timed-out read must still notify route recovery")
        let first = lock.withLock { delivered }
        assertEqual(first.count, 1, "the timeout must deliver one event")
        assertTrue(first.first?.0 == nil, "a timed-out route lookup must be unknown")
        assertEqual(first.first?.1, 123, "preserve the notification time")
        assertEqual(lock.withLock { recoveryNotifications }, 1,
                    "blocked lookup must still dispatch a recovery notification")

        dispatcher.close()
        blocker.signal()
        Thread.sleep(forTimeInterval: 0.1)
        assertEqual(lock.withLock { delivered.count }, 1,
                    "a late HAL result after timeout/shutdown must not notify observers")
        dispatcher.submit(at: 124)
        assertEqual(lock.withLock { delivered.count }, 1,
                    "a closed monitor must reject new notifications")
    }

    runSuite("DefaultInputDeviceNotificationLookupDispatcher — shutdown discards in-flight lookup") {
        let blocker = DispatchSemaphore(value: 0)
        let workerStarted = DispatchSemaphore(value: 0)
        let callback = DispatchSemaphore(value: 0)
        let dispatcher = DefaultInputDeviceNotificationLookupDispatcher(
            label: "test.default-input-shutdown",
            timeoutNanoseconds: 30_000_000,
            lookup: {
                workerStarted.signal()
                blocker.wait()
                return 42
            },
            deliver: { _, _ in callback.signal() }
        )
        dispatcher.submit(at: 123)
        assertTrue(workerStarted.wait(timeout: .now() + 2) == .success, "lookup starts")
        dispatcher.close()
        assertFalse(callback.wait(timeout: .now() + 0.1) == .success,
                    "shutdown must discard the timeout result")
        blocker.signal()
        assertFalse(callback.wait(timeout: .now() + 0.1) == .success,
                    "shutdown must discard the late successful result")
    }

    runSuite("DefaultInputDeviceNotificationLookupDispatcher — storm uses at most two blocked workers") {
        let blocker = DispatchSemaphore(value: 0)
        let workerStarted = DispatchSemaphore(value: 0)
        let callback = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var started = 0
        var notifications: [CFAbsoluteTime] = []
        let dispatcher = DefaultInputDeviceNotificationLookupDispatcher(
            label: "test.default-input-storm",
            timeoutNanoseconds: 30_000_000,
            lookup: {
                lock.withLock { started += 1 }
                workerStarted.signal()
                blocker.wait()
                return 42
            },
            deliver: { deviceID, request in
                assertTrue(deviceID == nil, "blocked lookups must time out or circuit-open")
                lock.withLock { notifications.append(request.notificationAt) }
                callback.signal()
            }
        )

        dispatcher.submit(at: 1)
        assertTrue(dispatcher.hasScheduledWorker, "an in-flight self-write must serialize later callbacks")
        assertTrue(workerStarted.wait(timeout: .now() + 2) == .success, "first worker starts")
        for index in 2...100 { dispatcher.submit(at: CFAbsoluteTime(index)) }
        assertTrue(callback.wait(timeout: .now() + 2) == .success, "first notification times out")
        assertTrue(workerStarted.wait(timeout: .now() + 2) == .success, "replacement worker starts")
        assertTrue(callback.wait(timeout: .now() + 2) == .success, "latest notification times out")
        dispatcher.submit(at: 101)
        assertTrue(callback.wait(timeout: .now() + 2) == .success, "circuit-open still delivers recovery event")
        assertEqual(lock.withLock { started }, 2,
                    "two retained blocked workers must not create an unbounded replacement queue")
        assertEqual(lock.withLock { notifications }, [1, 100, 101],
                    "keep the active echo, collapse the burst to its latest event, then deliver circuit-open")

        dispatcher.close()
        assertFalse(dispatcher.hasScheduledWorker, "shutdown releases mailbox worker ownership")
        blocker.signal()
        blocker.signal()
    }

    runSuite("DefaultInputDeviceNotificationLookupDispatcher — restart shares the blocked-worker circuit") {
        let coordinator = ParakeetReplaceableSystemInputWorkCoordinator(
            label: "test.default-input-restart-shared"
        )
        let blocker = DispatchSemaphore(value: 0)
        let workerStarted = DispatchSemaphore(value: 0)
        let callback = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var started = 0
        let lookup: () -> AudioDeviceID? = {
            lock.withLock { started += 1 }
            workerStarted.signal()
            blocker.wait()
            return 42
        }
        func restartedDispatcher(_ suffix: String) -> DefaultInputDeviceNotificationLookupDispatcher {
            DefaultInputDeviceNotificationLookupDispatcher(
                label: "test.default-input-restart.\(suffix)",
                timeoutNanoseconds: 30_000_000,
                lookup: lookup,
                workCoordinator: coordinator,
                deliver: { _, _ in callback.signal() }
            )
        }

        let first = restartedDispatcher("1")
        first.submit(at: 1)
        assertTrue(workerStarted.wait(timeout: .now() + 2) == .success, "first worker starts")
        assertTrue(callback.wait(timeout: .now() + 2) == .success, "first worker times out")
        first.close()
        let second = restartedDispatcher("2")
        second.submit(at: 2)
        assertTrue(workerStarted.wait(timeout: .now() + 2) == .success, "replacement worker starts")
        assertTrue(callback.wait(timeout: .now() + 2) == .success, "replacement worker times out")
        second.close()
        let third = restartedDispatcher("3")
        third.submit(at: 3)
        assertTrue(callback.wait(timeout: .now() + 2) == .success,
                   "circuit-open result still reaches the new monitor generation")
        assertEqual(lock.withLock { started }, 2,
                    "stop/start must not recreate a fresh circuit around retained blocked HAL workers")
        third.close()
        blocker.signal()
        blocker.signal()
    }
}
