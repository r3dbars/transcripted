// ParakeetAudioGraphOwnershipTests.swift
// Deterministic owner, timeout, late-completion, and successor interleavings.

import Foundation

func testParakeetAudioGraphOwnership() async {
    runSuite("Prewarm coalesces same-resource probes without blocking a replacement graph") {
        let engine = NSObject()
        let queue = NSObject()
        let original = ParakeetAudioEngineQueueOwnerToken(generation: 1, engine: engine, queue: queue)
        let released = ParakeetAudioEngineQueueOwnerToken(generation: 2, engine: engine, queue: queue)
        var admission = ParakeetPrewarmAdmissionState()
        assertTrue(admission.begin(owner: original), "first readiness probe owns the graph")
        assertFalse(admission.begin(owner: released), "idle cleanup generation change cannot admit a second route setter")
        assertTrue(admission.transfer(from: original, to: released), "idle cleanup can update its own owner")
        let replacement = ParakeetAudioEngineQueueOwnerToken(generation: 3, engine: NSObject(), queue: NSObject())
        assertTrue(admission.begin(owner: replacement), "a replacement queue must escape a blocked native stop")
        assertFalse(admission.transfer(from: released, to: original), "old completion cannot reclaim successor resources")
        admission.finish(owner: released)
        assertEqual(admission.owner, replacement, "old completion cannot clear successor admission")
        admission.finish(owner: replacement)
        assertTrue(admission.begin(owner: replacement), "completed prewarm permits a later refresh")
    }

    runSuite("Recorded conversion survives graph-only recovery but rejects cancelled or superseded audio") {
        let engine = NSObject()
        let owner = ParakeetAudioGraphOwnerToken(generation: 3, engine: engine)
        let recordingIdentity = UUID()
        let claim = ParakeetRecordedSamplesClaim(recordingIdentity: recordingIdentity, revision: 10)
        assertTrue(claim.isCurrent(recordingIdentity: recordingIdentity, revision: 10, cancelled: false), "unchanged stopped audio can commit")
        assertFalse(owner.matches(generation: 4, engine: engine), "route recovery really invalidates native graph ownership")
        assertTrue(claim.isCurrent(recordingIdentity: recordingIdentity, revision: 10, cancelled: false), "that graph-only change cannot revoke copied samples")
        assertFalse(claim.isCurrent(recordingIdentity: recordingIdentity, revision: 10, cancelled: true), "cancelled conversion cannot publish errors or consume")
        assertFalse(claim.isCurrent(recordingIdentity: recordingIdentity, revision: 11, cancelled: false), "same-recording discard/replacement invalidates conversion")
        assertFalse(claim.isCurrent(recordingIdentity: UUID(), revision: 10, cancelled: false), "a new recording owns its own samples even with the same revision")
    }

    await runSuite("Blocked stopped-audio checkpoint survives a graph swap, not a recording swap") {
        let barrier = RecordedAudioConversionBarrier()
        let recordingIdentity = UUID()
        let claim = ParakeetRecordedSamplesClaim(recordingIdentity: recordingIdentity, revision: 20)
        let conversion = Task {
            await barrier.block()
            return claim.isCurrent(recordingIdentity: recordingIdentity, revision: 20, cancelled: false)
        }
        await barrier.waitUntilBlocked()
        let oldEngine = NSObject()
        let graphBefore = ParakeetAudioGraphOwnerToken(generation: 6, engine: oldEngine)
        assertFalse(graphBefore.matches(generation: 7, engine: NSObject()), "the simulated route change swaps native graph resources while conversion is held")
        await barrier.release()
        assertTrue(await conversion.value, "copied stopped audio must remain checkpointable after a route-only graph swap")

        let superseded = ParakeetRecordedSamplesClaim(recordingIdentity: recordingIdentity, revision: 20)
        assertFalse(superseded.isCurrent(recordingIdentity: UUID(), revision: 20, cancelled: false), "a successor recording must not reuse the held checkpoint")
        assertFalse(superseded.isCurrent(recordingIdentity: recordingIdentity, revision: 21, cancelled: false), "explicit discard must revoke the held checkpoint")
        assertFalse(superseded.isCurrent(recordingIdentity: recordingIdentity, revision: 20, cancelled: true), "cancellation must revoke the held checkpoint")
    }

    runSuite("Old transcription completion cannot clear successor admission") {
        var ownership = ParakeetRecordedTranscriptionOwnership()
        let firstRecording = UUID()
        let first = ownership.begin(recordingIdentity: firstRecording)
        assertNotNil(first, "the first stopped recording admits transcription")
        assertEqual(ownership.begin(recordingIdentity: firstRecording), nil, "a second conversion cannot occupy the first owner's busy slot")
        ownership.revoke()
        let successorRecording = UUID()
        let successor = ownership.begin(recordingIdentity: successorRecording)
        assertNotNil(successor, "replacement recording can admit its own conversion")
        assertFalse(ownership.finish(first!, recordingIdentity: successorRecording), "late old completion cannot clear successor busy state")
        assertEqual(ownership.activeLease, successor, "successor transcription must remain admitted")
        assertTrue(ownership.finish(successor!, recordingIdentity: successorRecording), "only successor completion releases its slot")
    }

    runSuite("ParakeetZombieRecoveryOwnershipPolicy accepts only the exact active graph owner") {
        let engine = NSObject()
        let owner = ParakeetAudioGraphOwnerToken(generation: 7, engine: engine)

        assertTrue(
            ParakeetZombieRecoveryOwnershipPolicy.canContinue(
                taskIsCancelled: false,
                recoveryIsCurrent: true,
                expectedOwner: owner,
                currentGraphGeneration: 7,
                currentEngine: engine
            ),
            "the active task should mutate only its exact graph generation and engine"
        )
    }

    runSuite("ParakeetZombieRecoveryOwnershipPolicy rejects stale reset interleavings") {
        let staleEngine = NSObject()
        let healthyReplacement = NSObject()
        let owner = ParakeetAudioGraphOwnerToken(generation: 11, engine: staleEngine)

        assertFalse(
            ParakeetZombieRecoveryOwnershipPolicy.canContinue(
                taskIsCancelled: true,
                recoveryIsCurrent: true,
                expectedOwner: owner,
                currentGraphGeneration: 11,
                currentEngine: staleEngine
            ),
            "a stop cancellation must not enter or complete graph recreation"
        )
        assertFalse(
            ParakeetZombieRecoveryOwnershipPolicy.canContinue(
                taskIsCancelled: false,
                recoveryIsCurrent: false,
                expectedOwner: owner,
                currentGraphGeneration: 11,
                currentEngine: staleEngine
            ),
            "a config-change cancellation must make the old zombie generation stale"
        )
        assertFalse(
            ParakeetZombieRecoveryOwnershipPolicy.canContinue(
                taskIsCancelled: false,
                recoveryIsCurrent: true,
                expectedOwner: owner,
                currentGraphGeneration: 12,
                currentEngine: staleEngine
            ),
            "a newer graph owner using the same engine must not be abandoned by an old timeout"
        )
        assertFalse(
            ParakeetZombieRecoveryOwnershipPolicy.canContinue(
                taskIsCancelled: false,
                recoveryIsCurrent: true,
                expectedOwner: owner,
                currentGraphGeneration: 11,
                currentEngine: healthyReplacement
            ),
            "a stale reset completion must not mutate a healthy replacement engine"
        )
        assertFalse(
            ParakeetZombieRecoveryOwnershipPolicy.canContinue(
                taskIsCancelled: false,
                recoveryIsCurrent: true,
                expectedOwner: owner,
                currentGraphGeneration: 12,
                currentEngine: healthyReplacement
            ),
            "generation and identity must both match before shared reset state changes"
        )
    }

    runSuite("ParakeetAudioGraphOwnerToken preserves a newer tap after delayed cleanup") {
        let retiredEngine = NSObject()
        let replacementEngine = NSObject()
        let delayedCleanupOwner = ParakeetAudioGraphOwnerToken(generation: 20, engine: retiredEngine)

        var replacementTapInstalled = true
        if delayedCleanupOwner.matches(generation: 21, engine: replacementEngine) {
            replacementTapInstalled = false
        }
        assertTrue(
            replacementTapInstalled,
            "old cleanup completion must not clear a replacement engine's installed tap"
        )

        var newerGenerationTapInstalled = true
        if delayedCleanupOwner.matches(generation: 21, engine: retiredEngine) {
            newerGenerationTapInstalled = false
        }
        assertTrue(
            newerGenerationTapInstalled,
            "old cleanup completion must not clear a newer generation's tap on the same engine"
        )
    }

    runSuite("ParakeetTimedAudioEngineWorkOwnership moves successor work off a blocked queue") {
        let retiredEngine = NSObject()
        let blockedQueue = DispatchQueue(label: "test.parakeet.blocked-engine-queue")
        let owner = ParakeetAudioEngineQueueOwnerToken(
            generation: 30,
            engine: retiredEngine,
            queue: blockedQueue
        )
        let ownership = ParakeetTimedAudioEngineWorkOwnership()
        let blockedWorkStarted = DispatchSemaphore(value: 0)
        let releaseBlockedWork = DispatchSemaphore(value: 0)
        let blockedWorkFinished = DispatchSemaphore(value: 0)
        let staleCompletionMutatedState = DispatchSemaphore(value: 0)
        ownership.begin(owner: owner, phase: .zombieReset)

        blockedQueue.async {
            blockedWorkStarted.signal()
            _ = releaseBlockedWork.wait(timeout: .now() + 2)
            if ownership.finish(owner: owner, phase: .zombieReset) {
                staleCompletionMutatedState.signal()
            }
            blockedWorkFinished.signal()
        }

        assertTrue(
            blockedWorkStarted.wait(timeout: .now() + 1) == .success,
            "the old engine helper should be suspended on its serial queue"
        )

        let claimedOwner = ownership.claimPendingWorkForSuccessor(
            currentEngine: retiredEngine,
            currentQueue: blockedQueue
        )
        assertEqual(
            claimedOwner,
            ParakeetTimedAudioEngineWorkLease(owner: owner, phase: .zombieReset),
            "the successor must synchronously claim pending work on the exact blocked engine and queue"
        )

        let replacementEngine = NSObject()
        let replacementQueue = DispatchQueue(label: "test.parakeet.replacement-engine-queue")
        let replacementOwner = ParakeetAudioEngineQueueOwnerToken(
            generation: 31,
            engine: replacementEngine,
            queue: replacementQueue
        )
        assertTrue(
            replacementOwner.matches(
                generation: 31,
                engine: replacementEngine,
                queue: replacementQueue
            ),
            "successor replacement should own both a fresh engine and serial queue"
        )
        let successorCleanupFinished = DispatchSemaphore(value: 0)
        replacementQueue.async {
            successorCleanupFinished.signal()
        }
        assertTrue(
            successorCleanupFinished.wait(timeout: .now() + 1) == .success,
            "successor cleanup must run on the replacement queue while old work remains blocked"
        )

        releaseBlockedWork.signal()
        assertTrue(
            blockedWorkFinished.wait(timeout: .now() + 1) == .success,
            "the delayed old helper should finish after the test releases it"
        )
        assertTrue(
            staleCompletionMutatedState.wait(timeout: .now()) == .timedOut,
            "old helper completion must not reclaim ownership after successor replacement"
        )
    }

    runSuite("Parakeet recovery-start cancellation replaces a blocked engine and queue") {
        let blockedEngine = NSObject()
        let blockedQueue = DispatchQueue(label: "test.parakeet.blocked-recovery-start")
        let blockedOwner = ParakeetAudioEngineQueueOwnerToken(
            generation: 35,
            engine: blockedEngine,
            queue: blockedQueue
        )
        let ownership = ParakeetTimedAudioEngineWorkOwnership()
        var startAdmission = ParakeetAudioStartAdmissionState()
        let resources = ParakeetEngineQueueTestResources(
            engine: blockedEngine,
            queue: blockedQueue
        )
        var recoveryState = ParakeetZombieRecoveryState()
        let recoveryGeneration = recoveryState.begin(failureKind: "no_sample_callbacks")
        assertTrue(
            recoveryState.advance(to: .restart, generation: recoveryGeneration),
            "the production restart stage should own the leased start operation"
        )
        assertTrue(
            startAdmission.begin(owner: blockedOwner),
            "the blocked recovery start should own the single start-admission slot"
        )

        let blockedStartEntered = DispatchSemaphore(value: 0)
        let releaseBlockedStart = DispatchSemaphore(value: 0)
        let blockedStartFinished = DispatchSemaphore(value: 0)
        let lateCompletionMutatedResources = DispatchSemaphore(value: 0)
        ownership.begin(owner: blockedOwner, phase: .audioStart)
        blockedQueue.async {
            blockedStartEntered.signal()
            _ = releaseBlockedStart.wait(timeout: .now() + 2)
            if ownership.finish(owner: blockedOwner, phase: .audioStart) {
                resources.restoreOriginalResources()
                lateCompletionMutatedResources.signal()
            }
            blockedStartFinished.signal()
        }

        assertTrue(
            blockedStartEntered.wait(timeout: .now() + 1) == .success,
            "recovery install/start work should be suspended on its leased engine queue"
        )

        let claimedLease = ownership.claimPendingWorkForSuccessor(
            currentEngine: blockedEngine,
            currentQueue: blockedQueue
        )
        assertEqual(
            claimedLease,
            ParakeetTimedAudioEngineWorkLease(
                owner: blockedOwner,
                phase: .audioStart
            ),
            "cancellation should claim the exact in-flight recovery-start lease"
        )
        assertTrue(
            startAdmission.finish(owner: blockedOwner),
            "cancellation should release only the blocked start owner's admission"
        )

        let successorEngine = NSObject()
        let successorQueue = DispatchQueue(label: "test.parakeet.recovery-start-successor")
        let successorOwner = ParakeetAudioEngineQueueOwnerToken(
            generation: 36,
            engine: successorEngine,
            queue: successorQueue
        )
        resources.replace(engine: successorEngine, queue: successorQueue)
        assertTrue(
            startAdmission.begin(owner: successorOwner),
            "the replacement graph should be able to admit a successor start immediately"
        )
        let terminal = recoveryState.cancelActiveAttempt()
        assertTrue(
            resources.matches(engine: successorEngine, queue: successorQueue),
            "cancellation should synchronously replace both blocked resources before publishing terminal state"
        )
        assertEqual(terminal?.stage, .restart, "cancellation should terminate the blocked restart stage")
        assertEqual(terminal?.result, .cancelled, "cancellation should publish one cancelled terminal")

        let successorWorkFinished = DispatchSemaphore(value: 0)
        successorQueue.async {
            successorWorkFinished.signal()
        }
        assertTrue(
            successorWorkFinished.wait(timeout: .now() + 1) == .success,
            "successor cleanup should not queue behind blocked recovery-start work"
        )

        releaseBlockedStart.signal()
        assertTrue(
            blockedStartFinished.wait(timeout: .now() + 1) == .success,
            "the delayed recovery-start callback should finish after release"
        )
        assertTrue(
            lateCompletionMutatedResources.wait(timeout: .now()) == .timedOut,
            "late old completion must not reclaim or mutate successor resources"
        )
        assertTrue(
            resources.matches(engine: successorEngine, queue: successorQueue),
            "late old completion must leave the successor engine and queue intact"
        )
        assertFalse(
            startAdmission.finish(owner: blockedOwner),
            "the stale start defer must not clear the successor's admission"
        )
        assertEqual(
            startAdmission.owner,
            successorOwner,
            "the successor must remain the admitted start after stale completion"
        )
    }

    runSuite("Parakeet recovery cancellation releases a pre-lease admitted start") {
        let oldEngine = NSObject()
        let oldQueue = DispatchQueue(label: "test.parakeet.pre-lease-recovery-start")
        let oldOwner = ParakeetAudioEngineQueueOwnerToken(
            generation: 37,
            engine: oldEngine,
            queue: oldQueue
        )
        var startAdmission = ParakeetAudioStartAdmissionState()
        let timedWork = ParakeetTimedAudioEngineWorkOwnership()
        assertTrue(
            startAdmission.begin(owner: oldOwner),
            "route selection and snapshot work should hold start admission before the timed start lease begins"
        )
        assertNil(
            timedWork.claimPendingWorkForSuccessor(currentEngine: oldEngine, currentQueue: oldQueue),
            "pre-lease cancellation should not require a timed engine-work lease"
        )

        let cancelledOwner = startAdmission.cancel()
        assertEqual(cancelledOwner, oldOwner, "stop or wake should release the admitted pre-lease start")

        let successorEngine = NSObject()
        let successorQueue = DispatchQueue(label: "test.parakeet.pre-lease-successor")
        let successorOwner = ParakeetAudioEngineQueueOwnerToken(
            generation: 38,
            engine: successorEngine,
            queue: successorQueue
        )
        assertTrue(
            startAdmission.begin(owner: successorOwner),
            "a successor should start immediately after pre-lease cancellation"
        )
        assertFalse(
            startAdmission.finish(owner: oldOwner),
            "the stale pre-lease start defer must not clear successor admission"
        )
        assertEqual(
            startAdmission.owner,
            successorOwner,
            "successor admission should survive stale pre-lease completion"
        )
    }

    runSuite("Parakeet ordinary-start cancellation replaces a blocked pre-tap snapshot") {
        let blockedEngine = NSObject()
        let blockedQueue = DispatchQueue(label: "test.parakeet.blocked-ordinary-start")
        let blockedOwner = ParakeetAudioEngineQueueOwnerToken(
            generation: 39,
            engine: blockedEngine,
            queue: blockedQueue
        )
        let ownership = ParakeetTimedAudioEngineWorkOwnership()
        let cancellationState = ParakeetAudioStartCancellationState()
        var startAdmission = ParakeetAudioStartAdmissionState()
        let resources = ParakeetEngineQueueTestResources(
            engine: blockedEngine,
            queue: blockedQueue
        )
        assertTrue(startAdmission.begin(owner: blockedOwner), "the normal start should own admission before its snapshot")
        ownership.begin(owner: blockedOwner, phase: .audioStart)

        let blockedStartEntered = DispatchSemaphore(value: 0)
        let releaseBlockedStart = DispatchSemaphore(value: 0)
        let blockedStartFinished = DispatchSemaphore(value: 0)
        let staleStartMutatedResources = DispatchSemaphore(value: 0)
        blockedQueue.async {
            blockedStartEntered.signal()
            _ = releaseBlockedStart.wait(timeout: .now() + 2)
            if cancellationState.canRunWork,
               ownership.isActive(owner: blockedOwner, phase: .audioStart) {
                resources.restoreOriginalResources()
                staleStartMutatedResources.signal()
            }
            ownership.finish(owner: blockedOwner, phase: .audioStart)
            blockedStartFinished.signal()
        }
        assertTrue(
            blockedStartEntered.wait(timeout: .now() + 1) == .success,
            "ordinary pre-tap snapshot work should be in flight before stop"
        )

        // Production stop advances logical generation before the timed-out
        // continuation resumes. Claiming by engine+queue resource identity must
        // still retire that exact blocked worker.
        cancellationState.cancel()
        let claimedLease = ownership.claimPendingWorkForSuccessor(
            currentEngine: blockedEngine,
            currentQueue: blockedQueue
        )
        assertEqual(
            claimedLease,
            ParakeetTimedAudioEngineWorkLease(owner: blockedOwner, phase: .audioStart),
            "stop should claim a blocked ordinary start despite generation invalidation"
        )
        assertTrue(
            startAdmission.finish(owner: blockedOwner),
            "stop should release only the blocked ordinary start admission"
        )

        let successorEngine = NSObject()
        let successorQueue = DispatchQueue(label: "test.parakeet.ordinary-start-successor")
        let successorOwner = ParakeetAudioEngineQueueOwnerToken(
            generation: 41,
            engine: successorEngine,
            queue: successorQueue
        )
        resources.replace(engine: successorEngine, queue: successorQueue)
        assertTrue(
            startAdmission.begin(owner: successorOwner),
            "the replacement queue should admit a successor without another timeout"
        )
        let successorFinished = DispatchSemaphore(value: 0)
        successorQueue.async { successorFinished.signal() }
        assertTrue(
            successorFinished.wait(timeout: .now() + 1) == .success,
            "successor work should run while the retired queue remains blocked"
        )

        releaseBlockedStart.signal()
        assertTrue(
            blockedStartFinished.wait(timeout: .now() + 1) == .success,
            "the test should release the retired worker"
        )
        assertTrue(
            staleStartMutatedResources.wait(timeout: .now()) == .timedOut,
            "a cancelled late start must not reclaim successor resources"
        )
        assertFalse(
            startAdmission.finish(owner: blockedOwner),
            "the stale ordinary-start defer must not clear successor admission"
        )
        assertEqual(startAdmission.owner, successorOwner, "the successor should remain admitted")
    }

    runSuite("Parakeet stop replaces a blocked failed-start reset") {
        let oldEngine = NSObject()
        let oldQueue = DispatchQueue(label: "test.parakeet.blocked-failed-start-reset")
        let oldOwner = ParakeetAudioEngineQueueOwnerToken(
            generation: 43,
            engine: oldEngine,
            queue: oldQueue
        )
        let ownership = ParakeetTimedAudioEngineWorkOwnership()
        var startAdmission = ParakeetAudioStartAdmissionState()
        let resources = ParakeetEngineQueueTestResources(engine: oldEngine, queue: oldQueue)
        assertTrue(startAdmission.begin(owner: oldOwner), "failed-start reset should retain start admission")
        ownership.begin(owner: oldOwner, phase: .audioStart)

        let resetEntered = DispatchSemaphore(value: 0)
        let releaseReset = DispatchSemaphore(value: 0)
        let resetFinished = DispatchSemaphore(value: 0)
        let staleMutation = DispatchSemaphore(value: 0)
        oldQueue.async {
            resetEntered.signal()
            _ = releaseReset.wait(timeout: .now() + 2)
            if ownership.isActive(owner: oldOwner, phase: .audioStart),
               resources.matches(owner: oldOwner) {
                resources.restoreOriginalResources()
                staleMutation.signal()
            }
            ownership.finish(owner: oldOwner, phase: .audioStart)
            resetFinished.signal()
        }
        assertTrue(resetEntered.wait(timeout: .now() + 1) == .success, "failed-start reset should block first")

        let claimed = ownership.claimPendingWorkForSuccessor(
            currentEngine: oldEngine,
            currentQueue: oldQueue
        )
        assertEqual(
            claimed,
            ParakeetTimedAudioEngineWorkLease(owner: oldOwner, phase: .audioStart),
            "stop should claim reset work after logical generation changes"
        )
        let nextEngine = NSObject()
        let nextQueue = DispatchQueue(label: "test.parakeet.failed-start-reset-successor")
        var replacementCount = 0
        let cancellationReplacedGraph: Bool
        if claimed != nil {
            resources.replace(engine: nextEngine, queue: nextQueue)
            replacementCount += 1
            cancellationReplacedGraph = true
        } else {
            cancellationReplacedGraph = false
        }
        if !cancellationReplacedGraph {
            resources.replace(engine: nextEngine, queue: nextQueue)
            replacementCount += 1
        }
        assertEqual(replacementCount, 1, "timeout cleanup should replace the blocked graph exactly once")
        assertTrue(startAdmission.finish(owner: oldOwner), "stop should release the failed start's admission")

        let nextOwner = ParakeetAudioEngineQueueOwnerToken(
            generation: 45,
            engine: nextEngine,
            queue: nextQueue
        )
        assertTrue(startAdmission.begin(owner: nextOwner), "successor should start before old reset returns")
        let successorFinished = DispatchSemaphore(value: 0)
        nextQueue.async { successorFinished.signal() }
        assertTrue(successorFinished.wait(timeout: .now() + 1) == .success, "successor queue should not be denied")

        releaseReset.signal()
        assertTrue(resetFinished.wait(timeout: .now() + 1) == .success, "retired reset should finish")
        assertTrue(staleMutation.wait(timeout: .now()) == .timedOut, "late reset must not mutate successor resources")
        assertFalse(startAdmission.finish(owner: oldOwner), "stale reset must not clear successor admission")
        assertEqual(startAdmission.owner, nextOwner, "successor should remain admitted")
    }

    await runSuite("Parakeet system-input timeout replaces the blocked queue and reconciles late writes") {
        let timeouts = ManualSystemInputTimeouts()
        let coordinator = ParakeetReplaceableSystemInputWorkCoordinator(
            label: "test.parakeet.replaceable-system-input",
            scheduleTimeout: timeouts.schedule
        )
        let temporaryInput = "built-in-input"
        let previousInput = "bluetooth-input"
        let route = ParakeetSystemInputRouteTestState(
            route: temporaryInput,
            recoveryMarkerIsSet: true
        )
        let blockedWorkEntered = ParakeetAsyncInterleavingGate()
        let releaseBlockedWork = DispatchSemaphore(value: 0)
        let lateCompletionReconciled = ParakeetAsyncInterleavingGate()

        let blockedWork = Task {
            do {
                try await coordinator.run(
                    operation: "blocked_restore",
                    timeoutNanoseconds: 20_000_000,
                    cleanupAfterLateCompletion: { _ in
                        route.applyReplacementInput(temporaryInput)
                        Task { await lateCompletionReconciled.open() }
                    }
                ) {
                    Task { await blockedWorkEntered.open() }
                    // Backstop only, so a regression can't strand this worker.
                    _ = releaseBlockedWork.wait(timeout: .now() + .seconds(30))
                    route.restoreIfStillTemporary(
                        temporaryInput: temporaryInput,
                        previousInput: previousInput
                    )
                }
                return false
            } catch is ParakeetSystemInputWorkError {
                return true
            } catch {
                return false
            }
        }

        // The budget runs out only after the work is inside its HAL call.
        await blockedWorkEntered.wait()
        await timeouts.expireNext()
        assertTrue(await blockedWork.value, "the blocked operation should hit its timeout")

        // The successor's own budget never expires: it must finish on the
        // replacement queue while the old work is still blocked. The wait is
        // bounded so a queue-replacement regression fails instead of hanging.
        let successorFinished = DispatchSemaphore(value: 0)
        let successorLock = NSLock()
        var successorCompleted = false
        coordinator.schedule(
            operation: "successor_apply",
            timeoutNanoseconds: 500_000_000,
            completion: { (result: Result<Bool, Error>) in
                if case .success(true) = result {
                    successorLock.withLock { successorCompleted = true }
                }
                successorFinished.signal()
            }
        ) {
            route.applyReplacementInput(temporaryInput)
            return true
        }
        let successorReturned = await signalled(successorFinished)
        assertTrue(
            successorReturned && successorLock.withLock { successorCompleted },
            "a successor must run on the replacement queue before old HAL work returns"
        )

        releaseBlockedWork.signal()
        await lateCompletionReconciled.wait()
        assertEqual(
            route.currentRoute(),
            temporaryInput,
            "late stale restore must converge back to the successor route"
        )
    }

    await runSuite("Parakeet system-input timeout circuit caps permanently blocked workers") {
        let timeouts = ManualSystemInputTimeouts()
        let coordinator = ParakeetReplaceableSystemInputWorkCoordinator(
            label: "test.parakeet.bounded-system-input",
            scheduleTimeout: timeouts.schedule
        )
        let releaseWorkers = DispatchSemaphore(value: 0)
        let allWorkersCompleted = ParakeetAsyncInterleavingGate()
        let countLock = NSLock()
        var workersEntered = 0
        var workersCompleted = 0
        var timeoutErrors = 0
        var circuitOpenErrors = 0

        func record(_ error: Error) {
            switch error as? ParakeetSystemInputWorkError {
            case .timedOut:
                timeoutErrors += 1
            case .circuitOpen:
                circuitOpenErrors += 1
            case nil:
                assertTrue(false, "unexpected system-input circuit error: \(error)")
            }
        }

        // Two workers enter, block, and run out of budget while blocked.
        for attempt in 0..<2 {
            let entered = DispatchSemaphore(value: 0)
            let blocked = Task {
                try await coordinator.run(
                    operation: "blocked_\(attempt)",
                    timeoutNanoseconds: 20_000_000
                ) {
                    countLock.withLock { workersEntered += 1 }
                    entered.signal()
                    releaseWorkers.wait()
                    let allDone = countLock.withLock {
                        workersCompleted += 1
                        return workersCompleted == 2
                    }
                    if allDone {
                        Task { await allWorkersCompleted.open() }
                    }
                    return true
                }
            }
            guard await signalled(entered) else {
                // The queue wasn't replaced after the last timeout. Unblock
                // everything and fail rather than hang the fast suite.
                assertTrue(false, "blocked_\(attempt) must enter on a replacement queue")
                releaseWorkers.signal()
                releaseWorkers.signal()
                await timeouts.expireNext()
                _ = try? await blocked.value
                return
            }
            await timeouts.expireNext()
            do {
                _ = try await blocked.value
                assertTrue(false, "a blocked worker must not report success")
            } catch {
                record(error)
            }
        }

        // With both still blocked, the circuit is open: later work fails
        // without entering or scheduling a timeout.
        for attempt in 2..<12 {
            do {
                _ = try await coordinator.run(
                    operation: "blocked_\(attempt)",
                    timeoutNanoseconds: 20_000_000
                ) {
                    countLock.withLock { workersEntered += 1 }
                    return true
                }
                assertTrue(false, "an open circuit must not run work")
            } catch {
                record(error)
            }
        }

        assertEqual(countLock.withLock { workersEntered }, 2, "the circuit must cap permanently blocked worker closures")
        assertEqual(timeoutErrors, 2, "every admitted blocked worker must time out")
        assertEqual(circuitOpenErrors, 10, "after two workers block, later attempts must fail without entering work")
        assertEqual(timeouts.pendingCount, 0, "circuit-open attempts must not start a budget")

        releaseWorkers.signal()
        releaseWorkers.signal()
        await allWorkersCompleted.wait()
        assertEqual(countLock.withLock { workersCompleted }, 2, "bounded test workers should shut down after release")
    }

    runSuite("Parakeet system-input budget that runs out before work starts skips it and spends no capacity") {
        let timeouts = ManualSystemInputTimeouts()
        let coordinator = ParakeetReplaceableSystemInputWorkCoordinator(
            label: "test.parakeet.expired-before-start",
            scheduleTimeout: timeouts.schedule
        )
        let outcomeLock = NSLock()
        var outcomes: [String: Result<Bool, Error>] = [:]
        func submit(_ operation: String, _ work: @escaping () -> Bool) -> DispatchSemaphore {
            let finished = DispatchSemaphore(value: 0)
            coordinator.schedule(
                operation: operation,
                timeoutNanoseconds: 20_000_000,
                completion: { (result: Result<Bool, Error>) in
                    outcomeLock.withLock { outcomes[operation] = result }
                    finished.signal()
                },
                work
            )
            return finished
        }
        func outcome(_ operation: String) -> Result<Bool, Error>? {
            outcomeLock.withLock { outcomes[operation] }
        }
        func isTimedOut(_ result: Result<Bool, Error>?) -> Bool {
            guard case .failure(let error)? = result,
                  case .timedOut? = error as? ParakeetSystemInputWorkError else { return false }
            return true
        }

        // A holder occupies the first queue; its budget is never expired.
        let holderEntered = DispatchSemaphore(value: 0)
        let releaseHolder = DispatchSemaphore(value: 0)
        let holderFinished = submit("holder") {
            holderEntered.signal()
            _ = releaseHolder.wait(timeout: .now() + .seconds(30))
            return true
        }
        assertTrue(holderEntered.wait(timeout: .now() + .seconds(10)) == .success, "holder should enter")

        // Two operations queue behind it. The first one's budget runs out
        // before it can start.
        let skippedLock = NSLock()
        var expiredWorkRan = false
        let expiredFinished = submit("expired_before_start") {
            skippedLock.withLock { expiredWorkRan = true }
            return true
        }
        let trailingFinished = submit("queued_behind") { true }
        timeouts.expire(at: 1)
        assertTrue(expiredFinished.wait(timeout: .now()) == .success, "an expired budget should fail the caller right away")
        assertTrue(isTimedOut(outcome("expired_before_start")), "work that never started should report a timeout")

        // Nothing blocked, so the circuit still admits two blocked workers.
        let releaseWorkers = DispatchSemaphore(value: 0)
        for attempt in 0..<2 {
            let entered = DispatchSemaphore(value: 0)
            let finished = submit("blocked_\(attempt)") {
                entered.signal()
                _ = releaseWorkers.wait(timeout: .now() + .seconds(30))
                return true
            }
            guard entered.wait(timeout: .now() + .seconds(10)) == .success else {
                assertTrue(false, "blocked_\(attempt) should get its own queue; unstarted work must not spend capacity")
                releaseHolder.signal()
                releaseWorkers.signal()
                releaseWorkers.signal()
                return
            }
            timeouts.expire(at: timeouts.pendingCount - 1)
            assertTrue(finished.wait(timeout: .now()) == .success, "blocked_\(attempt) should time out")
            assertTrue(isTimedOut(outcome("blocked_\(attempt)")), "blocked_\(attempt) should report a timeout")
        }
        let openFinished = submit("after_two_blocked") { true }
        assertTrue(openFinished.wait(timeout: .now()) == .success, "an open circuit should fail right away")
        let circuitOpened: Bool = {
            guard case .failure(let error)? = outcome("after_two_blocked"),
                  case .circuitOpen? = error as? ParakeetSystemInputWorkError else { return false }
            return true
        }()
        assertTrue(circuitOpened, "two started-then-blocked workers should open the circuit")

        // Releasing the holder drains the first queue in order. The trailing
        // operation finishing proves the expired one's slot already passed.
        releaseHolder.signal()
        assertTrue(holderFinished.wait(timeout: .now() + .seconds(10)) == .success, "holder should finish")
        assertTrue(trailingFinished.wait(timeout: .now() + .seconds(10)) == .success, "queued work should finish")
        assertTrue(outcome("queued_behind").flatMap { try? $0.get() } == true, "queued work within budget should succeed")
        assertFalse(skippedLock.withLock { expiredWorkRan }, "work whose budget ran out before it started must never run")

        releaseWorkers.signal()
        releaseWorkers.signal()
    }

    runSuite("Parakeet queued recovery start cancellation skips retired work") {
        let engine = NSObject()
        let queue = DispatchQueue(label: "test.parakeet.cancelled-queued-start")
        let owner = ParakeetAudioEngineQueueOwnerToken(
            generation: 70,
            engine: engine,
            queue: queue
        )
        let ownership = ParakeetTimedAudioEngineWorkOwnership()
        ownership.begin(owner: owner, phase: .audioStart)

        assertEqual(
            ownership.claimPendingWorkForSuccessor(currentEngine: engine, currentQueue: queue)?.owner,
            owner,
            "stop should synchronously claim the queued recovery-start lease"
        )

        let retiredWorkRan = DispatchSemaphore(value: 0)
        let queuedWorkFinished = DispatchSemaphore(value: 0)
        queue.async {
            if ownership.isActive(owner: owner, phase: .audioStart) {
                retiredWorkRan.signal()
            }
            queuedWorkFinished.signal()
        }

        assertTrue(
            queuedWorkFinished.wait(timeout: .now() + 1) == .success,
            "the retired queue should drain without entering cancelled start work"
        )
        assertTrue(
            retiredWorkRan.wait(timeout: .now()) == .timedOut,
            "a claimed queued lease must fail the worker-entry gate before touching the microphone"
        )
    }

    runSuite("Parakeet in-flight recovery start cancellation cleans on its worker") {
        let engine = NSObject()
        let queue = DispatchQueue(label: "test.parakeet.cancelled-inflight-start")
        let owner = ParakeetAudioEngineQueueOwnerToken(
            generation: 71,
            engine: engine,
            queue: queue
        )
        let ownership = ParakeetTimedAudioEngineWorkOwnership()
        ownership.begin(owner: owner, phase: .audioStart)

        let workEntered = DispatchSemaphore(value: 0)
        let releaseWork = DispatchSemaphore(value: 0)
        let cleanupRan = DispatchSemaphore(value: 0)
        let workFinished = DispatchSemaphore(value: 0)
        queue.async {
            guard ownership.isActive(owner: owner, phase: .audioStart) else {
                workFinished.signal()
                return
            }
            workEntered.signal()
            _ = releaseWork.wait(timeout: .now() + 2)
            if !ownership.isActive(owner: owner, phase: .audioStart) {
                cleanupRan.signal()
            }
            workFinished.signal()
        }

        assertTrue(
            workEntered.wait(timeout: .now() + 1) == .success,
            "the recovery start should enter work before stop claims its lease"
        )
        assertNotNil(
            ownership.claimPendingWorkForSuccessor(currentEngine: engine, currentQueue: queue),
            "stop should claim an in-flight recovery-start lease"
        )
        releaseWork.signal()

        assertTrue(
            cleanupRan.wait(timeout: .now() + 1) == .success,
            "in-flight cancellation should trigger cleanup on the retiring worker queue"
        )
        assertTrue(
            workFinished.wait(timeout: .now() + 1) == .success,
            "cleanup should finish before retired work leaves its serial queue"
        )
    }

    runSuite("Parakeet recovery start cancellation preserves only committed callbacks") {
        let cancelledBeforeCommit = ParakeetAudioStartCancellationState()
        assertTrue(cancelledBeforeCommit.canRunWork, "a fresh recovery start should enter worker work")
        assertTrue(cancelledBeforeCommit.canDeliverSamples, "a fresh tap may deliver during start")

        cancelledBeforeCommit.cancel()
        assertFalse(cancelledBeforeCommit.canRunWork, "stop should gate queued or in-flight work")
        assertFalse(cancelledBeforeCommit.canDeliverSamples, "stop should gate stale tap callbacks")
        assertFalse(cancelledBeforeCommit.commit(), "a cancelled start cannot become a recording")

        let committedRecording = ParakeetAudioStartCancellationState()
        assertTrue(committedRecording.commit(), "the exact successful owner should commit its tap")
        assertFalse(committedRecording.canRunWork, "committed state is no longer start work")
        assertTrue(committedRecording.canDeliverSamples, "committing must not silence the recovered recording")

        committedRecording.cancel()
        assertFalse(committedRecording.canDeliverSamples, "a later user stop should silence committed callbacks immediately")
    }

    runSuite("Parakeet config-recovery lease preserves a successor owner") {
        let ownership = ParakeetTimedAudioEngineWorkOwnership()
        let blockedEngine = NSObject()
        let blockedQueue = NSObject()
        let blockedOwner = ParakeetAudioEngineQueueOwnerToken(
            generation: 1,
            engine: blockedEngine,
            queue: blockedQueue
        )
        ownership.begin(owner: blockedOwner, phase: .deviceRecoverySnapshot)

        let claimed = ownership.claimPendingWorkForSuccessor(
            currentEngine: blockedEngine,
            currentQueue: blockedQueue
        )
        assertEqual(
            claimed,
            ParakeetTimedAudioEngineWorkLease(owner: blockedOwner, phase: .deviceRecoverySnapshot),
            "stop should claim the exact blocked recovery snapshot"
        )

        let successorOwner = ParakeetAudioEngineQueueOwnerToken(
            generation: 2,
            engine: NSObject(),
            queue: NSObject()
        )
        ownership.begin(owner: successorOwner, phase: .deviceRecoverySnapshot)
        assertFalse(
            ownership.finish(owner: blockedOwner, phase: .deviceRecoverySnapshot),
            "late completion from the retired queue must not clear successor work"
        )
        assertTrue(
            ownership.finish(owner: successorOwner, phase: .deviceRecoverySnapshot),
            "the successor should retain and finish its own lease"
        )
    }

}
private final class ParakeetEngineQueueTestResources: @unchecked Sendable {
    private let lock = NSLock()
    private let originalEngine: AnyObject
    private let originalQueue: DispatchQueue
    private var engine: AnyObject
    private var queue: DispatchQueue

