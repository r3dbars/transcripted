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

    let plan = DictationActiveTaskCancellationPolicy.plan(
        cancelRecording: true, recordingStartWasInFlight: false,
        sttIsRecording: false, sttIsTranscribing: true
    )
    var queuedBusy = true
    let queuedSession = Task { @MainActor in
        defer { queuedBusy = false }
        do { try await queue.wait() } catch { }
    }
    while queue.isEmpty { await Task.yield() }
    assertTrue(plan.cancelStreamingTask, "explicit session cancellation must reach the inference waiter")
    if plan.cancelStreamingTask { queuedSession.cancel() }
    else { queue.resumeFirst() } // Let a failed policy assertion finish without hanging the runner.
    await queuedSession.value
    assertTrue(!queuedBusy && queue.isEmpty, "real session cancellation plan releases a queued inference caller")
    assertTrue(!plan.cancelSpeechEngine, "canceling a queued caller leaves shared native decoder work intact")

    var nativeCompletion: CheckedContinuation<Void, Never>?
    var nativeBusy = true
    let activeSession = Task { @MainActor in
        defer { nativeBusy = false }
        // Stand in for native work that cannot stop until its callback returns.
        await withCheckedContinuation { nativeCompletion = $0 }
    }
    while nativeCompletion == nil { await Task.yield() }
    if plan.cancelStreamingTask { activeSession.cancel() }
    await Task.yield()
    assertTrue(nativeBusy, "cooperative session cancellation does not mark active native work idle")
    nativeCompletion?.resume()
    await activeSession.value
    assertTrue(!nativeBusy, "active session becomes idle only after native completion")

}
