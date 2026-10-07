// ParakeetRecoveryStateTests.swift
// Device-change recovery, route debounce, zombie lifecycle, and retry policy.
// Audio graph ownership and system-input interleavings live in their own suite.

import Foundation

func testParakeetRecoveryState() async {
    func route(defaultInputID: UInt32, selectedInputID: UInt32) -> ParakeetAudioRouteIdentity {
        func device(_ id: UInt32) -> DictationAudioDevice {
            DictationAudioDevice(id: id, name: "Mic \(id)", transport: .usb,
                                 inputChannelCount: 1, uid: "mic-\(id)")
        }
        return ParakeetAudioRouteIdentity(selection: DictationInputDeviceSelection(
            defaultInput: device(defaultInputID), selectedInput: device(selectedInputID),
            defaultOutput: nil, reason: .defaultIsSafe
        ))
    }
    func ignored(_ source: ParakeetConfigChangeSource, at observedAt: CFAbsoluteTime,
                 until: CFAbsoluteTime = 0,
                 stable: ParakeetAudioRouteIdentity? = nil,
                 observed: ParakeetAudioRouteIdentity? = nil,
                 token: ParakeetAUHALBindingToken? = nil,
                 engine: AnyObject) -> Bool {
        ParakeetSelfInducedConfigChangePolicy.shouldIgnore(
            source: source, observedAt: observedAt,
            ignoreWindowUntil: until, windowDuration: 2.5,
            stableRoute: stable, observedRoute: observed,
            bindingToken: token, currentEngine: engine,
            forceForMicrophoneSharing: false
        )
    }
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

    runSuite("ParakeetRecoveryState.deferUntilNextUse — idle changes invalidate recovery without rebuilding") {
        var state = ParakeetRecoveryState()
        let staleGeneration = state.beginConfigChange()

        state.deferUntilNextUse()

        assertFalse(state.isRecovering, "idle route changes should not leave background recovery active")
        assertFalse(state.inputFormatReady, "the next explicit dictation should validate the new route")
        assertTrue(state.isStale(generation: staleGeneration), "idle deferral must supersede stale recovery work")
    }

    runSuite("ParakeetInputDeviceRefreshMailbox — a notification storm admits one worker and one pending request") {
        let mailbox = ParakeetInputDeviceRefreshMailbox()
        let countLock = NSLock()
        var scheduledWorkers = 0

        DispatchQueue.concurrentPerform(iterations: 100_000) { index in
            let source: ParakeetConfigChangeSource = index.isMultiple(of: 2)
                ? .audioEngine
                : .defaultInputDevice
            if mailbox.submit(configChangeSource: source) {
                countLock.withLock {
                    scheduledWorkers += 1
                }
            }
        }

        assertEqual(scheduledWorkers, 1, "100,000 callbacks should schedule exactly one HAL lookup worker")
        assertTrue(mailbox.takeNext() != nil, "the worker should receive one collapsed latest request")
        assertTrue(mailbox.takeNext() == nil, "the mailbox should be empty after one collapsed request")
        assertTrue(mailbox.submit(), "a fully drained mailbox should admit one future worker")
        mailbox.close()
        assertFalse(mailbox.submit(), "shutdown should permanently reject new callback work")
    }

    runSuite("Config refresh mailbox retains matching callback arrival through display-only coalescing") {
        let mailbox = ParakeetInputDeviceRefreshMailbox()
        let engine = NSObject()
        let intent = ParakeetAUHALBindingIntent()
        let token = intent.begin(engine: engine, route: route(defaultInputID: 1, selectedInputID: 1), at: 100)
        assertTrue(mailbox.submit(configChangeSource: .audioEngine, observedAt: 100.1,
                                  bindingToken: token), "first source schedules one worker")
        assertFalse(mailbox.submit(), "display-only refresh must share existing worker")
        let first = mailbox.takeNext()
        assertTrue(first?.configChangeSource == .audioEngine, "display refresh must keep source")
        assertTrue(first?.observedAt == 100.1, "display refresh must not age source arrival")
        assertTrue(first?.bindingToken === token, "display refresh must not replace binding ownership")
        assertFalse(mailbox.submit(configChangeSource: .defaultInputDevice, observedAt: 103.1),
                    "later source reuses worker")
        let second = mailbox.takeNext()
        assertTrue(second?.configChangeSource == .defaultInputDevice, "latest config source wins")
        assertTrue(second?.observedAt == 103.1, "latest config source owns its timestamp")
        assertTrue(second?.bindingToken == nil, "later default event cannot borrow setter token")
        assertTrue(mailbox.takeNext() == nil, "one worker drains both requests")
    }

    runSuite("AUHAL callback inside setter is suppressed only after successful command, even if HAL lookup is delayed") {
        let engine = NSObject()
        let intent = ParakeetAUHALBindingIntent()
        let selected = route(defaultInputID: 1, selectedInputID: 1)
        let token = intent.begin(engine: engine, route: selected, at: 100)
        let callbackToken = intent.tokenForNotification(engineID: ObjectIdentifier(engine), at: 100.1, window: 2.5)
        assertTrue(callbackToken === token, "callback can capture in-flight setter before confirmation")
        assertFalse(ignored(.audioEngine, at: 100.1, observed: selected,
                            token: callbackToken, engine: engine), "pending setter is not proven")
        token.finish(succeeded: true)
        assertTrue(ignored(.audioEngine, at: 100.1, observed: selected,
                           token: callbackToken, engine: engine),
                   "late delivery at 104 seconds uses callback arrival, not lookup completion")
        assertFalse(ignored(.audioEngine, at: 102.6, observed: selected,
                            token: callbackToken, engine: engine), "post-window notification must recover")
        assertFalse(ignored(.audioEngine, at: 100.1,
                            observed: route(defaultInputID: 2, selectedInputID: 2),
                            token: callbackToken, engine: engine), "physical route mismatch must recover")
        assertFalse(ignored(.audioEngine, at: 100.1, observed: nil,
                            token: callbackToken, engine: engine), "unknown HAL route must recover")
        assertFalse(ignored(.audioEngine, at: 100.1, observed: selected,
                            token: callbackToken, engine: NSObject()), "retired graph cannot mask replacement")
    }

    // True if the task completes before a generous give-up margin. The margin
    // only keeps a broken wake-up from hanging the suite; it is not a speed limit.
    func finishes(_ task: Task<Void, Never>) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await task.value; return true }
            group.addTask { try? await Task.sleep(nanoseconds: 30_000_000_000); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    await runSuite("In-flight AUHAL setter awaits bounded confirmation without blocking notification delivery") {
        let engine = NSObject()
        let selected = route(defaultInputID: 1, selectedInputID: 1)
        let token = ParakeetAUHALBindingIntent().begin(engine: engine, route: selected, at: 100)
        // The native timeout is an hour so only finish() can wake the handler;
        // the outcome check below uses a wide give-up margin, not a time limit.
        let handler = Task { await token.waitForResolution(nativeTimeoutNanoseconds: 3_600_000_000_000) }
        try? await Task.sleep(nanoseconds: 40_000_000)
        assertFalse(token.wasConfirmed, "callback/route lookup can reach handler before setter returns")
        token.finish(succeeded: true)
        let wokeByFinish = await finishes(handler)
        assertTrue(wokeByFinish, "successful setter wakes handler before the native timeout (an hour here)")
        assertTrue(ignored(.audioEngine, at: 100.1, observed: selected,
                           token: token, engine: engine), "resolved in-flight echo may be suppressed")

        let failed = ParakeetAUHALBindingIntent().begin(engine: engine, route: selected, at: 101)
        let failedHandler = Task { await failed.waitForResolution(nativeTimeoutNanoseconds: 250_000_000) }
        try? await Task.sleep(nanoseconds: 20_000_000)
        failed.finish(succeeded: false)
        await failedHandler.value
        assertFalse(ignored(.audioEngine, at: 101.1, observed: selected,
                            token: failed, engine: engine), "failed setter must recover")

        let hung = ParakeetAUHALBindingIntent().begin(engine: engine, route: selected, at: 102)
        let hungHandler = Task { await hung.waitForResolution(nativeTimeoutNanoseconds: 50_000_000) }
        let releasedByTimeout = await finishes(hungHandler)
        assertTrue(releasedByTimeout, "wedged setter must release notification handler once the native timeout fires")
        assertFalse(ignored(.audioEngine, at: 102.1, observed: selected,
                            token: hung, engine: engine), "timed-out setter remains unproven")
        hung.finish(succeeded: true)
        assertFalse(ignored(.audioEngine, at: 102.1, observed: selected,
                            token: hung, engine: engine), "late native completion cannot revive expired echo")
    }

    runSuite("Failed or superseded AUHAL setter cannot borrow later binding confirmation") {
        let engine = NSObject()
        let intent = ParakeetAUHALBindingIntent()
        let selected = route(defaultInputID: 1, selectedInputID: 1)
        let first = intent.begin(engine: engine, route: selected, at: 100)
        let firstCallback = intent.tokenForNotification(engineID: ObjectIdentifier(engine), at: 100.1, window: 2.5)
        first.finish(succeeded: false)
        let second = intent.begin(engine: engine, route: selected, at: 101)
        second.finish(succeeded: true)
        assertFalse(ignored(.audioEngine, at: 100.1, until: 102.5, stable: selected, observed: selected,
                            token: firstCallback, engine: engine), "failed A remains unproven after successful B")
        assertTrue(ignored(.audioEngine, at: 101.1, observed: selected,
                           token: second, engine: engine), "B owns its own confirmed echo")
    }

    runSuite("Generic ignore window uses callback arrival and never masks changed audio graph route") {
        let engine = NSObject()
        let stable = route(defaultInputID: 1, selectedInputID: 1)
        assertTrue(ignored(.audioEngine, at: 100.1, until: 102.5,
                           stable: stable, observed: stable, engine: engine),
                   "unchanged graph echo arriving in window remains suppressed after delayed lookup")
        assertFalse(ignored(.audioEngine, at: 102.6, until: 102.5,
                            stable: stable, observed: stable, engine: engine),
                    "actual post-window callback is not suppressed")
        assertFalse(ignored(.audioEngine, at: 100.1, until: 102.5,
                            stable: stable, observed: route(defaultInputID: 2, selectedInputID: 2),
                            engine: engine), "disconnect inside window must make input unready")
        assertFalse(ignored(.audioEngine, at: 100.1, until: 102.5,
                            stable: stable, observed: nil, engine: engine), "unknown route cannot prove echo")
        assertTrue(ignored(.defaultInputDevice, at: 100.1, until: 102.5,
                           stable: stable, observed: stable, engine: engine),
                   "deliberate system-input restore keeps its short existing window")
        assertFalse(ignored(.defaultInputDevice, at: 102.6, until: 102.5,
                            stable: stable, observed: stable, engine: engine),
                    "post-window external default change must recover")
    }

    runSuite("Route callback arrival is stamped once, owns the setter token, and survives the mailbox") {
        let engine = NSObject()
        let selected = route(defaultInputID: 1, selectedInputID: 2)
        let intent = ParakeetAUHALBindingIntent()
        let first = intent.begin(engine: engine, route: selected, at: 100)
        var clockReads = 0
        let arrival = ParakeetConfigChangeArrival.stamp(
            engineID: ObjectIdentifier(engine), bindingIntent: intent, window: 2.5,
            now: { clockReads += 1; return 100.4 }
        )
        assertEqual(arrival.observedAt, 100.4, "arrival keeps the callback clock value")
        assertEqual(clockReads, 1, "arrival reads the clock exactly once")
        assertTrue(arrival.bindingToken === first, "arrival owns the setter command current at that moment")

        let second = intent.begin(engine: engine, route: selected, at: 101)
        assertTrue(arrival.bindingToken !== second, "a later setter does not take over an earlier callback")

        let late = ParakeetConfigChangeArrival.stamp(
            engineID: ObjectIdentifier(engine), bindingIntent: intent, window: 2.5, now: { 104 }
        )
        assertTrue(late.bindingToken == nil, "a callback past the setter window owns no token")
        let otherEngine = ParakeetConfigChangeArrival.stamp(
            engineID: ObjectIdentifier(NSObject()), bindingIntent: intent, window: 2.5, now: { 101.2 }
        )
        assertTrue(otherEngine.bindingToken == nil, "another engine's callback owns no token")

        let mailbox = ParakeetInputDeviceRefreshMailbox()
        _ = mailbox.submit(configChangeSource: .audioEngine, observedAt: arrival.observedAt,
                           bindingToken: arrival.bindingToken)
        let drained = mailbox.takeNext()
        assertEqual(drained?.observedAt, 100.4, "the drained request carries arrival time, not drain time")
        assertTrue(drained?.bindingToken === first, "the drained request carries the arrival token")
    }

    await runSuite("Config-change admission classifies arrival time and waits only on the setter it owns") {
        let engine = NSObject()
        let stable = route(defaultInputID: 1, selectedInputID: 1)
        let selected = route(defaultInputID: 1, selectedInputID: 2)
        func request(_ source: ParakeetConfigChangeSource, at observedAt: CFAbsoluteTime,
                     token: ParakeetAUHALBindingToken? = nil, force: Bool = false,
                     until: CFAbsoluteTime = 0) -> ParakeetConfigChangeAdmissionRequest {
            ParakeetConfigChangeAdmissionRequest(source: source, observedAt: observedAt, bindingToken: token,
                                                 forceForMicrophoneSharing: force, ignoreWindowUntil: until)
        }
        @MainActor func decide(_ request: ParakeetConfigChangeAdmissionRequest,
                               observed: ParakeetAudioRouteIdentity?,
                               admitted: Bool = true,
                               onWait: @MainActor (ParakeetAUHALBindingToken) -> Void = { _ in },
                               policy: ParakeetConfigChangeAdmission.ShouldIgnore? = nil) async
            -> (ParakeetConfigChangeAdmission.Decision, Int) {
            var waits = 0
            let decision = await ParakeetConfigChangeAdmission.decide(
                request, observedRoute: observed, stableRoute: stable, windowDuration: 2.5,
                currentEngine: { engine },
                waitForResolution: { token in waits += 1; onWait(token) },
                stillAdmitted: { admitted },
                shouldIgnore: policy ?? ParakeetConfigChangeAdmission.eventTimePolicy
            )
            return (decision, waits)
        }

        var seen: (observedAt: CFAbsoluteTime, until: CFAbsoluteTime)?
        let (_, noTokenWaits) = await decide(
            request(.audioEngine, at: 100.1, until: 102.5), observed: stable,
            policy: { _, observedAt, until, _, _, _, _, _, _ in seen = (observedAt, until); return false }
        )
        assertEqual(seen?.observedAt, 100.1, "policy classifies the callback's arrival time")
        assertEqual(seen?.until, 102.5, "policy keeps the bounded restore window")
        assertEqual(noTokenWaits, 0, "no setter token means no wait")

        let intent = ParakeetAUHALBindingIntent()
        let pending = intent.begin(engine: engine, route: selected, at: 100)
        let (echo, echoWaits) = await decide(
            request(.audioEngine, at: 100.2, token: pending), observed: selected,
            onWait: { $0.finish(succeeded: true) }
        )
        assertEqual(echoWaits, 1, "a callback that arrived mid-write waits on its setter")
        assertEqual(echo, .ignoreSelfInduced, "a confirmed setter echo on its own route is ignored")

        let failing = intent.begin(engine: engine, route: selected, at: 100)
        let (failed, _) = await decide(
            request(.audioEngine, at: 100.2, token: failing, until: 102.5), observed: selected,
            onWait: { $0.finish(succeeded: false) }
        )
        assertEqual(failed, .recover, "a failed setter cannot hide behind the generic window")

        let lost = intent.begin(engine: engine, route: selected, at: 100)
        let (superseded, _) = await decide(
            request(.audioEngine, at: 100.2, token: lost), observed: selected, admitted: false,
            onWait: { $0.finish(succeeded: true) }
        )
        assertEqual(superseded, .superseded, "lifecycle change during the wait drops the callback")

        let foreign = ParakeetAUHALBindingToken(engine: NSObject(), route: selected, issuedAt: 100)
        let (_, foreignWaits) = await decide(request(.audioEngine, at: 100.2, token: foreign), observed: selected)
        assertEqual(foreignWaits, 0, "a token from a retired engine is never waited on")

        let defaultToken = intent.begin(engine: engine, route: selected, at: 100)
        let (_, defaultWaits) = await decide(request(.defaultInputDevice, at: 100.2, token: defaultToken),
                                             observed: selected)
        assertEqual(defaultWaits, 0, "default-input callbacks never wait on AUHAL setters")

        let (inWindow, _) = await decide(request(.audioEngine, at: 100.1, until: 102.5), observed: stable)
        assertEqual(inWindow, .ignoreSelfInduced, "an unchanged echo inside the restore window is ignored")
        let (forced, _) = await decide(request(.audioEngine, at: 100.1, force: true, until: 102.5),
                                       observed: stable)
        assertEqual(forced, .recover, "a call-app downgrade forces recovery through the restore window")
        let confirmed = intent.begin(engine: engine, route: selected, at: 100)
        confirmed.finish(succeeded: true)
        let (forcedEcho, _) = await decide(request(.audioEngine, at: 100.2, token: confirmed, force: true),
                                           observed: selected)
        assertEqual(forcedEcho, .recover, "a call-app downgrade is not postponed by our own setter echo")
    }

    runSuite("Native AUHAL setter owns its echo while writing and settles on return") {
        struct WriteFailed: Error {}
        let engine = NSObject()
        let selected = route(defaultInputID: 1, selectedInputID: 2)
        let intent = ParakeetAUHALBindingIntent()
        var midWrite: ParakeetAUHALBindingToken?
        ParakeetInputBindingWrite.perform(intent: intent, engine: engine, route: selected, now: { 100 }) {
            midWrite = intent.tokenForNotification(engineID: ObjectIdentifier(engine), at: 100.1, window: 2.5)
        }
        assertTrue(midWrite != nil, "a callback during the write is owned by this setter")
        assertEqual(midWrite?.route, selected, "the setter intent names the route it writes")
        assertTrue(midWrite?.wasConfirmed == true, "a successful write confirms its echo")

        var failedToken: ParakeetAUHALBindingToken?
        var rethrown = false
        do {
            try ParakeetInputBindingWrite.perform(intent: intent, engine: engine, route: selected, now: { 101 }) {
                failedToken = intent.tokenForNotification(engineID: ObjectIdentifier(engine), at: 101.1, window: 2.5)
                throw WriteFailed()
            }
        } catch is WriteFailed {
            rethrown = true
        } catch {}
        assertTrue(rethrown, "the write's error reaches the caller")
        assertTrue(failedToken != nil, "a failing write still owns callbacks during the write")
        assertTrue(failedToken !== midWrite, "each write issues its own intent")
        assertTrue(failedToken?.wasConfirmed == false, "a failed write never confirms its echo")
        assertFalse(ignored(.audioEngine, at: 101.1, until: 103.5, observed: selected,
                            token: failedToken, engine: engine),
                    "a failed write's callback is not suppressed")
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

    runSuite("ParakeetRecoveryState.cancelRecovery — stop cancels only its matching recovery") {
        var state = ParakeetRecoveryState()
        let recoveryGeneration = state.beginConfigChange()

        assertTrue(
            state.cancelRecovery(generation: recoveryGeneration),
            "the stop that observed the current recovery should consume it"
        )
        assertTrue(state.canStartRecording, "cancelling recovery should unblock the next recording start")
        assertTrue(
            state.isStale(generation: recoveryGeneration),
            "the suspended cleanup must become stale before it can resume"
        )
    }

    runSuite("ParakeetRecoveryState.cancelRecovery — stale cleanup preserves a successor owner") {
        var state = ParakeetRecoveryState()
        let staleGeneration = state.beginConfigChange()
        let successorGeneration = state.beginConfigChange()

        assertFalse(
            state.cancelRecovery(generation: staleGeneration),
            "a cleanup from the retired generation must not cancel its successor"
        )
        assertTrue(state.isRecovering, "the successor recovery should remain active")
        assertFalse(state.canStartRecording, "the successor must still gate recording starts")
        assertTrue(
            state.finishRecovery(success: true, generation: successorGeneration),
            "the successor should retain the right to finish"
        )
    }

    runSuite("ParakeetRecoveryState.cancelRecovery — late timeout cannot poison a cancelled stop") {
        var state = ParakeetRecoveryState()
        let recoveryGeneration = state.beginConfigChange()

        assertTrue(state.cancelRecovery(generation: recoveryGeneration), "matching stop should cancel recovery")
        assertFalse(
            state.timeoutRecovery(generation: recoveryGeneration),
            "the old timeout must not make the next start unready"
        )
        assertTrue(state.canStartRecording, "a cancelled timeout should leave the next start available")
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