    init(engine: AnyObject, queue: DispatchQueue) {
        originalEngine = engine
        originalQueue = queue
        self.engine = engine
        self.queue = queue
    }

    func replace(engine: AnyObject, queue: DispatchQueue) {
        lock.lock()
        self.engine = engine
        self.queue = queue
        lock.unlock()
    }

    func restoreOriginalResources() {
        replace(engine: originalEngine, queue: originalQueue)
    }

    func matches(engine: AnyObject, queue: DispatchQueue) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return ObjectIdentifier(self.engine) == ObjectIdentifier(engine)
            && ObjectIdentifier(self.queue) == ObjectIdentifier(queue)
    }

    func matches(owner: ParakeetAudioEngineQueueOwnerToken) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return ObjectIdentifier(engine) == owner.graphOwner.engineIdentity
            && ObjectIdentifier(queue) == owner.queueIdentity
    }
}

private final class ParakeetSystemInputRouteTestState: @unchecked Sendable {
    private let lock = NSLock()
    private var route: String
    private var markerIsSet: Bool

    init(route: String, recoveryMarkerIsSet: Bool) {
        self.route = route
        markerIsSet = recoveryMarkerIsSet
    }

    func restoreIfStillTemporary(temporaryInput: String, previousInput: String) {
        lock.lock()
        defer { lock.unlock() }
        guard route == temporaryInput else { return }
        route = previousInput
    }

