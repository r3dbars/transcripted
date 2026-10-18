import Foundation

// Finishing onboarding registers the login item once. SMAppService calls are
// blocking XPC round trips, so the register must not run on the main thread,
// and a failure must come back to the caller instead of vanishing.
@MainActor
func testLaunchAtLoginDefaultEnable() async {
    await runSuite("Onboarding's default login-item register runs off the main thread and reports a failure") {
        let (defaults, suiteName) = makeLaunchAtLoginDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let probe = LaunchAtLoginRegisterProbe()

        let failure = await LaunchAtLoginController.applyDefaultEnableIfNeeded(
            onboardingCompleted: true,
            userDefaults: defaults,
            register: {
                probe.record(onMainThread: Thread.isMainThread)
                throw LaunchAtLoginRegisterFailure()
            }
        )

        assertEqual(probe.calls, 1, "a fresh install should register the login item once")
        assertFalse(probe.ranOnMainThread, "the blocking register call must not run on the main thread")
        assertEqual(failure, LaunchAtLoginRegisterFailure().localizedDescription, "a register failure should reach the caller")
        assertTrue(LaunchAtLoginPreferences.hasAppliedDefaultEnable(userDefaults: defaults), "the one-time default should be marked applied")

        let again = await LaunchAtLoginController.applyDefaultEnableIfNeeded(
            onboardingCompleted: true,
            userDefaults: defaults,
            register: { probe.record(onMainThread: Thread.isMainThread) }
        )
        assertNil(again, "nothing to report once the default was applied")
        assertEqual(probe.calls, 1, "the default enable runs at most once per install")
    }

    await runSuite("An explicit launch-at-login choice skips the default register") {
        let (defaults, suiteName) = makeLaunchAtLoginDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        LaunchAtLoginPreferences.setEnabled(false, userDefaults: defaults)
        let probe = LaunchAtLoginRegisterProbe()

        let failure = await LaunchAtLoginController.applyDefaultEnableIfNeeded(
            onboardingCompleted: true,
            userDefaults: defaults,
            register: { probe.record(onMainThread: Thread.isMainThread) }
        )

        assertNil(failure, "no register means no failure")
        assertEqual(probe.calls, 0, "an explicit Settings choice always wins over the default")
    }

    await runSuite("A Settings opt-out made while the default register is pending runs after it and wins") {
        let (defaults, suiteName) = makeLaunchAtLoginDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let order = LaunchAtLoginOrderProbe()
        let toggleProbe = LaunchAtLoginRegisterProbe()
        let registerStarted = DispatchSemaphore(value: 0)
        let releaseRegister = DispatchSemaphore(value: 0)
        let toggleApplied = DispatchSemaphore(value: 0)

        let registerTask = Task.detached {
            await LaunchAtLoginController.applyDefaultEnableIfNeeded(
                onboardingCompleted: true,
                userDefaults: defaults,
                register: {
                    registerStarted.signal()
                    releaseRegister.wait()
                    order.append("register")
                }
            )
        }
        _ = await launchAtLoginWait(registerStarted)

        let toggleTask = Task.detached {
            try await LaunchAtLoginController.setEnabled(false, userDefaults: defaults, apply: { enabled in
                toggleProbe.record(onMainThread: Thread.isMainThread)
                order.append(enabled ? "enable" : "disable")
                toggleApplied.signal()
            })
        }
        // The window only gives an unserialized toggle the chance to jump the
        // queue; a serialized one can't finish before the register is released.
        let toggleRanEarly = await launchAtLoginWait(toggleApplied, timeout: 0.2)
        assertFalse(toggleRanEarly, "the toggle must wait behind the pending register")

        releaseRegister.signal()
        _ = await registerTask.value
        let toggleError: Error? = await {
            do { try await toggleTask.value; return nil } catch { return error }
        }()

        assertNil(toggleError, "the opt-out should succeed")
        assertEqual(order.events, ["register", "disable"], "turning the setting off must run after the pending register, not before it")
        assertFalse(toggleProbe.ranOnMainThread, "the Settings toggle's login-item call must not run on the main thread")
        assertTrue(LaunchAtLoginPreferences.hasExplicitChoice(userDefaults: defaults), "the opt-out should be saved")
        assertFalse(LaunchAtLoginPreferences.isEnabled(userDefaults: defaults), "the saved choice should stay off")
    }

    await runSuite("A default register that queues behind an in-flight opt-out never registers") {
        let (defaults, suiteName) = makeLaunchAtLoginDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let registerProbe = LaunchAtLoginRegisterProbe()
        let toggleStarted = DispatchSemaphore(value: 0)
        let releaseToggle = DispatchSemaphore(value: 0)
        let registerDone = DispatchSemaphore(value: 0)

        let toggleTask = Task.detached {
            try await LaunchAtLoginController.setEnabled(false, userDefaults: defaults, apply: { _ in
                toggleStarted.signal()
                releaseToggle.wait()
            })
        }
        _ = await launchAtLoginWait(toggleStarted)

        // Onboarding finishes while the opt-out is still in flight, so no
        // explicit choice is saved yet and the default register gets queued.
        let registerTask = Task.detached {
            let failure = await LaunchAtLoginController.applyDefaultEnableIfNeeded(
                onboardingCompleted: true,
                userDefaults: defaults,
                register: { registerProbe.record(onMainThread: Thread.isMainThread) }
            )
            registerDone.signal()
            return failure
        }
        let registerFinishedEarly = await launchAtLoginWait(registerDone, timeout: 0.2)
        assertFalse(registerFinishedEarly, "the default register must wait behind the in-flight opt-out")

        releaseToggle.signal()
        let failure = await registerTask.value
        try? await toggleTask.value

        assertNil(failure, "a skipped register has nothing to report")
        assertEqual(registerProbe.calls, 0, "the opt-out saved first must stop the queued default register")
        assertFalse(LaunchAtLoginPreferences.isEnabled(userDefaults: defaults), "the saved choice should stay off")
    }
}

/// Waits for a semaphore without blocking the main actor, which the
/// controller's own async calls need to hop back onto. Returns whether it was
/// signaled; with a timeout, `false` means the window passed first.
private func launchAtLoginWait(_ semaphore: DispatchSemaphore, timeout: TimeInterval? = nil) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            if let timeout {
                continuation.resume(returning: semaphore.wait(timeout: .now() + timeout) == .success)
            } else {
                semaphore.wait()
                continuation.resume(returning: true)
            }
        }
    }
}

private final class LaunchAtLoginOrderProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var events: [String] { lock.withLock { recorded } }
    func append(_ event: String) { lock.withLock { recorded.append(event) } }
}

private struct LaunchAtLoginRegisterFailure: LocalizedError {
    var errorDescription: String? { "register refused" }
}

private final class LaunchAtLoginRegisterProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0
    private var sawMainThread = false

    var calls: Int { lock.withLock { callCount } }
    var ranOnMainThread: Bool { lock.withLock { sawMainThread } }

    func record(onMainThread: Bool) {
        lock.withLock {
            callCount += 1
            if onMainThread { sawMainThread = true }
        }
    }
}

private func makeLaunchAtLoginDefaults() -> (UserDefaults, String) {
    let suiteName = "LaunchAtLoginDefaultEnableTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
}
