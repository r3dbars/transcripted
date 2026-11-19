import Foundation

func testMeetingTitlesDisplay() {
    runSuite("Home rows show the on-device title and carry the line and summary, cold and warm") {
        let directory = MeetingTitlesFixtures.temporaryDirectory("titles-home")
        defer { try? FileManager.default.removeItem(at: directory) }
        let labeled = MeetingTitlesFixtures.meetingMarkdown(title: "Meeting with Priya", extraFrontmatter: [
            "ai_title: \"Vendor contract renewal\"",
            "ai_title_replaces: \"Meeting with Priya\"",
            "ai_summary_line: \"The renewal goes ahead for one year.\"",
            "ai_summary: \"Two bids were compared. The current vendor stays.\"",
            "ai_summary_version: \"1\"",
        ])
        let renamed = MeetingTitlesFixtures.meetingMarkdown(title: "Board prep", date: "2026-03-03", extraFrontmatter: [
            "title_set_by_user: true",
            "ai_title: \"Vendor contract renewal\"",
            "ai_title_replaces: \"Meeting with Priya\"",
        ])
        let plain = MeetingTitlesFixtures.meetingMarkdown(title: "Meeting at 10:05 AM", date: "2026-03-02")
        MeetingTitlesFixtures.writeMeeting(labeled, named: "2026-03-04 Meeting with Priya.md", in: directory)
        MeetingTitlesFixtures.writeMeeting(renamed, named: "2026-03-03 Board prep.md", in: directory)
        MeetingTitlesFixtures.writeMeeting(plain, named: "2026-03-02 Meeting at 10.05 AM.md", in: directory)

        let cache = RecentMeetingMetadataCache(databaseURL: nil)
        for pass in ["cold", "warm"] {
            let rows = RecentMeetingsScanner.loadRecent(limit: 10, directory: directory, cache: cache)
            let labeledRow = rows.first { $0.title == "Meeting with Priya" }
            assertEqual(labeledRow?.displayTitle, "Vendor contract renewal", pass)
            assertEqual(labeledRow?.summaryLine, "The renewal goes ahead for one year.", pass)
            assertEqual(labeledRow?.summary, "Two bids were compared. The current vendor stays.", pass)
            assertEqual(rows.first { $0.title == "Board prep" }?.displayTitle, "Board prep", "\(pass): rename wins")
            assertEqual(rows.first { $0.title == "Meeting at 10:05 AM" }?.displayTitle, "Meeting at 10:05 AM", "\(pass): the app's title")
        }
    }

    runSuite("Home search finds a meeting by its on-device title and its saved title") {
        var item = RecentMeetingItem(
            title: "Meeting with Priya", date: Date(), startDate: nil, endDate: nil,
            transcriptURL: URL(fileURLWithPath: "/tmp/a.md"), audio: nil, speakerStatus: .ready
        )
        item.titles = MeetingTitlesFields(aiTitle: "Vendor contract renewal", aiTitleReplaces: "Meeting with Priya")
        let fields = HomeMeetingListFilter.searchFields(for: item)
        assertTrue(fields.contains("Vendor contract renewal"))
        assertTrue(fields.contains("Meeting with Priya"))
    }

    runSuite("The settings row says what it costs, how far along it is, and when it failed") {
        typealias Copy = MeetingTitlesSettingsCopy
        assertEqual(Copy.state(isEnabled: false, status: .notDownloaded, activity: .idle), .caption("3.1 GB download"))
        assertEqual(Copy.state(isEnabled: true, status: .ready, activity: .idle), .caption("On"))
        assertEqual(Copy.state(isEnabled: true, status: .ready, activity: .waitingForBusy), .caption("Waiting until you're done"))
        if case .progress(let fraction, _) = Copy.state(isEnabled: true, status: .downloading(received: 50, total: 200), activity: .idle) {
            assertEqual(fraction, 0.25)
        } else {
            assertTrue(false, "downloading shows progress")
        }
        assertEqual(Copy.state(isEnabled: true, status: .failed(.offline), activity: .idle), .failed("Download stopped"))
        assertEqual(Copy.state(isEnabled: true, status: .failed(.checksumMismatch), activity: .idle), .failed("Download was damaged"))
        assertEqual(Copy.state(isEnabled: true, status: .ready, activity: .engineUnavailable), .failed("Couldn't start the model"))
    }

    runSuite("The titles model shows in model storage and is reclaimable only while the feature is off") {
        let root = MeetingTitlesFixtures.temporaryDirectory("titles-inventory")
        defer { try? FileManager.default.removeItem(at: root) }
        let models = root.appendingPathComponent("models", isDirectory: true)
        let titles = ModelCacheInventory.meetingTitlesModelsDirectory(in: models)
            .appendingPathComponent("gemma-4-e2b-it-q4km", isDirectory: true)
        let keep = models.appendingPathComponent("parakeet-ultra/keep.bin")
        try? FileManager.default.createDirectory(at: titles, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: keep.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(repeating: 1, count: 4_000).write(to: titles.appendingPathComponent("model.gguf"))
        try? Data(repeating: 2, count: 10).write(to: keep)

        let snapshot = ModelCacheInventory.snapshot(
            fluidAudioModelsDirectory: root.appendingPathComponent("fluid"),
            transcriptedCacheDirectory: root.appendingPathComponent("cache"),
            whisperModelsDirectory: root.appendingPathComponent("cache/whisperkit/models"),
            meetingTitlesModelsDirectory: ModelCacheInventory.meetingTitlesModelsDirectory(in: models)
        )
        assertEqual(snapshot.meetingTitlesModelBytes, 4_000)
        assertEqual(snapshot.reclaimableBytes(includeWhisper: false, includeMeetingTitles: false), 0)
        assertEqual(snapshot.reclaimableBytes(includeWhisper: false, includeMeetingTitles: true), 4_000)

        let kept = try? ModelCacheInventory.removeReclaimableCaches(
            includeWhisper: false, includeMeetingTitles: false,
            fluidAudioModelsDirectory: root.appendingPathComponent("fluid"),
            transcriptedCacheDirectory: root.appendingPathComponent("cache"),
            whisperModelsDirectory: root.appendingPathComponent("cache/whisperkit/models"),
            modelsRootDirectory: models
        )
        assertEqual(kept?.removedBytes, 0, "on: the model stays")
        let removed = try? ModelCacheInventory.removeReclaimableCaches(
            includeWhisper: false, includeMeetingTitles: true,
            fluidAudioModelsDirectory: root.appendingPathComponent("fluid"),
            transcriptedCacheDirectory: root.appendingPathComponent("cache"),
            whisperModelsDirectory: root.appendingPathComponent("cache/whisperkit/models"),
            modelsRootDirectory: models
        )
        assertEqual(removed?.removedBytes, 4_000)
        assertFalse(FileManager.default.fileExists(atPath: titles.path))
        assertTrue(FileManager.default.fileExists(atPath: keep.path), "other models stay")
    }

    runSuite("Free up space says when it takes the titles model") {
        let message = StorageConfirmationPolicy.freeUpSpaceMessage(whisperIsSelected: false, removesMeetingTitlesModel: true)
        assertTrue(message.contains("meeting titles model"))
        assertFalse(StorageConfirmationPolicy.freeUpSpaceMessage(whisperIsSelected: false, removesMeetingTitlesModel: false).contains("titles"))
    }
}
