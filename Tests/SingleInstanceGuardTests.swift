import Foundation

func testSingleInstanceGuard() {
    runSuite("SingleInstanceGuard acquires and releases the app instance lock") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SingleInstanceGuardTests-\(UUID().uuidString)", isDirectory: true)
        let lockURL = tempRoot.appendingPathComponent("transcripted.instance.lock", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let first = SingleInstanceGuard(lockURL: lockURL)
        let second = SingleInstanceGuard(lockURL: lockURL)

        assertEqual(first.acquire(), .acquired, "first app instance should acquire the lock")
        assertEqual(second.acquire(), .alreadyRunning, "second app instance should be rejected while the lock is held")

        first.release()

        assertEqual(second.acquire(), .acquired, "second app instance should acquire the lock after release")
    }

    runSuite("SingleInstanceGuard acquire is idempotent for the owning process") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SingleInstanceGuardTests-\(UUID().uuidString)", isDirectory: true)
        let lockURL = tempRoot.appendingPathComponent("transcripted.instance.lock", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let guardInstance = SingleInstanceGuard(lockURL: lockURL)

        assertEqual(guardInstance.acquire(), .acquired, "first acquire should succeed")
        assertEqual(guardInstance.acquire(), .acquired, "same guard should not reject its own repeated acquire")
    }

    runSuite("SingleInstanceReopenPolicy sends a second launch to real controls, never an alert") {
        // Every surface is a live control: there is no alert case for a reopen to block on.
        assertEqual(
            SingleInstanceReopenSurface.allCases,
            [.onboarding, .popover, .settingsFallback],
            "reopen should only ever land on onboarding, the popover, or Settings"
        )
        assertEqual(
            SingleInstanceReopenPolicy.surface(onboardingComplete: false, hasStatusItem: true),
            .onboarding,
            "unfinished onboarding must remain reachable even with a status item"
        )
        assertEqual(
            SingleInstanceReopenPolicy.surface(onboardingComplete: false, hasStatusItem: false),
            .onboarding,
            "unfinished onboarding must remain reachable without a status item"
        )
        assertEqual(
            SingleInstanceReopenPolicy.surface(onboardingComplete: true, hasStatusItem: true),
            .popover,
            "reopen must surface the existing recording controls"
        )
        assertEqual(
            SingleInstanceReopenPolicy.surface(onboardingComplete: true, hasStatusItem: false),
            .settingsFallback,
            "reopen must retain the no-status-item fallback"
        )
    }
}