    func applyReplacementInput(_ input: String) {
        lock.lock()
        route = input
        lock.unlock()
    }

    func currentRoute() -> String {
        lock.lock()
        defer { lock.unlock() }
        return route
    }

    func clearRecoveryMarker() {
        lock.lock()
        markerIsSet = false
        lock.unlock()
    }

    func recoveryMarkerIsSet() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return markerIsSet
    }
}

private actor RecordedAudioConversionBarrier {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func block() async {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilBlocked() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

/// A system-input budget timer the test expires by hand. `expireNext` waits
/// until an operation has started its budget, so the test never races the
/// coordinator's own scheduling.
private final class ManualSystemInputTimeouts: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [() -> Void] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var pendingCount: Int { lock.withLock { pending.count } }

    func schedule(_ timeoutNanoseconds: UInt64, _ expire: @escaping () -> Void) {
        let ready = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            pending.append(expire)
            defer { waiters.removeAll() }
            return waiters
        }
        ready.forEach { $0.resume() }
    }

    /// Expires one specific pending budget, oldest first.
    func expire(at index: Int) {
        let expire = lock.withLock { pending.indices.contains(index) ? pending.remove(at: index) : nil }
        expire?()
    }

    func expireNext() async {
        while true {
            let next = lock.withLock { pending.isEmpty ? nil : pending.removeFirst() }
            if let next {
                next()
                return
            }
            await withCheckedContinuation { continuation in
                let alreadyScheduled = lock.withLock { () -> Bool in
                    if pending.isEmpty {
                        waiters.append(continuation)
                        return false
                    }
                    return true
                }
                if alreadyScheduled { continuation.resume() }
            }
        }
    }
}

/// Waits for `semaphore` off the cooperative pool. The bound only turns a
/// regression into a failure instead of a hung fast suite.
private func signalled(_ semaphore: DispatchSemaphore) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: semaphore.wait(timeout: .now() + .seconds(10)) == .success)
        }
    }
}
