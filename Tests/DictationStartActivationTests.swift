import Foundation

@MainActor
func testDictationStartActivation() async {
    await runSuite("Foreground-sensitive mic reproduces menu versus hotkey readiness") {
        // Model the report's environment constraint, not a claim to emulate
        // Falcon or reproduce its behavior on the local machine.
        let hotkey = ActivationMicFixture()
        assertFalse(hotkey.startMic(), "1.1.60 background path has no activation handshake")
        let menu = ActivationMicFixture()
        menu.activate()
        try? await menu.wait()
        menu.restore()
        assertTrue(menu.startMic(), "menu visits foreground and restores the editor before start")

        let prepared = await hotkey.prepare(using: DictationStartActivation())
        assertTrue(prepared, "hotkey activation preparation should complete")
        assertTrue(hotkey.startMic(), "same foreground-sensitive mic now starts through hotkey")
        assertEqual(hotkey.events, ["activate", "active", "restore", "mic"], "activation must complete before mic access, with editor focus restored")
        assertEqual(hotkey.frontmost, "editor", "paste target stays the editor")
        assertEqual(hotkey.waits, 1, "do not spend the entire timeout once active")
    }

    await runSuite("Release before delayed activation restores late focus without recording") {
        let fixture = ActivationMicFixture()
        let activation = DictationStartActivation()
        fixture.acceptActivation = false
        fixture.afterWait = {
            if fixture.waits == 1 {
                fixture.current = false
                activation.cancel()
                fixture.acceptActivation = true
            }
        }
        let ready = await fixture.prepare(using: activation)
        if ready { _ = fixture.startMic() }
        assertFalse(ready, "cancelled start cannot record after delayed OS activation")
        assertEqual(fixture.events, ["activate", "active", "restore"], "retain cleanup ownership until pending activation completes")
        assertEqual(fixture.frontmost, "editor", "late activation cannot strand focus in Transcripted")
    }

    await runSuite("A newer prepare owns focus instead of an older suspended prepare") {
        let fixture = ActivationMicFixture()
        let activation = DictationStartActivation()
        let ready = await activation.prepare(
            isCurrent: { true },
            isActive: { fixture.frontmost == "transcripted" },
            activate: { fixture.activate() },
            restore: { fixture.restore() },
            now: { fixture.time },
            wait: {
                fixture.frontmost = "new-session"
                _ = await activation.prepare(
                    isCurrent: { true },
                    isActive: { true },
                    activate: {},
                    restore: {}
                )
            }
        )
        assertFalse(ready, "a superseded prepare cannot admit its old recording")
        assertEqual(fixture.frontmost, "new-session", "old cleanup cannot restore over newer ownership")
    }

    await runSuite("An already active app does not activate or restore focus") {
        let fixture = ActivationMicFixture()
        fixture.frontmost = "transcripted"
        let ready = await fixture.prepare(using: DictationStartActivation())
        assertTrue(ready, "already-active start proceeds")
        assertTrue(fixture.events.isEmpty, "no focus churn or sleep on foreground path")
    }

    await runSuite("Activation refusal is bounded and leaves mic recovery available") {
        let fixture = ActivationMicFixture()
        fixture.acceptActivation = false
        let ready = await fixture.prepare(using: DictationStartActivation())
        assertTrue(ready, "activation timeout must not replace existing audio readiness recovery")
        assertTrue(fixture.time >= 0.5 && fixture.time < 0.6, "activation has a bounded half-second budget")
        assertEqual(fixture.events, ["activate"], "do not restore when another app owns focus")
    }

    await runSuite("Push-to-talk release during activation prevents capture") {
        let fixture = ActivationMicFixture()
        let activation = DictationStartActivation()
        fixture.afterWait = {
            fixture.current = false
            activation.cancel()
        }
        let ready = await fixture.prepare(using: activation)
        if ready { _ = fixture.startMic() }
        assertFalse(ready, "released/cancelled session cannot proceed")
        assertFalse(fixture.events.contains("mic"), "never record after release")
        assertEqual(fixture.frontmost, "editor", "cancellation restores the editor")
        assertEqual(fixture.events.filter { $0 == "restore" }.count, 1, "restore only once")
    }

    await runSuite("User switching apps during activation keeps their chosen focus") {
        let fixture = ActivationMicFixture()
        fixture.acceptActivation = false
        fixture.afterWait = {
            fixture.frontmost = "third-app"
            fixture.current = false
        }
        let ready = await fixture.prepare(using: DictationStartActivation())
        assertFalse(ready, "ended session stays ended")
        assertEqual(fixture.frontmost, "third-app", "cleanup cannot steal focus from another app")
        assertFalse(fixture.events.contains("restore"), "no source reactivation after a user focus change")
    }

    await runSuite("A current session leaves a user-selected third app focused") {
        let fixture = ActivationMicFixture()
        fixture.acceptActivation = false
        fixture.afterWait = { fixture.frontmost = "third-app" }
        let ready = await fixture.prepare(using: DictationStartActivation())
        assertTrue(ready, "existing mic readiness recovery remains available")
        assertEqual(fixture.frontmost, "third-app", "a still-current session cannot steal user focus")
        assertFalse(fixture.events.contains("restore"), "only restore while Transcripted is active")
    }

    await runSuite("Cancelled task never starts or activates") {
        let fixture = ActivationMicFixture()
        let task = Task { @MainActor in
            await fixture.prepare(using: DictationStartActivation())
        }
        task.cancel()
        let ready = await task.value
        assertFalse(ready, "cancelled queued start must abort")
        assertTrue(fixture.events.isEmpty, "cancelled task cannot change focus")
    }

    await runSuite("Superseded activation cannot restore over a newer session") {
        let fixture = ActivationMicFixture()
        let activation = DictationStartActivation()
        fixture.afterWait = {
            activation.cancel()
            fixture.frontmost = "new-session"
        }
        let ready = await fixture.prepare(using: activation)
        assertFalse(ready, "old generation is invalid even if session still reports current")
        assertEqual(fixture.frontmost, "new-session", "old defer cannot restore over new ownership")
    }

    runSuite("Production hotkey preparation preserves capture and cancellation ordering") {
        do {
            let source = try String(contentsOf: repoFixtureURL("Sources/UI/Overlay/DictationSessionController.swift"), encoding: .utf8)
            let capture = source.range(of: "sessionPasteTarget = DictationPasteTarget.capture(sourceApp: sourceApp)")!
            let prepare = source.range(of: "await self.startActivation.prepare(")!
            assertTrue(capture.lowerBound < prepare.lowerBound, "save editor target before changing focus")
            assertTrue(source.contains("if !activationPrepared, !canUseMeetingMic, !NSApp.isActive,"), "meeting mic and active app bypass preparation")
            assertTrue(source.contains("currentDictationTrigger == .physicalKey || currentDictationTrigger == .keyboardShortcut || currentDictationTrigger == .rightOptionTap"), "only hotkey starts need the menu activation handshake")
            assertTrue(source.contains("self.currentDictationSessionID == sessionID"), "resumed startup checks session identity")
            assertTrue(source.contains("private func cancelActiveTasks(cancelRecording: Bool) {\n        startActivation.cancel()"), "cancellation restores focus synchronously")
            let captureSource = try String(contentsOf: repoFixtureURL("Sources/Capture/ContextCaptureEngine.swift"), encoding: .utf8)
            assertTrue(captureSource.contains("session.stopDictationAndPaste(trigger: .physicalKey)"), "push-to-talk release still stops instead of waiting to record")
        } catch {
            assertTrue(false, "production wiring should be readable: \(error)")
        }
    }
}

@MainActor
private final class ActivationMicFixture {
    var frontmost = "editor"
    var current = true
    var acceptActivation = true
    var activated = false
    var events: [String] = []
    var time: TimeInterval = 0
    var waits = 0
    var afterWait: (() -> Void)?

    func activate() { events.append("activate") }
    func wait() async throws {
        waits += 1
        time += 0.1
        if acceptActivation, !activated {
            frontmost = "transcripted"
            activated = true
            events.append("active")
        }
        afterWait?()
    }
    func restore() {
        frontmost = "editor"
        events.append("restore")
    }
    func startMic() -> Bool {
        guard activated else { return false }
        events.append("mic")
        return true
    }
    func prepare(using activation: DictationStartActivation) async -> Bool {
        await activation.prepare(
            isCurrent: { self.current },
            isActive: { self.frontmost == "transcripted" },
            activate: { self.activate() },
            restore: { self.restore() },
            now: { self.time },
            wait: { try await self.wait() }
        )
    }
}
