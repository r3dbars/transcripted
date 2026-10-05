import Foundation

/// A closed Settings window stops paying for work nobody can see, and
/// reopening performs one explicit refresh without hidden scans.
func testSettingsClosedWindowPolicy() {
    runSuite("Closed window - app activation skips permissions and library scans") {
        let closed = SettingsClosedWindowRefreshPolicy.appActivationWork(isWindowOpen: false)
        assertFalse(closed.permissions, "no TCC reads for a closed window")
        assertFalse(closed.shortcuts, "no shortcut re-read for a closed window")
        assertFalse(closed.launchAtLogin, "no login-item read for a closed window")
        assertFalse(closed.recentCaptures, "presenting the window refreshes Today once instead")
        assertFalse(closed.dashboard, "activation doesn't reload Home and Dictations for a closed window")

        let open = SettingsClosedWindowRefreshPolicy.appActivationWork(isWindowOpen: true)
        assertEqual(
            open,
            .init(permissions: true, shortcuts: true, launchAtLogin: true, recentCaptures: true, dashboard: true),
            "an open window refreshes everything on activation, as before"
        )
    }

    runSuite("Closed window - rebuilds are held, and the newest one shows on reopen") {
        var hold = SettingsWindowSnapshotHold<Int>()
        assertEqual(hold.deliver(1), 1, "an open window publishes right away")

        hold.windowDidClose()
        assertNil(hold.deliver(2), "a closed window doesn't publish")
        assertNil(hold.deliver(3), "still closed")
        assertEqual(hold.windowWillShow(), 3, "reopening hands back the newest rebuild")
        assertNil(hold.windowWillShow(), "and only once")
        assertEqual(hold.deliver(4), 4, "open again: publishes right away")

        hold.windowDidClose()
        assertNil(hold.windowWillShow(), "nothing built while closed, nothing to swap in")
    }

    runSuite("Today writing cache - unchanged day files aren't parsed again") {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("today-writing-cache-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Writing_2026-09-24.md")
        func entry(_ id: Int) -> String {
            """

            ## 10:4\(id) AM - Note \(id)

            Entry ID: `writing-\(id)`
            Captured: 2026-09-24T15:4\(id):11.387Z
            Source app: Notes
            Words: 2
            Accepted words: 0

            note \(id)
            """
        }
        try? ("# Writing" + entry(1)).write(to: file, atomically: true, encoding: .utf8)

        let cache = TodayWritingDayFileCache()
        var reads = 0
        func facts() -> [TodayWritingFact]? {
            // A fresh URL, like each scan's directory listing gives: URLs
            // cache their resource values.
            let listed = URL(fileURLWithPath: file.path)
            return cache.facts(for: listed, signature: TodayWritingDayFileCache.signature(of: listed)) {
                reads += 1
                return try? String(contentsOf: file, encoding: .utf8)
            }
        }
        assertEqual(facts()?.map(\.entryID), ["writing-1"], "first read parses the file")
        assertEqual(facts()?.map(\.entryID), ["writing-1"], "same entries from the cache")
        assertEqual(reads, 1, "an unchanged file isn't read twice")

        try? ("# Writing" + entry(1) + entry(2)).write(to: file, atomically: true, encoding: .utf8)
        assertEqual(facts()?.map(\.entryID), ["writing-1", "writing-2"], "a saved entry shows up")
        assertEqual(reads, 2, "a changed file is read again")

        cache.retainOnly([])
        _ = facts()
        assertEqual(reads, 3, "a file dropped from the scan is forgotten")

        let unknown = TodayWritingDayFileCache.Signature(modifiedAt: nil, size: nil)
        _ = cache.facts(for: file, signature: unknown) { reads += 1; return "" }
        _ = cache.facts(for: file, signature: unknown) { reads += 1; return "" }
        assertEqual(reads, 5, "without a date and size the cache never trusts a hit")
    }
}
