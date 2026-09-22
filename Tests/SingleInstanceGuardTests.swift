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

    runSuite("SingleInstanceGuard reopen presents controls without a modal alert") {
        let sourceURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/TranscriptedApp.swift")
        let source = (try? String(contentsOf: sourceURL, encoding: .utf8)) ?? ""
        let body = source.components(separatedBy: "private func handleSingleInstanceReopenRequest() {")
            .dropFirst().first?.components(separatedBy: "@objc func togglePopover()").first ?? ""
        assertFalse(body.isEmpty, "the production reopen handler must be present")
        assertFalse(body.contains("NSAlert("), "reopen must not hide recording controls behind an alert")
        assertFalse(body.contains("runModal("), "reopen must not block capture commands in a modal loop")
        assertTrue(body.contains("onboardingWindowController.present"), "unfinished onboarding must remain reachable")
        assertTrue(body.contains("showMainPopover("), "reopen must surface the existing recording controls")
        assertTrue(body.contains("showSettingsWindow("), "reopen must retain the no-status-item fallback")
    }
}
