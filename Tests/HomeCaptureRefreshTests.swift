import Foundation

// Verifies the producer signal -> Home cache re-resolution path that keeps Home's
// scan-time transcript/audio URLs from outliving the real files after background
// recompression (WAV->M4A) and transcript rename.
//
// `RecentMeetingsScanner.loadRecent(directory:)` is the exact re-resolution
// primitive HomeViewModel runs on each reload, so the probe below drives the real
// broadcaster + observer wiring into that primitive against a temp library.
@MainActor
func testHomeCaptureRefresh() async {
    runSuite("Home cache re-resolves transcript + audio URLs after WAV->M4A recompression and rename") {
        guard let meetingsDir = makeHomeRefreshMeetingsDir() else {
            assertTrue(false, "could not create temporary meetings directory")
            return
        }
        defer { try? FileManager.default.removeItem(at: meetingsDir.deletingLastPathComponent()) }

        let oldStem = "meeting-draft"
        let oldTranscriptURL = meetingsDir.appendingPathComponent("\(oldStem).md")
        writeHomeRefreshMeeting(title: "Draft Title", to: oldTranscriptURL)
        writeHomeRefreshAudio(forTranscript: oldTranscriptURL, extension: "wav")

        let center = NotificationCenter()
        let cache = HomeRefreshCacheProbe(directory: meetingsDir)
        let observer = HomeCaptureRefreshObserver(notificationCenter: center) { ids in
            cache.handleSignal(ids)
        }
        _ = observer

        cache.reload()
        assertEqual(cache.items.map(\.transcriptURL.lastPathComponent), ["\(oldStem).md"], "initial scan caches the saved transcript URL")
        assertEqual(
            cache.items.first?.audio?.urls.map { $0.pathExtension },
            ["wav", "wav"],
            "initial scan caches the uncompressed WAV audio URLs"
        )

        // Simulate the background pipeline: recompress WAV->M4A, then rename the
        // transcript + its audio directory to the canonical stem.
        recompressHomeRefreshAudio(forTranscript: oldTranscriptURL)
        let newStem = "2026-06-13 Draft Title"
        let newTranscriptURL = renameHomeRefreshMeeting(
            from: oldTranscriptURL,
            toStem: newStem,
            in: meetingsDir
        )

        let broadcaster = CaptureLibraryChangeBroadcaster(
            notificationCenter: center,
            debounceInterval: 0,
            scheduleFlush: { work in work() }
        )
        broadcaster.noteArtifactsChanged(transcriptURLs: [newTranscriptURL])

        assertEqual(cache.reloadCount, 2, "the capture-changed signal should drive exactly one re-resolution")
        assertEqual(
            cache.items.map(\.transcriptURL.lastPathComponent),
            ["\(newStem).md"],
            "the refreshed cache should hold the renamed transcript URL"
        )
        assertEqual(
            cache.items.first?.audio?.urls.map { $0.pathExtension },
            ["m4a", "m4a"],
            "the refreshed cache should resolve the recompressed M4A audio"
        )

        let allPaths = cache.items.flatMap { item -> [String] in
            [item.transcriptURL.path] + (item.audio?.urls.map(\.path) ?? [])
        }
        assertFalse(
            allPaths.contains(where: { $0.contains(oldStem) || $0.hasSuffix(".wav") }),
            "the refreshed cache must not retain any stale pre-rename / pre-compression path"
        )
        assertTrue(
            allPaths.allSatisfy { FileManager.default.fileExists(atPath: $0) },
            "every URL the refreshed cache holds must exist on disk"
        )
    }

    runSuite("Home cache drops the stale path after a rename-during-scan race") {
        guard let meetingsDir = makeHomeRefreshMeetingsDir() else {
            assertTrue(false, "could not create temporary meetings directory")
            return
        }
        defer { try? FileManager.default.removeItem(at: meetingsDir.deletingLastPathComponent()) }

        let oldStem = "race-draft"
        let oldTranscriptURL = meetingsDir.appendingPathComponent("\(oldStem).md")
        writeHomeRefreshMeeting(title: "Race Title", to: oldTranscriptURL)
        writeHomeRefreshAudio(forTranscript: oldTranscriptURL, extension: "wav")

        let center = NotificationCenter()
        let cache = HomeRefreshCacheProbe(directory: meetingsDir)
        let observer = HomeCaptureRefreshObserver(notificationCenter: center) { ids in
            cache.handleSignal(ids)
        }
        _ = observer

        // The cache scanned and cached the pre-rename URL...
        cache.reload()
        let stalePath = cache.items.first?.transcriptURL.path
        assertNotNil(stalePath, "the initial scan should have cached a transcript URL")

        // ...then the rename lands on disk, making the cached path point at a file
        // that no longer exists (the stale-reveal race PR #1134 patched).
        let newStem = "2026-06-13 Race Title"
        let newTranscriptURL = renameHomeRefreshMeeting(
            from: oldTranscriptURL,
            toStem: newStem,
            in: meetingsDir
        )
        if let stalePath {
            assertFalse(
                FileManager.default.fileExists(atPath: stalePath),
                "the rename should have invalidated the originally cached path"
            )
        }

        // The capture-changed signal makes the cache re-resolve so it never serves
        // the stale path.
        let broadcaster = CaptureLibraryChangeBroadcaster(
            notificationCenter: center,
            debounceInterval: 0,
            scheduleFlush: { work in work() }
        )
        broadcaster.noteArtifactsChanged(transcriptURLs: [newTranscriptURL])

        assertEqual(
            cache.items.map(\.transcriptURL.path),
            [newTranscriptURL.path],
            "after the signal the cache should hold only the current on-disk transcript URL"
        )
        if let stalePath {
            assertFalse(
                cache.items.contains(where: { $0.transcriptURL.path == stalePath }),
                "the refreshed cache must not contain the stale pre-rename path"
            )
        }
    }
}

