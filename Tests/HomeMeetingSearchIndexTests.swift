import Foundation

func testHomeMeetingSearchIndex() async {
    runSuite("RecentMeetingSpeakerStatus.speakerNames keeps named speakers only") {
        let labels = [
            "Mic/You",
            "System/Alex Rivera",
            "System/Speaker 2",
            "Mic/Unknown speaker",
            "System/alex rivera",
            "Mic/Priya",
            "System/Review later",
            "System/Remote",
            "System/Remote Participant",
            "Casey"
        ]
        assertEqual(
            RecentMeetingSpeakerStatus.speakerNames(fromLabels: labels),
            ["Alex Rivera", "Priya", "Casey"],
            "channel prefixes, generic labels, You, and case-duplicates should drop out"
        )
    }

    runSuite("RecentMeetingSpeakerStatus.speakerNames reads Obsidian wiki-link labels") {
        let markdown = """
        ## Full Transcript

        [00:01] [Mic/You] Morning.

        [00:04] [System/[[José Núñez]]] Hi all.

        [00:09] [System/Speaker 3] Can you hear me?
        """
        let labels = RecentMeetingSpeakerStatus.transcriptSpeakerLabels(in: markdown)
        assertEqual(
            RecentMeetingSpeakerStatus.speakerNames(fromLabels: labels),
            ["José Núñez"],
            "wiki-linked names should be searchable without the brackets"
        )
        assertEqual(
            RecentMeetingSpeakerStatus.detect(speakerLabels: labels),
            RecentMeetingSpeakerStatus.detect(in: markdown),
            "the label-based detect must agree with the markdown one"
        )
    }

    runSuite("HomeMeetingListFilter.searchFields includes speaker names") {
        var item = searchIndexSampleItem(title: "Weekly sync", path: "/tmp/a.md")
        item.speakerNames = ["Priya Shah"]
        let fields = HomeMeetingListFilter.searchFields(for: item)
        assertTrue(fields.contains("Priya Shah"), "speaker names should be searchable")
        assertTrue(
            HomeMeetingListFilter.matches(query: "priya sync", in: fields),
            "tokens may match across title and speaker fields"
        )
    }

    runSuite("Pre-speaker-name cache payloads require reparsing") {
        let payload = CachedRecentMeetingMetadata(
            title: "Old row",
            displayDate: Date(timeIntervalSinceReferenceDate: 0),
            startDate: nil,
            endDate: nil,
            speakerNeedsReviewCount: nil,
            hasAudioHealth: false,
            audioHealthMicBoostOutcome: nil
        )
        guard let encoded = try? JSONEncoder().encode(payload),
              var object = (try? JSONSerialization.jsonObject(with: encoded)) as? [String: Any] else {
            assertTrue(false, "payload should encode")
            return
        }
        object.removeValue(forKey: "speakerNames")
        let legacy = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        assertNil(
            try? JSONDecoder().decode(CachedRecentMeetingMetadata.self, from: legacy),
            "a cached row without speaker names must miss so the meeting is reparsed"
        )
    }

    runSuite("HomeMeetingSearchIndex.search pages newest-first matches") {
        let scanned = (0..<5).map { index in
            RecentMeetingIndexEntry(
                path: "/tmp/meeting-\(index).md",
                stamp: RecentMeetingCacheStamp(transcriptModified: Double(index), transcriptSize: 1),
                item: searchIndexSampleItem(
                    title: index.isMultiple(of: 2) ? "Budget review \(index)" : "Standup \(index)",
                    path: "/tmp/meeting-\(index).md",
                    date: Date(timeIntervalSinceReferenceDate: Double(100 - index))
                )
            )
        }
        let index = HomeMeetingSearchIndex(scanned: scanned)

        let firstPage = index.search(query: "budget", limit: 2)
        assertEqual(firstPage.items.map(\.title), ["Budget review 0", "Budget review 2"], "first page keeps scan order")
        assertTrue(firstPage.hasMore, "a third match should report more")

        let everything = index.search(query: "budget", limit: 10)
        assertEqual(everything.items.count, 3, "all matches fit in a bigger page")
        assertFalse(everything.hasMore, "no more once every match is returned")

        let exact = index.search(query: "budget", limit: 3)
        assertFalse(exact.hasMore, "a page that exactly fits the matches has no more")

        assertTrue(index.search(query: "   ", limit: 10).items.isEmpty, "blank query matches nothing")
        assertTrue(index.search(query: "budget", limit: 0).items.isEmpty, "zero limit returns nothing")
    }

    runSuite("HomeMeetingSearchIndex reuses haystacks only on the same day") {
        let scannedEntry = RecentMeetingIndexEntry(
            path: "/tmp/day.md",
            stamp: RecentMeetingCacheStamp(transcriptModified: 1, transcriptSize: 1),
            item: searchIndexSampleItem(title: "Planning", path: "/tmp/day.md")
        )
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        let today = calendar.startOfDay(for: now)
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else {
            assertTrue(false, "calendar math should work")
            return
        }
        // A marker haystack stands in for date words baked in on an earlier day.
        let marker = HomeMeetingSearchIndex.Entry(scanned: scannedEntry, haystack: "stale-marker")

        let sameDay = HomeMeetingSearchIndex(entries: [marker], day: today)
        let rebuiltSameDay = HomeMeetingSearchIndex(scanned: [scannedEntry], previous: sameDay, now: now, calendar: calendar)
        assertEqual(rebuiltSameDay.search(query: "stale-marker", limit: 5).items.count, 1, "same-day rebuild reuses the haystack")

        let dayOld = HomeMeetingSearchIndex(entries: [marker], day: yesterday)
        assertFalse(dayOld.isCurrent(now: now, calendar: calendar), "an index from yesterday is not current")
        let rebuiltNextDay = HomeMeetingSearchIndex(scanned: [scannedEntry], previous: dayOld, now: now, calendar: calendar)
        assertTrue(rebuiltNextDay.isCurrent(now: now, calendar: calendar), "the rebuilt index is current")
        assertTrue(rebuiltNextDay.search(query: "stale-marker", limit: 5).items.isEmpty, "a new day recomputes haystacks")
        assertEqual(rebuiltNextDay.search(query: "planning", limit: 5).items.count, 1, "fresh haystack still finds the title")
    }

    runSuite("RecentMeetingMetadataCache batch store and allRows round-trip stamped rows") {
        let cache = RecentMeetingMetadataCache(databaseURL: nil)
        var payload = CachedRecentMeetingMetadata(
            title: "Row",
            displayDate: Date(timeIntervalSinceReferenceDate: 0),
            startDate: nil,
            endDate: nil,
            speakerNeedsReviewCount: nil,
            hasAudioHealth: false,
            audioHealthMicBoostOutcome: nil
        )
        payload.speakerNames = ["Dana"]
        let stamp = RecentMeetingCacheStamp(transcriptModified: 7, transcriptSize: 42)
        cache.store(path: "/tmp/row.md", stamp: stamp, metadata: payload)
        cache.store([
            (path: "/tmp/batch-a.md", stamp: stamp, metadata: payload),
            (path: "/tmp/batch-b.md", stamp: stamp, metadata: payload)
        ])
        let rows = cache.allRows()
        assertEqual(rows.count, 3, "single and batched rows all come back")
        assertNotNil(cache.lookup(path: "/tmp/batch-b.md", stamp: stamp), "batched rows are visible to lookup")
        assertEqual(rows["/tmp/row.md"]?.stamp, stamp, "the stored stamp comes back")
        assertEqual(rows["/tmp/row.md"]?.metadata.speakerNames, ["Dana"], "the payload decodes")
    }

    runSuite("HomeMeetingSearchIndex.removeMeeting drops a deleted row") {
        let scanned = [
            RecentMeetingIndexEntry(
                path: "/tmp/keep.md",
                stamp: RecentMeetingCacheStamp(transcriptModified: 1, transcriptSize: 1),
                item: searchIndexSampleItem(title: "Retro keep", path: "/tmp/keep.md")
            ),
            RecentMeetingIndexEntry(
                path: "/tmp/gone.md",
                stamp: RecentMeetingCacheStamp(transcriptModified: 1, transcriptSize: 1),
                item: searchIndexSampleItem(title: "Retro gone", path: "/tmp/gone.md")
            )
        ]
        var index = HomeMeetingSearchIndex(scanned: scanned)
        index.removeMeeting(id: "/tmp/gone.md")
        assertEqual(index.search(query: "retro", limit: 10).items.map(\.title), ["Retro keep"])
    }

    await runSuite("loadSearchIndex finds meetings past the Home slice, by speaker name") {
        await withSearchIndexMeetingsFolder { folder in
            for number in 0..<25 {
                try? writeSearchIndexMeeting(
                    title: "Meeting \(number)",
                    minutesAgo: number,
                    speaker: number == 24 ? "Marguerite Okafor" : "Speaker 1",
                    to: folder.appendingPathComponent(String(format: "m%02d.md", number))
                )
            }
            let cache = RecentMeetingMetadataCache(databaseURL: nil)

            let recent = RecentMeetingsScanner.loadRecent(limit: 10, directory: folder, cache: cache)
            assertFalse(recent.contains { $0.title == "Meeting 24" }, "the oldest meeting is outside the loaded slice")

            guard let scanned = RecentMeetingsScanner.loadSearchIndex(directory: folder, cache: cache) else {
                assertTrue(false, "index build should not report cancellation")
                return
            }
            assertEqual(scanned.count, 25, "the index covers every saved meeting")
            assertEqual(scanned.first?.item.title, "Meeting 0", "newest first")
            assertTrue(scanned.allSatisfy { $0.item.audio == nil }, "the index skips audio probes")

            let index = HomeMeetingSearchIndex(scanned: scanned)
            let byName = index.search(query: "okafor", limit: 50)
            assertEqual(byName.items.map(\.title), ["Meeting 24"], "a speaker name finds the old meeting")
            assertEqual(byName.items.first?.speakerNames, ["Marguerite Okafor"], "speaker names ride on the row")
            assertEqual(
                index.search(query: "speaker", limit: 50).items.count,
                0,
                "generic speaker labels are not searchable"
            )
        }
    }

    await runSuite("loadSearchIndex reuses cached and previous rows without reading transcripts") {
        await withSearchIndexMeetingsFolder { folder in
            let url = folder.appendingPathComponent("cached.md")
            try? writeSearchIndexMeeting(title: "Cached planning", minutesAgo: 1, speaker: "Dana", to: url)
            let cache = RecentMeetingMetadataCache(databaseURL: nil)

            let cold = RecentMeetingsScanner.loadSearchIndex(directory: folder, cache: cache) ?? []
            assertEqual(cold.map(\.item.speakerNames), [["Dana"]], "cold build parses speaker names")

            // Any path that opens the file for reading now fails; stat still works.
            try? FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }

            let control = RecentMeetingsScanner.loadSearchIndex(
                directory: folder,
                cache: RecentMeetingMetadataCache(databaseURL: nil)
            ) ?? []
            assertTrue(control.isEmpty, "an unreadable transcript yields no row without a warm cache")

            let fromCache = RecentMeetingsScanner.loadSearchIndex(directory: folder, cache: cache) ?? []
            assertEqual(fromCache.map(\.item.title), ["Cached planning"], "the SQLite cache serves the row")
            assertEqual(fromCache.map(\.item.speakerNames), [["Dana"]], "speaker names survive the cache")

            let previous = Dictionary(uniqueKeysWithValues: cold.map { ($0.path, $0) })
            let fromPrevious = RecentMeetingsScanner.loadSearchIndex(
                directory: folder,
                cache: nil,
                previous: previous
            ) ?? []
            assertEqual(fromPrevious.map(\.item.title), ["Cached planning"], "the previous index serves the row with no cache")
        }
    }

    await runSuite("Today metadata keeps recording facts without populating a partial speaker-search cache") {
        await withSearchIndexMeetingsFolder { folder in
            let url = folder.appendingPathComponent("long.md")
            try? writeSearchIndexMeeting(title: "Résumé planning", minutesAgo: 30, speaker: "Speaker 2", to: url)
            let original = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let long = original + String(repeating: "\nA long transcript paragraph.\n", count: 3_000)
                + "\n[59:59] [System/José Núñez] Late speaker.\n"
            try? long.write(to: url, atomically: true, encoding: .utf8)
            let cache = RecentMeetingMetadataCache(databaseURL: nil)
            let summary = RecentMeetingsScanner.loadTodayIndex(directory: folder, cache: cache) ?? []
            assertEqual(summary.count, 1)
            assertEqual(summary.first?.item.title, "Résumé planning")
            assertTrue(summary.first?.item.speakerNames.isEmpty == true, "Today does not traverse the transcript for names")
            guard let entry = summary.first else { return }
            assertNil(cache.lookup(path: entry.path, stamp: entry.stamp), "partial summaries cannot masquerade as search rows")

            let full = RecentMeetingsScanner.loadSearchIndex(directory: folder, cache: cache) ?? []
            assertEqual(full.first?.item.speakerNames, ["José Núñez"], "Home still reads named speakers beyond the preview limit")
            assertEqual(full.first?.item.title, entry.item.title)
            assertEqual(full.first?.item.date, entry.item.date)
            assertEqual(full.first?.item.startDate, entry.item.startDate)
            assertEqual(full.first?.item.endDate, entry.item.endDate)
            assertEqual(full.first?.item.transcriptURL, entry.item.transcriptURL)
            let index = HomeMeetingSearchIndex(scanned: full)
            assertEqual(index.search(query: "resume JOSE nunez", limit: 50).items.count, 1,
                        "case, diacritic, and cross-field token semantics remain intact")

            let warm = RecentMeetingsScanner.loadTodayIndex(directory: folder, cache: cache) ?? []
            assertEqual(warm.first?.item.date, entry.item.date, "full-cache reuse preserves Today recording time")
        }
    }

    await runSuite("Today metadata retains old latest meetings and reconciles changed or removed files") {
        await withSearchIndexMeetingsFolder { folder in
            let older = folder.appendingPathComponent("old.md")
            let newer = folder.appendingPathComponent("new.md")
            try? writeSearchIndexMeeting(title: "Older", minutesAgo: 100_000, speaker: "Dana", to: older)
            try? writeSearchIndexMeeting(title: "Latest", minutesAgo: 50_000, speaker: "Casey", to: newer)
            let first = RecentMeetingsScanner.loadTodayIndex(directory: folder, cache: nil) ?? []
            assertEqual(first.map(\.item.title), ["Latest", "Older"], "old captures remain available to the return signal")
            let previous = Dictionary(uniqueKeysWithValues: first.map { ($0.path, $0) })
            try? writeSearchIndexMeeting(title: "Changed latest title", minutesAgo: 1, speaker: "Casey", to: newer)
            try? FileManager.default.removeItem(at: older)
            let second = RecentMeetingsScanner.loadTodayIndex(directory: folder, cache: nil, previous: previous) ?? []
            assertEqual(second.map(\.item.title), ["Changed latest title"], "reveal cannot reuse a deleted or changed row")
            assertTrue((second.first?.item.date ?? .distantPast) > (first.first?.item.date ?? .distantPast))
        }
    }


    await runSuite("Today preview preserves fallback titles for legacy untitled meetings") {
        await withSearchIndexMeetingsFolder { folder in
            let url = folder.appendingPathComponent("legacy.md")
            try? writeSearchIndexMeeting(title: "Temporary title", minutesAgo: 5, speaker: "Dana", to: url)
            let text = ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
                .replacingOccurrences(of: "title: \"Temporary title\"", with: "title: \"   \"")
            try? text.write(to: url, atomically: true, encoding: .utf8)
            let today = RecentMeetingsScanner.loadTodayIndex(directory: folder, cache: nil) ?? []
            let full = RecentMeetingsScanner.loadSearchIndex(directory: folder, cache: nil) ?? []
            assertEqual(today.first?.item.title, "Meeting with Dana", "no explicit title still uses the preview's speaker-derived fallback")
            assertEqual(today.first?.item.title, full.first?.item.title)
        }
    }

}

