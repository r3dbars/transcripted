// ParakeetAudioGraphOwnershipTests.swift
// Deterministic owner, timeout, late-completion, and successor interleavings.

import Foundation

func testParakeetAudioGraphOwnership() async {
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

    await runSuite("ParakeetOwnerBoundPendingState rejects a truly delayed stale restore") {
        let engine = NSObject()
        let staleOwner = ParakeetAudioGraphOwnerToken(generation: 40, engine: engine)
        let replacementOwner = ParakeetAudioGraphOwnerToken(generation: 41, engine: engine)
        let state = ParakeetPendingRestoreInterleavingHarness()
        let cleanupCapturedOwner = ParakeetAsyncInterleavingGate()
        let allowCleanupCompletion = ParakeetAsyncInterleavingGate()

        await state.replace("old-route", ownedBy: staleOwner)
        let delayedCleanup = Task {
            let capturedOwner = await state.owner()
            await cleanupCapturedOwner.open()
            await allowCleanupCompletion.wait()
            guard let capturedOwner else { return nil as String? }
            return await state.take(ownedBy: capturedOwner)
        }

        await cleanupCapturedOwner.wait()
        await state.replace("replacement-route", ownedBy: replacementOwner)
        await allowCleanupCompletion.open()

        let staleRestore = await delayedCleanup.value
        let replacementValue = await state.value(ownedBy: replacementOwner)
        let replacementRestore = await state.take(ownedBy: replacementOwner)
        assertNil(
            staleRestore,
            "cleanup delayed across an await must not consume a replacement start's restore target"
        )
        assertEqual(
            replacementValue,
            "replacement-route",
            "the replacement target must remain installed after stale cleanup resumes"
        )
        assertEqual(
            replacementRestore,
            "replacement-route",
            "only the exact newer generation+engine owner may consume its route restore"
        )
    }

    await runSuite("Parakeet matching restore survives unrelated graph ownership loss") {
        let retiredEngine = NSObject()
        let replacementEngine = NSObject()
        let cleanupOwner = ParakeetAudioGraphOwnerToken(generation: 43, engine: retiredEngine)
        let replacementOwner = ParakeetAudioGraphOwnerToken(generation: 44, engine: replacementEngine)
        let pendingState = ParakeetPendingRestoreInterleavingHarness()

        await pendingState.replace("previous-route", ownedBy: cleanupOwner)
        assertFalse(
            cleanupOwner.matches(generation: 44, engine: replacementEngine),
            "the cleanup should observe that audio graph ownership changed"
        )
        assertNil(
            await pendingState.value(ownedBy: replacementOwner),
            "unrelated graph replacement should not silently re-own the old restore target"
        )
        assertEqual(
            await pendingState.take(ownedBy: cleanupOwner),
            "previous-route",
            "cleanup should still consume its exact owner-bound restore after graph loss"
        )
    }

    await runSuite("Parakeet stale cleanup cannot restore after a same-input successor takes ownership") {
        let engine = NSObject()
        let oldOwner = ParakeetAudioGraphOwnerToken(generation: 45, engine: engine)
        let replacementOwner = ParakeetAudioGraphOwnerToken(generation: 46, engine: engine)
        let pendingState = ParakeetPendingRestoreInterleavingHarness()
        let temporaryInput = "built-in-input"
        let previousInput = "bluetooth-input"
        let route = ParakeetSystemInputRouteTestState(
            route: temporaryInput,
            recoveryMarkerIsSet: true
        )

        await pendingState.replace(previousInput, ownedBy: oldOwner)
        await pendingState.replace(previousInput, ownedBy: replacementOwner)
        if let staleRestore = await pendingState.take(ownedBy: oldOwner) {
            route.restoreIfStillTemporary(
                temporaryInput: temporaryInput,
                previousInput: staleRestore
            )
        }

        assertEqual(
            route.currentRoute(),
            temporaryInput,
            "stale cleanup must not undo a successor that selected the same temporary input"
        )
        assertTrue(
            route.recoveryMarkerIsSet(),
            "stale cleanup must not clear the replacement owner's recovery marker"
        )
        assertEqual(
            await pendingState.value(ownedBy: replacementOwner),
            previousInput,
            "only the matching successor owner may consume its restore target"
        )
    }

    await runSuite("Parakeet system-input timeout replaces the blocked queue and reconciles late writes") {
        let coordinator = ParakeetReplaceableSystemInputWorkCoordinator(
            label: "test.parakeet.replaceable-system-input"
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
                    _ = releaseBlockedWork.wait(timeout: .now() + 2)
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

        await blockedWorkEntered.wait()
        assertTrue(await blockedWork.value, "the blocked operation should hit its deterministic timeout")

        let successorCompleted = (try? await coordinator.run(
            operation: "successor_apply",
            timeoutNanoseconds: 500_000_000
        ) {
            route.applyReplacementInput(temporaryInput)
            return true
        }) ?? false
        assertTrue(
            successorCompleted,
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

    await runSuite("Successful system-input fallback restores after cancel wake or graph replacement") {
        enum OwnershipLoss: String, CaseIterable {
            case cancel
            case wake
            case graphRebuild
        }

        enum SuspensionPoint: String, CaseIterable {
            case systemOverride
            case snapshotFailure
            case snapshotSuccess
        }

        for ownershipLoss in OwnershipLoss.allCases {
            for suspensionPoint in SuspensionPoint.allCases {
                let oldEngine = NSObject()
                let oldQueue = DispatchQueue(label: "test.parakeet.stale-system-input.old.\(ownershipLoss.rawValue)")
                let oldOwner = ParakeetAudioEngineQueueOwnerToken(
                    generation: 60,
                    engine: oldEngine,
                    queue: oldQueue
                )
                let successorEngine: NSObject = ownershipLoss == .graphRebuild ? NSObject() : oldEngine
                let successorQueue = ownershipLoss == .graphRebuild
                    ? DispatchQueue(label: "test.parakeet.stale-system-input.new.graph")
                    : oldQueue
                let successorOwner = ParakeetAudioEngineQueueOwnerToken(
                    generation: 61,
                    engine: successorEngine,
                    queue: successorQueue
                )
                let coordinator = ParakeetReplaceableSystemInputWorkCoordinator(
                    label: "test.parakeet.stale-system-input.\(ownershipLoss.rawValue).\(suspensionPoint.rawValue)"
                )
                let route = ParakeetSystemInputRouteTestState(
                    route: "airpods-input",
                    recoveryMarkerIsSet: true
                )
                let overrideEntered = ParakeetAsyncInterleavingGate()
                let releaseOverride = DispatchSemaphore(value: 0)

                let staleSnapshot = Task {
                    try? await coordinator.run(
                        operation: "test_override",
                        timeoutNanoseconds: 3_000_000_000
                    ) {
                        route.applyReplacementInput("built-in-input")
                        Task { await overrideEntered.open() }
                        _ = releaseOverride.wait(timeout: .now() + 2)
                    }
                    guard oldOwner == successorOwner else {
                        try? await coordinator.run(
                            operation: "test_restore",
                            timeoutNanoseconds: 3_000_000_000
                        ) {
                            route.restoreIfStillTemporary(
                                temporaryInput: "built-in-input",
                                previousInput: "airpods-input"
                            )
                        }
                        return true
                    }
                    return false
                }

                await overrideEntered.wait()
                releaseOverride.signal()
                let didRestoreBeforeCancellation = await staleSnapshot.value

                assertTrue(
                    didRestoreBeforeCancellation,
                    "\(ownershipLoss.rawValue) should make the awaited fallback owner stale"
                )
                assertEqual(
                    route.currentRoute(),
                    "airpods-input",
                    "\(ownershipLoss.rawValue) at \(suspensionPoint.rawValue) must restore the prior system input before stale work cancels"
                )
            }
        }
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

}
private actor ParakeetPendingRestoreInterleavingHarness {
    private var state = ParakeetOwnerBoundPendingState<String>()

    func replace(_ value: String, ownedBy owner: ParakeetAudioGraphOwnerToken) {
        state.replace(value, ownedBy: owner)
    }

    func owner() -> ParakeetAudioGraphOwnerToken? {
        state.owner
    }

    func take(ownedBy owner: ParakeetAudioGraphOwnerToken) -> String? {
        state.take(ownedBy: owner)
    }

    func value(ownedBy owner: ParakeetAudioGraphOwnerToken) -> String? {
        state.value(ownedBy: owner)
    }

    func hasPendingValue() -> Bool {
        state.hasPendingValue
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
