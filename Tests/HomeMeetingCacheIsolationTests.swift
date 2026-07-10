import Foundation

// Regression coverage for the Home meeting metadata cache:
//   1. Test/CI runs must never write fixture rows into the real
//      ~/Library/Application Support/Transcripted container. The scan path used
//      to reach RecentMeetingMetadataCache.shared, whose static-let DB path is
//      the real user cache, so tests leaked hundreds of dead rows into it.
//   2. The cache self-heals: rows whose transcript no longer exists on disk are
//      pruned on refresh so stale rows can't strand the Home list at
//      "No meetings yet".
func testHomeMeetingCacheIsolation() {
    runSuite("Home scan storage is isolated from the real app-support container") {
        let realHomeCacheDB = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(
                "Library/Application Support/Transcripted/cache/home_meeting_metadata.sqlite"
            )

        // The harness must redirect the container so .shared never resolves to the
        // real user path. Fail loudly rather than silently writing fixture rows
        // into ~/Library/Application Support/Transcripted.
        guard let containerRaw = ProcessInfo.processInfo.environment["TRANSCRIPTED_CONTAINER_DIR"],
              !containerRaw.isEmpty else {
            assertTrue(
                false,
                "TRANSCRIPTED_CONTAINER_DIR must be exported by the test harness to isolate storage"
            )
            return
        }
        // Standardize so a `TMPDIR` trailing slash (→ `//`) can't break the prefix.
        let container = URL(fileURLWithPath: containerRaw, isDirectory: true).standardizedFileURL.path

        // The location .shared writes to must live under the override, never the
        // real container.
        let cacheFolder = MeetingStoragePaths.cacheFolder.standardizedFileURL.path
        assertTrue(
            cacheFolder.hasPrefix(container),
            "cache folder should live under the test container, got \(cacheFolder)"
        )
        assertFalse(
            realHomeCacheDB.deletingLastPathComponent().standardizedFileURL.path.hasPrefix(container),
            "sanity: the real app-support path should differ from the test container"
        )

        let realSizeBefore = fileSizeOrNil(realHomeCacheDB)

        // Exercise the exact path the buggy tests used: scan a fixture directory
        // through the DEFAULT cache (.shared, via the default argument). With the
        // container redirected this must populate the redirected DB and leave the
        // real one untouched.
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("build/home-cache-isolation-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fixtureDir = root.appendingPathComponent("meetings", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            try FileManager.default.createDirectory(at: fixtureDir, withIntermediateDirectories: true)
            let transcript = fixtureDir.appendingPathComponent("Isolation fixture.md")
            try isolationFixtureMarkdown(title: "Isolation fixture")
                .write(to: transcript, atomically: true, encoding: .utf8)

            let scanned = RecentMeetingsScanner.loadRecent(limit: 5, directory: fixtureDir)
            assertTrue(
                scanned.contains { $0.transcriptURL.lastPathComponent == "Isolation fixture.md" },
                "fixture meeting should scan as a Home row (cold path writes the cache)"
            )
        } catch {
            assertionFailure("fixture setup failed: \(error)")
            return
        }

        // The redirected cache DB should now exist under the container...
        let redirectedDB = MeetingStoragePaths.cacheFolder
            .appendingPathComponent("home_meeting_metadata.sqlite", isDirectory: false)
        assertTrue(
            FileManager.default.fileExists(atPath: redirectedDB.path),
            "the scan should have written the Home cache under the redirected container"
        )
        // ...and the real one must be exactly as it was (unchanged / still absent).
        assertEqual(
            fileSizeOrNil(realHomeCacheDB),
            realSizeBefore,
            "the Home scan must not create or grow the real app-support cache DB"
        )
    }

    runSuite("Cache prune drops rows whose transcript file is gone") {
        let cache = RecentMeetingMetadataCache(databaseURL: nil)
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("home-cache-prune-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            assertionFailure("temp dir setup failed: \(error)")
            return
        }

        let presentPath = tempDir.appendingPathComponent("present.md").path
        let missingPath = tempDir.appendingPathComponent("missing.md").path
        FileManager.default.createFile(atPath: presentPath, contents: Data("x".utf8))

        let stamp = RecentMeetingCacheStamp(
            transcriptModified: 1,
            transcriptSize: 1,
            summaryModified: 0,
            summarySize: -1
        )
        let payload = CachedRecentMeetingMetadata(
            title: "T",
            displayDate: Date(),
            startDate: nil,
            endDate: nil,
            speakerNeedsReviewCount: nil,
            summaryPreview: nil,
            hasAudioHealth: false,
            audioHealthMicBoostOutcome: nil
        )
        cache.store(path: presentPath, stamp: stamp, metadata: payload)
        cache.store(path: missingPath, stamp: stamp, metadata: payload)

        assertNotNil(cache.lookup(path: presentPath, stamp: stamp), "present row should be cached before prune")
        assertNotNil(cache.lookup(path: missingPath, stamp: stamp), "missing row should be cached before prune")

        let removed = cache.pruneMissingPaths()
        assertEqual(removed, 1, "prune should drop exactly the row whose file is gone")
        assertNotNil(
            cache.lookup(path: presentPath, stamp: stamp),
            "a row whose file still exists should survive prune"
        )
        assertNil(
            cache.lookup(path: missingPath, stamp: stamp),
            "a row whose file is missing should be pruned"
        )

        cache.store(path: missingPath, stamp: stamp, metadata: payload)
        assertEqual(
            cache.pruneMissingPathsIfNeeded(now: Date(timeIntervalSince1970: 100)),
            1,
            "first scheduled prune should heal a stale row"
        )
        cache.store(path: missingPath, stamp: stamp, metadata: payload)
        assertEqual(
            cache.pruneMissingPathsIfNeeded(now: Date(timeIntervalSince1970: 130)),
            0,
            "scheduled pruning should not repeat on every refresh"
        )
        assertEqual(
            cache.pruneMissingPathsIfNeeded(now: Date(timeIntervalSince1970: 160)),
            1,
            "scheduled pruning should run again after its maintenance interval"
        )
    }
}

private func fileSizeOrNil(_ url: URL) -> Int64? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
          let size = attributes[.size] as? NSNumber else {
        return nil
    }
    return size.int64Value
}

private func isolationFixtureMarkdown(title: String) -> String {
    let id = UUID().uuidString
    let frontmatter = [
        "---",
        "capture_id: \"\(id)\"",
        "transcript_id: \"\(id)\"",
        "capture_type: meeting",
        "title: \"\(title)\"",
        "date: \"2026-06-05\"",
        "time: \"18:39:20\"",
        "duration: \"0:04\"",
        "total_word_count: 2",
        "mic_utterances: 1",
        "system_utterances: 1",
        "---"
    ].joined(separator: "\n")
    return frontmatter + """


    # \(title)

    ## Transcript

    **00:01** [Mic/You]
    Synthetic test.

    **00:02** [System/Remote]
    Synthetic reply.
    """
}