private func searchIndexSampleItem(
    title: String,
    path: String,
    date: Date = Date(timeIntervalSinceReferenceDate: 10)
) -> RecentMeetingItem {
    RecentMeetingItem(
        title: title,
        date: date,
        startDate: nil,
        endDate: nil,
        transcriptURL: URL(fileURLWithPath: path),
        audio: nil,
        speakerStatus: .ready
    )
}

private func withSearchIndexMeetingsFolder(_ body: (URL) async -> Void) async {
    let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent("build/home-meeting-search-index-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    await body(folder)
}

private func writeSearchIndexMeeting(title: String, minutesAgo: Int, speaker: String, to url: URL) throws {
    let date = Date(timeIntervalSince1970: 1_780_000_000 - Double(minutesAgo * 60))
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    let day = formatter.string(from: date)
    formatter.dateFormat = "HH:mm:ss"
    let time = formatter.string(from: date)
    let markdown = """
    ---
    title: "\(title)"
    capture_type: meeting
    date: "\(day)"
    time: "\(time)"
    duration: "10:00"
    ---

    # \(title)

    ## Full Transcript

    [00:01] [Mic/You] Morning.

    [00:04] [System/\(speaker)] Hello there.
    """
    try markdown.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.creationDate: date, .modificationDate: date],
        ofItemAtPath: url.path
    )
}
