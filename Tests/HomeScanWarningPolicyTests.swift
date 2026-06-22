import Foundation

func testHomeScanWarningPolicy() {
    let fm = FileManager.default

    func temporaryRoot() -> URL {
        let root = fm.temporaryDirectory.appendingPathComponent("home-scan-warning-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    runSuite("RecentMeetingsScanner.diagnose reports a healthy meetings folder as ok") {
        let dir = temporaryRoot()
        defer { try? fm.removeItem(at: dir) }
        assertEqual(
            RecentMeetingsScanner.diagnose(directory: dir),
            .ok,
            "an existing readable directory should diagnose as ok"
        )
    }

    runSuite("RecentMeetingsScanner.diagnose treats a missing folder as the empty state") {
        let root = temporaryRoot()
        defer { try? fm.removeItem(at: root) }
        let missing = root.appendingPathComponent("not-created-yet", isDirectory: true)
        assertEqual(
            RecentMeetingsScanner.diagnose(directory: missing),
            .missingFolder,
            "a folder that was never created should be the benign empty state, not damage"
        )
    }

    runSuite("RecentMeetingsScanner.diagnose flags a file-shaped meetings path as damaged") {
        let root = temporaryRoot()
        defer { try? fm.removeItem(at: root) }
        let filePath = root.appendingPathComponent("meetings", isDirectory: false)
        fm.createFile(atPath: filePath.path, contents: Data("not a directory".utf8))
        assertEqual(
            RecentMeetingsScanner.diagnose(directory: filePath),
            .damagedPath(reason: .notADirectory),
            "a path that resolves to a file should diagnose as a damaged, not-a-directory path"
        )
    }

    runSuite("HomeScanWarningPolicy stays silent for ok and missing-folder states") {
        assertNil(
            HomeScanWarningPolicy.card(for: .ok),
            "a healthy folder must not raise a warning card"
        )
        assertNil(
            HomeScanWarningPolicy.card(for: .missingFolder),
            "a not-yet-created folder is the normal empty state and must not warn"
        )
    }

    runSuite("HomeScanWarningPolicy surfaces a named retry/reveal card for a damaged path") {
        let dir = temporaryRoot()
        defer { try? fm.removeItem(at: dir) }
        let filePath = dir.appendingPathComponent("meetings", isDirectory: false)
        fm.createFile(atPath: filePath.path, contents: Data("not a directory".utf8))

        let diagnosis = RecentMeetingsScanner.diagnose(directory: filePath)
        let card = HomeScanWarningPolicy.card(for: diagnosis)
        assertNotNil(card, "a damaged path should produce a warning card")
        guard let card else { return }

        assertFalse(card.title.isEmpty, "the card must name the issue with a non-empty title")
        assertFalse(card.detail.isEmpty, "the card must explain the damaged path")
        assertEqual(card.retryTitle, "Retry", "the card must keep a clear Retry target")
        assertEqual(card.revealTitle, "Reveal in Finder", "the card must keep a Reveal-in-Finder target")
    }
}
