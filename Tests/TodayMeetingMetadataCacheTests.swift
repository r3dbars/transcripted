import Foundation

func testTodayMeetingMetadataCache() {
    // One row uses direct lookup; 33 exceeds the scanner's bulk-query threshold.
    for count in [1, 33] {
        runSuite("Today persists bounded rows across cache instances for \(count) meetings without hiding full speaker search") {
            withTodayCacheFixture { fixture in
                try fixture.writeMeetings(count: count, title: "Before")
                let cache = RecentMeetingMetadataCache(databaseURL: fixture.database)
                let first = RecentMeetingsScanner.loadTodayIndex(directory: fixture.meetings, cache: cache) ?? []
                assertEqual(first.count, count)
                assertTrue(first.allSatisfy { !$0.includesSpeakerDetails && $0.item.speakerNames.isEmpty },
                           "Today preserves bounded parsing even with named speakers after the preview")
                assertTrue(cache.allRows().isEmpty, "legacy full-cache readers cannot see bounded rows")
                let previous = Dictionary(uniqueKeysWithValues: first.map { ($0.path, $0) })
                for entry in first {
                    assertNil(cache.lookup(path: entry.path, stamp: entry.stamp), "partial rows never satisfy full lookup")
                }

                // Change content without its identity stamp. Cached output must
                // retain Before while the uncached control observes After!.
                try fixture.writeMeetings(count: count, title: "After!")
                let control = RecentMeetingsScanner.loadTodayIndex(directory: fixture.meetings, cache: nil) ?? []
                assertTrue(control.allSatisfy { $0.item.title == "After!" }, "the control reads the changed bytes")
                assertEqual(control.map(\.stamp), first.map(\.stamp), "the fixture retains the exact file stamps")
                let reopened = RecentMeetingMetadataCache(databaseURL: fixture.database)
                let warm = RecentMeetingsScanner.loadTodayIndex(directory: fixture.meetings, cache: reopened) ?? []
                assertEqual(warm.count, count)
                assertTrue(warm.allSatisfy { $0.item.title == "Before" }, "a reopened cache retains Today work")

                let full = RecentMeetingsScanner.loadSearchIndex(
                    directory: fixture.meetings, cache: reopened, previous: previous
                ) ?? []
                assertEqual(full.count, count)
                assertTrue(full.allSatisfy { $0.includesSpeakerDetails && $0.item.title == "After!" },
                           "neither persisted nor previous Today rows satisfy full search")
                assertTrue(full.allSatisfy { $0.item.speakerNames == ["Late Person"] },
                           "full search still finds speakers beyond the bounded preview")
                let todayFromFull = RecentMeetingsScanner.loadTodayIndex(directory: fixture.meetings, cache: reopened) ?? []
                assertEqual(todayFromFull.count, count)
                assertTrue(todayFromFull.allSatisfy { $0.includesSpeakerDetails && $0.item.title == "After!" },
                           "matching full rows win over matching partial rows")
                assertTrue(todayFromFull.allSatisfy { $0.item.speakerNames == ["Late Person"] })
            }
        }

        runSuite("A stale full row cannot mask a fresh persisted Today row for \(count) meetings") {
            withTodayCacheFixture { fixture in
                try fixture.writeMeetings(count: count, title: "Before")
                let cache = RecentMeetingMetadataCache(databaseURL: fixture.database)
                let old = RecentMeetingsScanner.loadSearchIndex(directory: fixture.meetings, cache: cache) ?? []
                assertEqual(old.count, count)
                assertEqual(cache.allRows().count, count, "the stale full rows actually exist before the change")
                try fixture.writeMeetings(count: count, title: "Newest", modified: fixture.modified.addingTimeInterval(60))
                let fresh = RecentMeetingsScanner.loadTodayIndex(directory: fixture.meetings, cache: cache) ?? []
                assertEqual(fresh.count, count)
                assertTrue(fresh.allSatisfy { $0.item.title == "Newest" && !$0.includesSpeakerDetails })
                assertTrue(fresh.map(\.stamp) != old.map(\.stamp), "the changed stamp invalidates the old full row")
                try fixture.writeMeetings(count: count, title: "Hidden", modified: fixture.modified.addingTimeInterval(60))
                let reopened = RecentMeetingMetadataCache(databaseURL: fixture.database)
                let warm = RecentMeetingsScanner.loadTodayIndex(directory: fixture.meetings, cache: reopened) ?? []
                assertEqual(warm.count, count)
                assertTrue(warm.allSatisfy { $0.item.title == "Newest" && !$0.includesSpeakerDetails },
                           "matching partial rows survive reopening alongside stale full rows")
                let control = RecentMeetingsScanner.loadTodayIndex(directory: fixture.meetings, cache: nil) ?? []
                assertTrue(control.allSatisfy { $0.item.title == "Hidden" })
                assertEqual(control.map(\.stamp), fresh.map(\.stamp))
            }
        }
    }

    runSuite("Pruning removes both cache projections and counts each missing path once") {
        withTodayCacheFixture { fixture in
            try fixture.writeMeetings(count: 1, title: "Before")
            let cache = RecentMeetingMetadataCache(databaseURL: fixture.database)
            let partial = RecentMeetingsScanner.loadTodayIndex(directory: fixture.meetings, cache: cache) ?? []
            _ = RecentMeetingsScanner.loadSearchIndex(directory: fixture.meetings, cache: cache)
            guard let entry = partial.first else { assertTrue(false, "fixture should produce a row"); return }
            try fixture.removeMeeting(at: entry.item.transcriptURL)
            assertEqual(cache.pruneMissingPaths(), 1, "two projections still describe one missing path")
            assertTrue(cache.allRows().isEmpty)
            assertTrue(cache.allRowsForToday().isEmpty)
        }
    }
}

