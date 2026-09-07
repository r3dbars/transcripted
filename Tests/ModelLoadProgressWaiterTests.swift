import Combine
import Foundation

@MainActor
func testModelLoadProgressWaiter() async {
    let subject = PassthroughSubject<Void, Never>()
    var subscriptions = 0
    var cancellations = 0
    let changes = subject.handleEvents(
        receiveSubscription: { _ in subscriptions += 1 },
        receiveCancel: { cancellations += 1 }
    ).eraseToAnyPublisher()
    let start = ProcessInfo.processInfo.systemUptime
    await ModelLoadProgressWaiter.wait(for: changes, until: start + 0.02)
    assertTrue(ProcessInfo.processInfo.systemUptime - start < 1, "a stalled load must release its caller at the deadline")
    assertEqual(cancellations, 1, "timeout removes observation")

    let transition = Task { @MainActor in
        await ModelLoadProgressWaiter.wait(for: changes, until: ProcessInfo.processInfo.systemUptime + 60)
    }
    while subscriptions < 2 { await Task.yield() }
    subject.send(())
    await transition.value
    assertEqual(cancellations, 2, "state transition removes observation and deadline timer")

    let canceled = Task { @MainActor in
        await ModelLoadProgressWaiter.wait(for: changes, until: ProcessInfo.processInfo.systemUptime + 60)
    }
    while subscriptions < 3 { await Task.yield() }
    canceled.cancel()
    await canceled.value
    assertEqual(cancellations, 3, "caller cancellation does not wait for native initialization")

    let alreadyCanceled = Task { @MainActor in
        await ModelLoadProgressWaiter.wait(for: changes, until: ProcessInfo.processInfo.systemUptime + 60)
    }
    alreadyCanceled.cancel()
    await alreadyCanceled.value
    assertEqual(subscriptions, 3, "already canceled caller does not subscribe")

    await ModelLoadProgressWaiter.wait(for: changes, until: ProcessInfo.processInfo.systemUptime - 1)
    assertEqual(subscriptions, 3, "expired deadline does not subscribe")
    subject.send(())
    assertEqual(cancellations, 3, "late model progress cannot double-resume a finished waiter")

    // Each caller owns only its observation; timing out one must not finish or
    // cancel another caller still waiting on the same shared initialization.
    let shared = PassthroughSubject<Void, Never>()
    var sharedSubscriptions = 0
    var sharedCancellations = 0
    var survivorFinished = false
    let sharedChanges = shared.handleEvents(
        receiveSubscription: { _ in sharedSubscriptions += 1 },
        receiveCancel: { sharedCancellations += 1 }
    ).eraseToAnyPublisher()
    let survivor = Task { @MainActor in
        await ModelLoadProgressWaiter.wait(for: sharedChanges, until: ProcessInfo.processInfo.systemUptime + 60)
        survivorFinished = true
    }
    while sharedSubscriptions < 1 { await Task.yield() }
    await ModelLoadProgressWaiter.wait(for: sharedChanges, until: ProcessInfo.processInfo.systemUptime + 0.02)
    assertEqual(sharedCancellations, 1, "one caller timing out removes only its own subscription")
    assertTrue(!survivorFinished, "another caller continues waiting after shared peer times out")
    let canceledPeer = Task { @MainActor in
        await ModelLoadProgressWaiter.wait(for: sharedChanges, until: ProcessInfo.processInfo.systemUptime + 60)
    }
    while sharedSubscriptions < 3 { await Task.yield() }
    canceledPeer.cancel()
    await canceledPeer.value
    assertEqual(sharedCancellations, 2, "one caller canceling removes only its own subscription")
    assertTrue(!survivorFinished, "another caller continues waiting after shared peer cancels")
    shared.send(())
    await survivor.value
    assertTrue(survivorFinished, "surviving caller receives the eventual shared model transition")
    assertEqual(sharedCancellations, 3, "all completed callers release their observations")

}