// MARK: - Probe

/// Minimal stand-in for Home's scan-time cache: holds resolved meeting items and
/// re-resolves them from disk whenever the capture-changed signal arrives — the
/// same reload primitive (`RecentMeetingsScanner.loadRecent`) HomeViewModel uses.
private final class HomeRefreshCacheProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let directory: URL
    private var storedItems: [RecentMeetingItem] = []
    private var storedReloadCount = 0
    private var storedLastSignalIDs: [String]?

    init(directory: URL) {
        self.directory = directory
    }

    func reload() {
        let loaded = RecentMeetingsScanner.loadRecent(limit: 50, directory: directory)
        lock.withLock {
            storedItems = loaded
            storedReloadCount += 1
        }
    }

    func handleSignal(_ ids: [String]) {
        lock.withLock { storedLastSignalIDs = ids }
        reload()
    }

    var items: [RecentMeetingItem] {
        lock.withLock { storedItems }
    }

    var reloadCount: Int {
        lock.withLock { storedReloadCount }
    }

    var lastSignalIDs: [String]? {
        lock.withLock { storedLastSignalIDs }
    }
}

// MARK: - Fixtures

private func makeHomeRefreshMeetingsDir() -> URL? {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent("build/home-capture-refresh-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let meetings = root.appendingPathComponent("meetings", isDirectory: true)
    do {
        try fm.createDirectory(at: meetings, withIntermediateDirectories: true)
        return meetings
    } catch {
        return nil
    }
}

private func writeHomeRefreshMeeting(title: String, to url: URL) {
    let markdown = """
    ---
    title: "\(title)"
    capture_type: meeting
    date: "2026-06-13"
    time: "14:00:00"
    duration: "10:00"
    total_word_count: 5
    mic_utterances: 1
    system_utterances: 1
    ---

    # \(title)

    ## Transcript

    **00:01** [Mic/You]
    Synthetic test meeting.

    **00:04** [System/Remote Participant]
    Synthetic response.
    """
    try? markdown.write(to: url, atomically: true, encoding: .utf8)
}

private func writeHomeRefreshAudio(forTranscript transcriptURL: URL, extension ext: String) {
    let audioDir = MeetingAudioArchiveResolver.archiveDirectory(forTranscript: transcriptURL)
    try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
    FileManager.default.createFile(
        atPath: audioDir.appendingPathComponent("microphone.\(ext)").path,
        contents: Data("mic".utf8)
    )
    FileManager.default.createFile(
        atPath: audioDir.appendingPathComponent("system_audio.\(ext)").path,
        contents: Data("system".utf8)
    )
}

/// Simulate the WAV->M4A recompression step: drop the WAVs and write M4As in the
/// same archive directory.
private func recompressHomeRefreshAudio(forTranscript transcriptURL: URL) {
    let audioDir = MeetingAudioArchiveResolver.archiveDirectory(forTranscript: transcriptURL)
    let fm = FileManager.default
    for stem in ["microphone", "system_audio"] {
        try? fm.removeItem(at: audioDir.appendingPathComponent("\(stem).wav"))
        fm.createFile(
            atPath: audioDir.appendingPathComponent("\(stem).m4a").path,
            contents: Data("compressed".utf8)
        )
    }
}

/// Simulate the transcript restyle rename: move the `.md` and its
/// `audio/<stem>_audio/` directory to the new canonical stem.
private func renameHomeRefreshMeeting(from oldURL: URL, toStem newStem: String, in meetingsDir: URL) -> URL {
    let fm = FileManager.default
    let newURL = meetingsDir.appendingPathComponent("\(newStem).md")
    try? fm.moveItem(at: oldURL, to: newURL)

    let oldAudioDir = MeetingAudioArchiveResolver.archiveDirectory(forTranscript: oldURL)
    let newAudioDir = MeetingAudioArchiveResolver.archiveDirectory(forTranscript: newURL)
    if fm.fileExists(atPath: oldAudioDir.path) {
        try? fm.createDirectory(at: newAudioDir.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.moveItem(at: oldAudioDir, to: newAudioDir)
    }
    return newURL
}
