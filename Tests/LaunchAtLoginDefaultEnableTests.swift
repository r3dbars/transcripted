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
