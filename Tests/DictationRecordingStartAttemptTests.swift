import Foundation

@MainActor
func testDictationRecordingStartAttempt() async {
    await runSuite("Healthy microphone bypasses activation and its failure window") {
        var events: [String] = []
        let started = await DictationRecordingStartAttempt.run(
            start: { events.append("native_start"); return true },
            onFailure: { events.append("activation"); events.append("500ms_wait") }
        )
        assertTrue(started, "healthy capture succeeds without requiring app activation")
        assertEqual(events, ["native_start"], "no new activation or wait can precede a successful ordinary start")
    }

    await runSuite("A failed microphone start gets recovery before the next attempt") {
        var events: [String] = []
        var nativeResults = [false, true]
        let start: () async -> Bool = {
            let result = nativeResults.removeFirst()
            events.append(result ? "native_success" : "native_failure")
            return result
        }
        let recover: () async -> Void = { events.append("recover") }
        let first = await DictationRecordingStartAttempt.run(start: start, onFailure: recover)
        let retry = await DictationRecordingStartAttempt.run(start: start, onFailure: recover)
        assertFalse(first, "preparing recovery must not manufacture recording success")
        assertTrue(retry, "only actual native success admits recording")
        assertEqual(events, ["native_failure", "recover", "native_success"], "native failure is required before activation recovery")
    }

    await runSuite("Unsuccessful recovery does not become a false successful recording") {
        var recoveries = 0
        let started = await DictationRecordingStartAttempt.run(
            start: { false }, onFailure: { recoveries += 1 }
        )
        assertFalse(started, "caller retains ownership of bounded retry/timeout policy")
        assertEqual(recoveries, 1, "one failure notification per completed failed attempt")
    }

    await runSuite("Release while native start is pending cannot activate on late failure") {
        var recovered = false
        let task = Task { @MainActor in
            await DictationRecordingStartAttempt.run(
                start: {
                    withUnsafeCurrentTask { $0?.cancel() }
                    return false // native work may finish after cancellation
                },
                onFailure: { recovered = true }
            )
        }
        let started = await task.value
        assertFalse(started, "cancelled failure stays failed")
        assertFalse(recovered, "late native failure cannot activate after release")
    }

    await runSuite("Late native success is returned so the cancelled caller can stop it") {
        var recovered = false
        let task = Task { @MainActor in
            await DictationRecordingStartAttempt.run(
                start: {
                    withUnsafeCurrentTask { $0?.cancel() }
                    return true
                },
                onFailure: { recovered = true }
            )
        }
        let started = await task.value
        assertTrue(started, "do not hide a real recording that cancellation cleanup must stop")
        assertFalse(recovered, "a success must never invoke focus recovery")
    }

    await runSuite("Cancelled queued attempt neither opens mic nor changes focus") {
        var events: [String] = []
        let task = Task { @MainActor in
            await DictationRecordingStartAttempt.run(
                start: { events.append("mic"); return true },
                onFailure: { events.append("activate") }
            )
        }
        task.cancel()
        let started = await task.value
        assertFalse(started, "cancelled queued work stays cancelled")
        assertTrue(events.isEmpty, "neither native work nor activation is admitted")
    }

    await runSuite("Existing callers without focus recovery preserve native failure") {
        let started = await DictationRecordingStartAttempt.run(start: { false })
        assertFalse(started, "optional recovery cannot change existing start-result semantics")
    }

    runSuite("Both production start paths use failure-only recovery") {
        do {
            let speech = try String(contentsOf: repoFixtureURL("Sources/Speech/DictationSession.swift"), encoding: .utf8)
            assertTrue(speech.contains("return await DictationRecordingStartAttempt.run("), "native microphone starts execute the tested production runner")
            assertTrue(speech.contains("onFailure: onStartFailed"), "native failure is the sole recovery trigger")
            let controller = try String(contentsOf: repoFixtureURL("Sources/UI/Overlay/DictationSessionController.swift"), encoding: .utf8)
            let begin = controller.components(separatedBy: "private func beginDictationRecording(sourceApp: NSRunningApplication?) {").last ?? ""
            let body = begin.components(separatedBy: "private func waitForEngineAndStart(").first ?? ""
            assertFalse(body.contains("startActivation.prepare"), "normal entrypoint must not activate before trying the mic")
            assertFalse(controller.contains("activationPrepared"), "remove the old unconditional activation recursion")
            assertTrue(controller.contains("!didAttemptStartActivation"), "recovery is admitted at most once per session")
            assertTrue(controller.contains("didAttemptStartActivation = false"), "each new session gets a fresh recovery opportunity")
            assertEqual(controller.components(separatedBy: "await self?.recoverBackgroundHotkeyStart(sessionID: sessionID)").count - 1, 2, "fast starts and readiness-loop failures share the guarded recovery")
        } catch {
            assertTrue(false, "production wiring should be readable: \(error)")
        }
    }
}
