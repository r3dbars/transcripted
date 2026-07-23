// ParakeetRecoveryStateTests.swift
// Tests for the device-change recovery state machine — generation guard,
// readiness flags, transitions across config-change → recovery → success.

import Foundation

func testParakeetRecoveryState() async {
    runSuite("ParakeetRecoveryState — initial state is ready and not recovering") {
        let state = ParakeetRecoveryState()
        assertFalse(state.isRecovering, "fresh state should not be recovering")
        assertTrue(state.inputFormatReady, "fresh state should report format ready")
        assertEqual(state.generation, 0, "fresh state should be generation 0")
    }

    runSuite("ParakeetRecoveryState.beginConfigChange — enters recovery and bumps generation") {
        var state = ParakeetRecoveryState()
        let g = state.beginConfigChange()

        assertEqual(g, 1, "first config change should be generation 1")
        assertTrue(state.isRecovering, "config change should mark recovery active")
        assertFalse(state.inputFormatReady, "config change should clear format-ready")
        assertEqual(state.generation, 1, "generation should be advanced")
    }

    runSuite("ParakeetRecoveryState.finishRecovery — success clears flags for matching generation") {
        var state = ParakeetRecoveryState()
        let g = state.beginConfigChange()
        let applied = state.finishRecovery(success: true, generation: g)

        assertTrue(applied, "matching generation should apply")
        assertFalse(state.isRecovering, "successful finish should clear recovery flag")
        assertTrue(state.inputFormatReady, "successful finish should mark format ready")
    }

    runSuite("ParakeetRecoveryState.finishRecovery — failure clears recovery but leaves format unready") {
        var state = ParakeetRecoveryState()
        let g = state.beginConfigChange()
        let applied = state.finishRecovery(success: false, generation: g)

        assertTrue(applied, "matching generation should apply")
        assertFalse(state.isRecovering, "failed finish should clear recovery flag")
        assertFalse(state.inputFormatReady, "failed finish should leave format unready")
    }

    runSuite("ParakeetRecoveryState.finishRecovery — stale generation is rejected") {
        var state = ParakeetRecoveryState()
        let firstGen = state.beginConfigChange()
        _ = state.beginConfigChange()  // newer device change supersedes
        let applied = state.finishRecovery(success: true, generation: firstGen)

        assertFalse(applied, "stale finish should be rejected")
        assertTrue(state.isRecovering, "newer recovery should still be active")
        assertFalse(state.inputFormatReady, "format should still be unready after stale finish")
    }

    runSuite("ParakeetRecoveryState.finishRecovery — stale failure cannot poison newer ready generation") {
        var state = ParakeetRecoveryState()
        let staleGeneration = state.beginConfigChange()
        let currentGeneration = state.beginConfigChange()

        assertTrue(state.finishRecovery(success: true, generation: currentGeneration), "current recovery should mark the graph ready")
        assertFalse(state.finishRecovery(success: false, generation: staleGeneration), "stale failure must be rejected")
        assertTrue(state.canStartRecording, "late failure from an old graph must not poison the ready graph")
    }

    runSuite("ParakeetRecoveryState.timeoutRecovery — fails active recovery and supersedes stale tasks") {
        var state = ParakeetRecoveryState()
        let recoveryGeneration = state.beginConfigChange()
        let applied = state.timeoutRecovery(generation: recoveryGeneration)

        assertTrue(applied, "matching active recovery should time out")
        assertFalse(state.isRecovering, "timeout should clear active recovery")
        assertFalse(state.inputFormatReady, "timeout should leave input unready for prewarm")
        assertTrue(state.isStale(generation: recoveryGeneration), "timeout should supersede the stuck recovery generation")
    }

    runSuite("ParakeetRecoveryState.timeoutRecovery — ignores stale or finished recovery") {
        var state = ParakeetRecoveryState()
        let recoveryGeneration = state.beginConfigChange()
        _ = state.finishRecovery(success: true, generation: recoveryGeneration)

        assertFalse(state.timeoutRecovery(generation: recoveryGeneration), "finished recovery should not time out later")
        assertTrue(state.inputFormatReady, "finished recovery should keep its ready state")
    }

    runSuite("ParakeetRecoveryState.timeoutRecovery — rejects superseded generations") {
        var state = ParakeetRecoveryState()
        let staleGeneration = state.beginConfigChange()
        _ = state.beginConfigChange()

        assertFalse(state.timeoutRecovery(generation: staleGeneration), "stale timeout should not affect newer recovery")
        assertTrue(state.isRecovering, "newer recovery should stay active")
        assertFalse(state.inputFormatReady, "newer recovery should keep input unready")
    }

    runSuite("ParakeetRecoveryState.timeoutRecovery — stale timeout cannot poison newer ready generation") {
        var state = ParakeetRecoveryState()
        let staleGeneration = state.beginConfigChange()
        let currentGeneration = state.beginConfigChange()

        assertTrue(state.finishRecovery(success: true, generation: currentGeneration), "current recovery should mark input ready")
        assertFalse(state.timeoutRecovery(generation: staleGeneration), "stale timeout must not apply after newer success")
        assertTrue(state.canStartRecording, "late timeout from an old graph must not block recording")
    }

    runSuite("ParakeetRecoveryState.timeoutRecovery — ignores pristine state") {
        var state = ParakeetRecoveryState()

        assertFalse(state.timeoutRecovery(generation: 0), "fresh non-recovering state should not time out")
        assertFalse(state.isRecovering, "fresh state should remain not recovering")
        assertTrue(state.inputFormatReady, "fresh state should remain ready")
    }

    runSuite("ParakeetRecoveryState.finishRecovery — timeout supersedes late success") {
        var state = ParakeetRecoveryState()
        let recoveryGeneration = state.beginConfigChange()
        _ = state.timeoutRecovery(generation: recoveryGeneration)

        assertFalse(state.finishRecovery(success: true, generation: recoveryGeneration), "late recovery success should stay stale after timeout")
        assertFalse(state.isRecovering, "timed-out state should remain not recovering")
        assertFalse(state.inputFormatReady, "late success should not mark timed-out input ready")
    }

    runSuite("ParakeetRecoveryState.isStale — detects superseded generations") {
        var state = ParakeetRecoveryState()
        let g1 = state.beginConfigChange()
        assertFalse(state.isStale(generation: g1), "current generation is not stale")

        _ = state.beginConfigChange()
        assertTrue(state.isStale(generation: g1), "earlier generation is stale once superseded")
    }

    runSuite("ParakeetRecoveryState.markFormatReady — clears recovery and marks format ready without bumping generation") {
        var state = ParakeetRecoveryState()
        let g = state.beginConfigChange()
        state.markFormatReady()

        assertFalse(state.isRecovering, "markFormatReady should clear recovery flag")
        assertTrue(state.inputFormatReady, "markFormatReady should mark format ready")
        assertEqual(state.generation, g, "markFormatReady should not bump generation")
    }

    runSuite("ParakeetRecoveryState.markFormatUnready — flips format flag without bumping generation") {
        var state = ParakeetRecoveryState()
        let before = state.generation
        state.markFormatUnready()

        assertFalse(state.inputFormatReady, "format should be unready after explicit mark")
        assertEqual(state.generation, before, "marking format unready should not bump generation")
        assertFalse(state.isRecovering, "marking format unready alone should not set recovery flag")
    }

    runSuite("ParakeetRecoveryState.canStartRecording — requires recovery to be done and format ready") {
        var state = ParakeetRecoveryState()
        assertTrue(state.canStartRecording, "fresh state should allow recording starts")

        let generation = state.beginConfigChange()
        assertFalse(state.canStartRecording, "active recovery should block recording starts")

        _ = state.finishRecovery(success: true, generation: generation)
        assertTrue(state.canStartRecording, "successful recovery should allow recording starts again")

        state.markStartFailed()
        assertFalse(state.canStartRecording, "start failure should hold recording until prewarm marks format ready")
    }

    runSuite("ParakeetRecoveryState.markStartFailed — does not bump generation or enter recovery") {
        var state = ParakeetRecoveryState()
        let before = state.generation
        state.markStartFailed()

        assertFalse(state.inputFormatReady, "start failure should mark format unready")
        assertFalse(state.isRecovering, "plain start failure should not pretend a device-change recovery is active")
        assertEqual(state.generation, before, "plain start failure should not supersede device-change generations")
    }

    runSuite("ParakeetRecoveryState.markStartFailed — preserves active recovery generation") {
        var state = ParakeetRecoveryState()
        let generation = state.beginConfigChange()

        state.markStartFailed()

        assertTrue(state.isRecovering, "start failure during device recovery should keep recovery visible")
        assertFalse(state.inputFormatReady, "start failure should keep the input format unready")
        assertEqual(state.generation, generation, "start failure should not supersede the active recovery generation")
    }

    runSuite("ParakeetRecoveryState.markFormatReady — recovers after start failure") {
        var state = ParakeetRecoveryState()
        state.markStartFailed()

        state.markFormatReady()

        assertTrue(state.canStartRecording, "format-ready should unblock recording after a failed start")
    }

    runSuite("ParakeetRecoveryState.reset — clears cancellation leftovers and supersedes older recovery tasks") {
        var state = ParakeetRecoveryState()
        let staleGeneration = state.beginConfigChange()

        state.reset()

        assertFalse(state.isRecovering, "reset should clear recovering state")
        assertTrue(state.inputFormatReady, "reset should restore ready state for a fresh start")
        assertTrue(state.canStartRecording, "reset should allow a new start attempt")
        assertTrue(state.isStale(generation: staleGeneration), "reset should supersede in-flight recovery tasks")
    }

    runSuite("ParakeetRouteTransitionDebounceState emits one stable categorical transition") {
        let builtIn = categoricalRoute(input: "built_in", output: "built_in", shape: "built_in_to_built_in")
        let bluetooth = categoricalRoute(input: "bluetooth", output: "bluetooth", shape: "bluetooth_to_bluetooth")
        var state = ParakeetRouteTransitionDebounceState()
        state.seedStableRouteIfNeeded(builtIn)

        state.observe(bluetooth)
        state.observe(bluetooth)
        let transition = state.commitPendingRoute()

        assertEqual(transition, bluetooth, "repeated notifications should coalesce into one stable route transition")
        assertEqual(state.commitPendingRoute(), nil, "a committed burst should not emit a second transition")

        state.observe(bluetooth)
        assertEqual(state.commitPendingRoute(), nil, "the already-stable route should stay quiet")
    }

    runSuite("ParakeetRouteTransitionDebounceState suppresses oscillation back to the original route") {
        let builtIn = categoricalRoute(input: "built_in", output: "built_in", shape: "built_in_to_built_in")
        let bluetooth = categoricalRoute(input: "bluetooth", output: "bluetooth", shape: "bluetooth_to_bluetooth")
        var state = ParakeetRouteTransitionDebounceState()
        state.seedStableRouteIfNeeded(builtIn)

        state.observe(bluetooth)
        state.observe(builtIn)

        assertEqual(state.commitPendingRoute(), nil, "A -> B -> A notification churn is not a stable route change")
        assertEqual(state.stableRoute, builtIn, "oscillation should preserve the original stable route")
    }

    runSuite("ParakeetRouteTransitionDebounceState treats the first known route as a baseline") {
        let builtIn = categoricalRoute(input: "built_in", output: "built_in", shape: "built_in_to_built_in")
        var state = ParakeetRouteTransitionDebounceState()

        state.observe(builtIn)

        assertEqual(state.commitPendingRoute(), nil, "initial discovery should seed a baseline instead of claiming a transition")
        assertEqual(state.stableRoute, builtIn, "initial discovery should become the stable baseline")
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
        ownership.begin(owner: blockedOwner, phase: .zombieRecoveryStart)
        blockedQueue.async {
            blockedStartEntered.signal()
            _ = releaseBlockedStart.wait(timeout: .now() + 2)
            if ownership.finish(owner: blockedOwner, phase: .zombieRecoveryStart) {
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
                phase: .zombieRecoveryStart
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

    await runSuite("Parakeet pending restore preserves a same-input replacement after take") {
        let engine = NSObject()
        let oldOwner = ParakeetAudioGraphOwnerToken(generation: 45, engine: engine)
        let replacementOwner = ParakeetAudioGraphOwnerToken(generation: 46, engine: engine)
        let pendingState = ParakeetPendingRestoreInterleavingHarness()
        let coordinator = ParakeetSerialSystemInputWorkCoordinator(
            label: "test.parakeet.system-input-interleaving"
        )
        let temporaryInput = "built-in-input"
        let previousInput = "bluetooth-input"
        let route = ParakeetSystemInputRouteTestState(
            route: temporaryInput,
            recoveryMarkerIsSet: true
        )

        await pendingState.replace(previousInput, ownedBy: oldOwner)
        guard let takenRestore = await pendingState.take(ownedBy: oldOwner) else {
            assertTrue(false, "the old owner should take its pending restore before suspension")
            return
        }

        let oldRestoreEntered = ParakeetAsyncInterleavingGate()
        let releaseOldRestore = DispatchSemaphore(value: 0)
        let oldRestore = Task {
            await coordinator.run {
                Task { await oldRestoreEntered.open() }
                _ = releaseOldRestore.wait(timeout: .now() + 2)
                route.restoreIfStillTemporary(
                    temporaryInput: temporaryInput,
                    previousInput: takenRestore
                )
            }
            if !(await pendingState.hasPendingValue()) {
                route.clearRecoveryMarker()
            }
        }

        await oldRestoreEntered.wait()

        await pendingState.replace(previousInput, ownedBy: replacementOwner)
        let replacementStartScheduled = ParakeetAsyncInterleavingGate()
        let replacementSelectionRan = ParakeetAsyncInterleavingGate()
        let replacementStart = Task {
            await replacementStartScheduled.open()
            let selectedFromRoute = await coordinator.run {
                Task { await replacementSelectionRan.open() }
                return route.currentRoute()
            }
            await coordinator.run {
                route.applyReplacementInput(temporaryInput)
            }
            return selectedFromRoute
        }

        await replacementStartScheduled.wait()
        assertFalse(
            await replacementSelectionRan.opened(),
            "replacement route selection must queue behind the already-taken restore"
        )

        releaseOldRestore.signal()
        await oldRestore.value
        let replacementSelection = await replacementStart.value

        assertEqual(
            replacementSelection,
            previousInput,
            "replacement selection should run after the old restore completes"
        )
        assertEqual(
            route.currentRoute(),
            temporaryInput,
            "old restore completion must not leave the replacement on the prior route"
        )
        assertTrue(
            route.recoveryMarkerIsSet(),
            "old restore completion must not clear the replacement owner's recovery marker"
        )
        assertEqual(
            await pendingState.value(ownedBy: replacementOwner),
            previousInput,
            "old completion must leave the replacement owner's pending restore intact"
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
                let coordinator = ParakeetSerialSystemInputWorkCoordinator(
                    label: "test.parakeet.stale-system-input.\(ownershipLoss.rawValue).\(suspensionPoint.rawValue)"
                )
                let route = ParakeetSystemInputRouteTestState(
                    route: "airpods-input",
                    recoveryMarkerIsSet: true
                )
                let overrideEntered = ParakeetAsyncInterleavingGate()
                let releaseOverride = DispatchSemaphore(value: 0)

                let staleSnapshot = Task {
                    await coordinator.run {
                        route.applyReplacementInput("built-in-input")
                        Task { await overrideEntered.open() }
                        _ = releaseOverride.wait(timeout: .now() + 2)
                    }
                    guard oldOwner == successorOwner else {
                        await coordinator.run {
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

    runSuite("ParakeetZombieRecoveryState emits exactly one terminal result per attempt") {
        var state = ParakeetZombieRecoveryState()
        let generation = state.begin(failureKind: "no_sample_callbacks")

        assertTrue(state.advance(to: .reset, generation: generation), "active recovery should advance into reset")
        assertTrue(state.advance(to: .restart, generation: generation), "active recovery should advance into restart")
        let terminal = state.finish(result: .failed, generation: generation)

        assertEqual(terminal?.stage, .restart, "terminal telemetry should preserve the last actionable stage")
        assertEqual(terminal?.result, .failed, "terminal telemetry should preserve the outcome")
        assertEqual(terminal?.failureKind, "no_sample_callbacks", "terminal telemetry should preserve the categorical trigger")
        assertEqual(state.finish(result: .failed, generation: generation), nil, "the same attempt cannot finish twice")
    }

    runSuite("ParakeetZombieRecoveryState cancellation is terminal and rejects stale callbacks") {
        var state = ParakeetZombieRecoveryState()
        let generation = state.begin(failureKind: "silent_hfp_callbacks")
        assertTrue(state.advance(to: .settle, generation: generation), "active recovery should advance into settle")

        let terminal = state.cancelActiveAttempt()

        assertEqual(terminal?.stage, .settle, "cancellation should name the stage it interrupted")
        assertEqual(terminal?.result, .cancelled, "cancellation should have a categorical terminal result")
        assertFalse(state.canContinue(generation: generation), "cancelled work should become stale")
        assertFalse(state.advance(to: .restart, generation: generation), "late callbacks cannot revive a cancelled recovery")
    }

    await runSuite("Parakeet user stop invalidates recovery before a delayed restart") {
        let harness = ParakeetZombieStopInterleavingHarness()
        let resetPublished = ParakeetAsyncInterleavingGate()
        let allowDelayedRestart = ParakeetAsyncInterleavingGate()

        let delayedRecovery = Task {
            let generation = await harness.beginReset()
            await resetPublished.open()
            await allowDelayedRestart.wait()
            return await harness.tryRestart(generation: generation)
        }

        await resetPublished.wait()
        let terminal = await harness.stop()
        await allowDelayedRestart.open()

        assertEqual(terminal?.result, .cancelled, "stop should consume the active recovery attempt")
        assertFalse(
            await delayedRecovery.value,
            "a recovery continuation delayed behind stop must not restart the microphone"
        )
    }

    runSuite("ParakeetZombieRecoveryState keeps one active generation") {
        var state = ParakeetZombieRecoveryState()
        let first = state.begin(failureKind: "no_sample_callbacks")
        let duplicate = state.begin(failureKind: "silent_hfp_callbacks")

        assertEqual(duplicate, first, "a second detector callback must not replace an unfinished recovery attempt")
        assertTrue(state.canContinue(generation: first), "the original attempt should remain active")
    }

    runSuite("ParakeetAudioStartRecoveryPolicy.shouldRetryStartFailure — retries only normal first failures") {
        assertTrue(
            ParakeetAudioStartRecoveryPolicy.shouldRetryStartFailure(isRecoveryAttempt: false, failedAttempts: 1, retryBudget: 1),
            "normal first failure should get one immediate graph-reset retry"
        )
        assertFalse(
            ParakeetAudioStartRecoveryPolicy.shouldRetryStartFailure(isRecoveryAttempt: false, failedAttempts: 2, retryBudget: 1),
            "retry budget should cap repeated immediate attempts"
        )
        assertFalse(
            ParakeetAudioStartRecoveryPolicy.shouldRetryStartFailure(isRecoveryAttempt: true, failedAttempts: 1, retryBudget: 1),
            "recovery attempts should not recursively retry"
        )
    }

    runSuite("ParakeetAudioStartRecoveryPolicy.shouldReportFailure — throttles repeated Sentry reports") {
        assertTrue(
            ParakeetAudioStartRecoveryPolicy.shouldReportFailure(now: 100, lastReportAt: nil, throttle: 15),
            "first failure should report"
        )
        assertFalse(
            ParakeetAudioStartRecoveryPolicy.shouldReportFailure(now: 110, lastReportAt: 100, throttle: 15),
            "repeat failures inside the throttle window should stay local-only"
        )
        assertTrue(
            ParakeetAudioStartRecoveryPolicy.shouldReportFailure(now: 116, lastReportAt: 100, throttle: 15),
            "failures after the throttle window should report again"
        )
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

private actor ParakeetZombieStopInterleavingHarness {
    private var state = ParakeetZombieRecoveryState()

    func beginReset() -> UInt64 {
        let generation = state.begin(failureKind: "no_sample_callbacks")
        _ = state.advance(to: .reset, generation: generation)
        return generation
    }

    func stop() -> ParakeetZombieRecoveryTerminal? {
        state.cancelActiveAttempt()
    }

    func tryRestart(generation: UInt64) -> Bool {
        state.advance(to: .restart, generation: generation)
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

private actor ParakeetAsyncInterleavingGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func opened() -> Bool {
        isOpen
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pendingWaiters = waiters
        waiters.removeAll()
        for waiter in pendingWaiters {
            waiter.resume()
        }
    }
}

private func categoricalRoute(
    input: String,
    output: String,
    shape: String
) -> ParakeetCategoricalAudioRoute {
    ParakeetCategoricalAudioRoute(
        inputDeviceClass: input,
        outputDeviceClass: output,
        routeShape: shape
    )
}
