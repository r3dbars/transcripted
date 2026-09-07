import Foundation

@MainActor
func testASRInferenceWaiterQueue() async {
    let queue = ASRInferenceWaiterQueue()
    let first = Task { @MainActor () -> Bool in
        do { try await queue.wait(); return true } catch { return false }
    }
    while queue.count < 1 { await Task.yield() }
    let canceled = Task { @MainActor () -> Bool in
        do { try await queue.wait(); return true } catch { return false }
    }
    while queue.count < 2 { await Task.yield() }
    canceled.cancel()
    let canceledWasGranted = await canceled.value
    assertTrue(!canceledWasGranted, "queued cancellation finishes without waiting for active inference")
    assertEqual(queue.count, 1, "cancellation removes only its own queued continuation")
    queue.resumeFirst()
    let firstWasGranted = await first.value
    assertTrue(firstWasGranted, "remaining FIFO waiter still receives handoff")
    assertTrue(queue.isEmpty, "handoff removes granted continuation")

    let handoff = Task { @MainActor () -> Bool in
        do { try await queue.wait(); return true } catch { return false }
    }
    while queue.count < 1 { await Task.yield() }
    queue.resumeFirst()
    handoff.cancel()
    let handoffWasGranted = await handoff.value
    assertTrue(handoffWasGranted, "cancellation after handoff leaves slot release to the granted caller")
    assertTrue(queue.isEmpty, "late cancellation cannot consume another waiter")

    let alreadyCanceled = Task { @MainActor () -> Bool in
        do { try await queue.wait(); return true } catch { return false }
    }
    alreadyCanceled.cancel()
    let alreadyCanceledWasGranted = await alreadyCanceled.value
    assertTrue(!alreadyCanceledWasGranted, "pre-canceled requests never enter the queue")
    assertTrue(queue.isEmpty, "pre-cancellation leaves no continuation behind")
}
