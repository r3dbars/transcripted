// WakeRecoveryCoordinatorTests.swift
// Async reliability tests for wake coalescing and hotkey recovery.

import Foundation

@MainActor
private final class HotkeyScript {
    private var scriptedErrors: [String?]
    private(set) var registerCalls = 0
    private(set) var unregisterCalls = 0
    private(set) var currentError: String?

    init(scriptedErrors: [String?]) {
        self.scriptedErrors = scriptedErrors
        self.currentError = scriptedErrors.first ?? nil
    }

    func unregister() {
        unregisterCalls += 1
    }

    func register() {
        registerCalls += 1
        if !scriptedErrors.isEmpty {
            currentError = scriptedErrors.removeFirst()
        }
    }
}

@MainActor
private final class CountBox {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

private actor AsyncSignal {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }

        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }
}

func testWakeRecoveryCoordinator() async {
    await runSuite("WakeRecoveryCoordinator.handleSystemWake — coalesces concurrent wake requests") {
        let hotkeys = await MainActor.run { HotkeyScript(scriptedErrors: [nil]) }
        let readinessCalls = await MainActor.run { CountBox() }
        let readinessStarted = AsyncSignal()
        let readinessContinue = AsyncSignal()

        let coordinator = await MainActor.run {
            WakeRecoveryCoordinator(
                hotkeyRetryAttempts: 3,
                hotkeyRetryDelay: 1,
                unregisterHotkeys: { hotkeys.unregister() },
                registerHotkeys: { hotkeys.register() },
                currentHotkeyError: { hotkeys.currentError },
                waitForRuntimeReadiness: {
                    await MainActor.run { readinessCalls.increment() }
                    await readinessStarted.open()
                    await readinessContinue.wait()
                }
            )
        }

        let first = Task { await coordinator.handleSystemWake() }
        await readinessStarted.wait()
        let second = Task { await coordinator.handleSystemWake() }
        await readinessContinue.open()

        let firstResult = await first.value
        let secondResult = await second.value

        assertTrue(firstResult.hotkeysRecovered, "first wake should recover hotkeys")
        assertTrue(firstResult.performedRecovery, "first wake should own the recovery task")
        assertTrue(secondResult.hotkeysRecovered, "joined wake should observe successful recovery")
        assertFalse(secondResult.performedRecovery, "joined wake should reuse the in-flight task")
        let registerCalls = await MainActor.run { hotkeys.registerCalls }
        let readinessCount = await MainActor.run { readinessCalls.count }
        assertEqual(registerCalls, 1, "concurrent wakes should register hotkeys once")
        assertEqual(readinessCount, 1, "concurrent wakes should wait on one readiness task")
    }

    await runSuite("WakeRecoveryCoordinator.handleSystemWake — retries hotkeys until success") {
        let hotkeys = await MainActor.run { HotkeyScript(scriptedErrors: ["busy", "busy", nil]) }
        let sleepCalls = await MainActor.run { CountBox() }

        let coordinator = await MainActor.run {
            WakeRecoveryCoordinator(
                hotkeyRetryAttempts: 3,
                hotkeyRetryDelay: 10,
                unregisterHotkeys: { hotkeys.unregister() },
                registerHotkeys: { hotkeys.register() },
                currentHotkeyError: { hotkeys.currentError },
                waitForRuntimeReadiness: {},
                sleep: { _ in
                    await MainActor.run { sleepCalls.increment() }
                }
            )
        }

        let result = await coordinator.handleSystemWake()

        assertTrue(result.hotkeysRecovered, "third retry should recover hotkeys")
        assertTrue(result.performedRecovery, "single wake should perform recovery itself")
        let registerCalls = await MainActor.run { hotkeys.registerCalls }
        let unregisterCalls = await MainActor.run { hotkeys.unregisterCalls }
        let sleepCount = await MainActor.run { sleepCalls.count }
        assertEqual(registerCalls, 3, "hotkey registration should retry until success")
        assertEqual(unregisterCalls, 3, "hotkey unregister should run for every retry attempt")
        assertEqual(sleepCount, 2, "only failed attempts before the last retry should sleep")
    }

    await runSuite("WakeRecoveryCoordinator.handleSystemWake — waits for runtime readiness before completing") {
        let hotkeys = await MainActor.run { HotkeyScript(scriptedErrors: [nil]) }
        let readinessStarted = AsyncSignal()
        let readinessContinue = AsyncSignal()
        let completionFlag = await MainActor.run { CountBox() }

        let coordinator = await MainActor.run {
            WakeRecoveryCoordinator(
                hotkeyRetryAttempts: 3,
                hotkeyRetryDelay: 1,
                unregisterHotkeys: { hotkeys.unregister() },
                registerHotkeys: { hotkeys.register() },
                currentHotkeyError: { hotkeys.currentError },
                waitForRuntimeReadiness: {
                    await readinessStarted.open()
                    await readinessContinue.wait()
                }
            )
        }

        let task = Task {
            let result = await coordinator.handleSystemWake()
            await MainActor.run { completionFlag.increment() }
            return result
        }

        await readinessStarted.wait()
        try? await Task.sleep(nanoseconds: 50_000_000)

        let completedBeforeReadiness = await MainActor.run { completionFlag.count }
        assertEqual(completedBeforeReadiness, 0, "wake recovery should stay pending until readiness finishes")

        await readinessContinue.open()
        let result = await task.value

        assertTrue(result.hotkeysRecovered, "wake recovery should succeed once readiness finishes")
        let completedAfterReadiness = await MainActor.run { completionFlag.count }
        assertEqual(completedAfterReadiness, 1, "wake recovery should finish after readiness resumes")
    }

    await runSuite("WakeRecoveryCoordinator.handleSystemWake — reuses an immediately completed recovery") {
        let hotkeys = await MainActor.run { HotkeyScript(scriptedErrors: ["busy", nil]) }
        let readinessCalls = await MainActor.run { CountBox() }
        let sleepCalls = await MainActor.run { CountBox() }
        let readinessStarted = AsyncSignal()
        let readinessContinue = AsyncSignal()

        let coordinator = await MainActor.run {
            WakeRecoveryCoordinator(
                hotkeyRetryAttempts: 3,
                hotkeyRetryDelay: 1,
                unregisterHotkeys: { hotkeys.unregister() },
                registerHotkeys: { hotkeys.register() },
                currentHotkeyError: { hotkeys.currentError },
                waitForRuntimeReadiness: {
                    await MainActor.run { readinessCalls.increment() }
                    await readinessStarted.open()
                    await readinessContinue.wait()
                },
                sleep: { _ in
                    await MainActor.run { sleepCalls.increment() }
                }
            )
        }

        let first = Task { await coordinator.handleSystemWake() }
        await readinessStarted.wait()
        await readinessContinue.open()

        let firstResult = await first.value
        let secondResult = await coordinator.handleSystemWake()

        assertTrue(firstResult.hotkeysRecovered, "first wake should recover after retry")
        assertTrue(firstResult.performedRecovery, "first wake should own the recovery task")
        assertTrue(secondResult.hotkeysRecovered, "immediate follow-up wake should observe successful recovery")
        assertFalse(secondResult.performedRecovery, "immediate follow-up wake should reuse the completed recovery")
        let registerCalls = await MainActor.run { hotkeys.registerCalls }
        let readinessCount = await MainActor.run { readinessCalls.count }
        let sleepCount = await MainActor.run { sleepCalls.count }
        assertEqual(registerCalls, 2, "reused wake should not re-register hotkeys")
        assertEqual(readinessCount, 1, "reused wake should not wait for readiness again")
        assertEqual(sleepCount, 1, "reused wake should not add retry sleeps")
    }

    await runSuite("WakeRecoveryCoordinator.handleSystemWake — does not reuse a failed completed recovery") {
        let hotkeys = await MainActor.run { HotkeyScript(scriptedErrors: ["busy", nil]) }

        let coordinator = await MainActor.run {
            WakeRecoveryCoordinator(
                hotkeyRetryAttempts: 1,
                hotkeyRetryDelay: 1,
                unregisterHotkeys: { hotkeys.unregister() },
                registerHotkeys: { hotkeys.register() },
                currentHotkeyError: { hotkeys.currentError },
                waitForRuntimeReadiness: {}
            )
        }

        let firstResult = await coordinator.handleSystemWake()
        let secondResult = await coordinator.handleSystemWake()

        assertFalse(firstResult.hotkeysRecovered, "first wake should fail with scripted hotkey error")
        assertTrue(firstResult.performedRecovery, "first wake should perform recovery")
        assertTrue(secondResult.hotkeysRecovered, "second wake should retry instead of replaying the failed task")
        assertTrue(secondResult.performedRecovery, "failed completed recoveries should not be reused")
        let registerCalls = await MainActor.run { hotkeys.registerCalls }
        assertEqual(registerCalls, 2, "second wake should perform a fresh hotkey registration")
    }

    await runSuite("WakeRecoveryCoordinator.cancel — stale completions do not clear a newer in-flight recovery") {
        let hotkeys = await MainActor.run { HotkeyScript(scriptedErrors: [nil, nil, nil]) }
        let readinessPhase = await MainActor.run { CountBox() }
        let firstReadinessStarted = AsyncSignal()
        let firstReadinessContinue = AsyncSignal()
        let secondReadinessStarted = AsyncSignal()
        let secondReadinessContinue = AsyncSignal()

        let coordinator = await MainActor.run {
            WakeRecoveryCoordinator(
                hotkeyRetryAttempts: 3,
                hotkeyRetryDelay: 1,
                unregisterHotkeys: { hotkeys.unregister() },
                registerHotkeys: { hotkeys.register() },
                currentHotkeyError: { hotkeys.currentError },
                waitForRuntimeReadiness: {
                    await MainActor.run { readinessPhase.increment() }
                    let phase = await MainActor.run { readinessPhase.count }
                    if phase == 1 {
                        await firstReadinessStarted.open()
                        await firstReadinessContinue.wait()
                    } else {
                        await secondReadinessStarted.open()
                        await secondReadinessContinue.wait()
                    }
                }
            )
        }

        let first = Task { await coordinator.handleSystemWake() }
        await firstReadinessStarted.wait()

        await MainActor.run { coordinator.cancel() }

        let second = Task { await coordinator.handleSystemWake() }
        await secondReadinessStarted.wait()

        await firstReadinessContinue.open()
        try? await Task.sleep(nanoseconds: 50_000_000)

        let third = Task { await coordinator.handleSystemWake() }
        try? await Task.sleep(nanoseconds: 50_000_000)
        await secondReadinessContinue.open()

        let firstResult = await first.value
        let secondResult = await second.value
        let thirdResult = await third.value

        assertTrue(firstResult.hotkeysRecovered, "released cancelled recovery should still finish cleanly")
        assertTrue(secondResult.hotkeysRecovered, "replacement recovery should finish cleanly")
        assertTrue(thirdResult.hotkeysRecovered, "joined recovery should observe the replacement result")
        assertTrue(firstResult.performedRecovery, "original task still owned its work before cancellation")
        assertTrue(secondResult.performedRecovery, "replacement task should perform the new recovery")
        assertFalse(thirdResult.performedRecovery, "follow-up wake should join the replacement task instead of starting a third recovery")
        let registerCalls = await MainActor.run { hotkeys.registerCalls }
        assertEqual(registerCalls, 2, "stale completion should not clear the active recovery task")
    }
}