private struct TodayCacheFixture {
    let root: URL
    let parent: URL
    let modified = Date(timeIntervalSince1970: 1_780_000_000)
    var meetings: URL { root.appendingPathComponent("meetings", isDirectory: true) }
    var database: URL { root.appendingPathComponent("metadata.sqlite") }

    func ownsRoot() -> Bool {
        let canonical = root.resolvingSymlinksInPath().standardizedFileURL
        let prefix = "today-metadata-cache-"
        let name = canonical.lastPathComponent
        return canonical == root.standardizedFileURL && canonical.deletingLastPathComponent() == parent
            && name.hasPrefix(prefix) && UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
    }

    func writeMeetings(count: Int, title: String, modified: Date? = nil) throws {
        for index in 0..<count {
            let url = meetings.appendingPathComponent("meeting-\(index).md")
            let markdown = """
            ---
            title: "\(title)"
            capture_type: meeting
            date: "2026-05-28"
            time: "12:00:00"
            duration: "10:00"
            ---

            # \(title)

            ## Full Transcript

            """ + String(repeating: "A synthetic paragraph.\n", count: 4_000)
                + "\n[00:04] [System/Late Person] Synthetic words.\n"
            try markdown.write(to: url, atomically: false, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: modified ?? self.modified], ofItemAtPath: url.path)
        }
    }

    func removeMeeting(at url: URL) throws {
        guard ownsRoot(), url.resolvingSymlinksInPath().deletingLastPathComponent() == meetings,
              url.lastPathComponent == "meeting-0.md" else {
            assertTrue(false, "refusing to remove an unowned meeting fixture")
            return
        }
        try FileManager.default.removeItem(at: url)
    }
}

private func withTodayCacheFixture(_ body: (TodayCacheFixture) throws -> Void) {
    let fm = FileManager.default
    let parent = fm.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
    let fixture = TodayCacheFixture(
        root: parent.appendingPathComponent("today-metadata-cache-\(UUID().uuidString)", isDirectory: true), parent: parent
    )
    defer {
        if fixture.ownsRoot() {
            do { try fm.removeItem(at: fixture.root) }
            catch { assertTrue(false, "could not remove owned Today metadata fixture") }
        } else { assertTrue(false, "refusing to remove an unowned Today metadata root") }
    }
    do {
        try fm.createDirectory(at: fixture.meetings, withIntermediateDirectories: true)
        try body(fixture)
    } catch { assertTrue(false, "owned Today metadata fixture operation failed") }
}
