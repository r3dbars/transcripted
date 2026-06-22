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

    runSuite("SingleInstanceGuard duplicate-launch handoff copy is user-ready") {
        assertEqual(
            SingleInstanceGuard.HandoffNotice.alreadyRunningTitle,
            "Transcripted is already running",
            "the handoff title should name the already-running state plainly"
        )
        assertTrue(
            SingleInstanceGuard.HandoffNotice.alreadyRunningMessage.contains("menu bar"),
            "the handoff message should explain where the running copy lives"
        )
        assertFalse(
            SingleInstanceGuard.HandoffNotice.openButtonTitle.isEmpty,
            "the handoff should offer a way to bring the running instance forward"
        )
        assertFalse(
            SingleInstanceGuard.HandoffNotice.dismissButtonTitle.isEmpty,
            "the handoff should offer a way to dismiss the notice"
        )
    }
}
