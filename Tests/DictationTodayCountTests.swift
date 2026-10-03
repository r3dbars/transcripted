// DictationTodayCountTests.swift
// Home's "N today" dictation count reads only today's day file, and gives the
// same number the full-library count does.

import Foundation

func testDictationTodayCount() async {
    await runSuite("RecentCaptureLoader todayOnly — same count as the full library, parsing only today's file") {
        await withTodayCountDirectory { dir in
            let today = todayCountNoon(year: 2026, month: 4, day: 11)
            for dayOffset in 1...4 {
                saveTodayCountDictation("older day \(dayOffset)", at: today.addingTimeInterval(Double(-dayOffset) * 86_400), in: dir)
            }
            for minute in 0..<3 {
                saveTodayCountDictation("today entry \(minute)", at: today.addingTimeInterval(Double(minute) * 60), in: dir)
            }
            try? "# Notes\n\n## 9:00 AM - not a day file\n".write(
                to: dir.appendingPathComponent("Notes.md"), atomically: true, encoding: .utf8
            )

            DictationTranscriptStore.resetSavedDictationCountsCacheForTesting()
            defer { DictationTranscriptStore.resetSavedDictationCountsCacheForTesting() }
            let todayOnly = await RecentCaptureLoader.load(
                dictationLimit: 0,
                meetingLimit: 0,
                dictationCountScope: .todayOnly,
                meetingDirectory: dir.appendingPathComponent("no-meetings", isDirectory: true),
                dictationDirectory: dir,
                today: today
            )
            let todayOnlyMisses = DictationTranscriptStore.savedDictationCountsCacheMissesForTesting()
            let full = DictationTranscriptStore.savedDictationCounts(directory: dir, today: today)

            assertEqual(todayOnly.todayDictationCount, 3, "today-only load counts today's entries")
            assertEqual(todayOnly.todayDictationCount, full.today, "today-only matches the full-library today count")
            assertEqual(full.total, 7, "fixture has every day's entries")
            assertEqual(todayOnlyMisses, 1, "today-only load parses only today's day file")
            assertEqual(todayOnly.dictationCounts.total, 0, "today-only load does not fill library totals")
            assertEqual(todayOnly.dictationCounts.totalWords, 0, "today-only load does not fill word totals")

            let fullLoad = await RecentCaptureLoader.load(
                dictationLimit: 0,
                meetingLimit: 0,
                includeDictationCounts: true,
                meetingDirectory: dir.appendingPathComponent("no-meetings", isDirectory: true),
                dictationDirectory: dir,
                today: today
            )
            assertNil(fullLoad.todayDictationCount, "full-library load leaves the today-only field unset")
            assertEqual(fullLoad.dictationCounts.today, 3, "full-library load still counts today")
            assertEqual(fullLoad.dictationCounts.total, 7, "full-library load still counts the whole library")
        }
    }

    runSuite("savedDictationCount(forDayOf:) — zero without today's file or folder") {
        withTodayCountDirectorySync { dir in
            let today = todayCountNoon(year: 2026, month: 4, day: 11)
            saveTodayCountDictation("yesterday", at: today.addingTimeInterval(-86_400), in: dir)
            assertEqual(DictationTranscriptStore.savedDictationCount(forDayOf: today, directory: dir), 0, "no file for today gives 0")

            saveTodayCountDictation("today", at: today, in: dir)
            assertEqual(DictationTranscriptStore.savedDictationCount(forDayOf: today, directory: dir), 1, "today's file is counted")

            try? FileManager.default.removeItem(at: DictationTranscriptWriter.dailyFileURL(for: today, in: dir))
            assertEqual(DictationTranscriptStore.savedDictationCount(forDayOf: today, directory: dir), 0, "deleted today's file gives 0")

            let missing = dir.appendingPathComponent("missing", isDirectory: true)
            assertEqual(DictationTranscriptStore.savedDictationCount(forDayOf: today, directory: missing), 0, "missing folder gives 0")
        }
    }

    runSuite("savedDictationCount(forDayOf:) — an upper-case .MD day file is not counted, as in the full scan") {
        withTodayCountDirectorySync { dir in
            let today = todayCountNoon(year: 2026, month: 4, day: 11)
            let canonical = DictationTranscriptWriter.dailyFileURL(for: today, in: dir)
            let upper = canonical.deletingPathExtension().appendingPathExtension("MD")
            try? todayCountDayFile(headings: ["## 9:00 AM - a"]).write(to: upper, atomically: true, encoding: .utf8)

            let full = DictationTranscriptStore.savedDictationCounts(directory: dir, today: today)
            assertEqual(full.today, 0, "full scan skips a non-.md day file")
            assertEqual(
                DictationTranscriptStore.savedDictationCount(forDayOf: today, directory: dir),
                full.today,
                "today-only count agrees on a case-insensitive volume"
            )
        }
    }

    runSuite("Entry headings — only lines that start with \"## <time> - \" count") {
        withTodayCountDirectorySync { dir in
            let today = todayCountNoon(year: 2026, month: 4, day: 11)
            let url = DictationTranscriptWriter.dailyFileURL(for: today, in: dir)
            let content = todayCountDayFile(headings: [
                "## 9:00 AM - a",
                "##x",
                "  ## 9:05 AM - indented",
                "#  9:10 AM - one hash",
                "## 10:15 PM - b",
            ])
            try? content.write(to: url, atomically: true, encoding: .utf8)

            let counts = DictationTranscriptStore.savedDictationCounts(directory: dir, today: today)
            assertEqual(counts.total, 2, "only real entry headings count")
            assertEqual(counts.totalWords, 4, "words come from real entries' metadata")
            assertEqual(DictationTranscriptStore.savedDictationCount(forDayOf: today, directory: dir), 2, "today-only agrees")
        }
    }

    runSuite("Saved dictation createdAt — exact millisecond, same as ISO8601DateFormatter") {
        withTodayCountDirectorySync { dir in
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]

            // Deterministic spread of whole milliseconds, 2000-2100, plus one
            // second's worth of every millisecond.
            var milliseconds: [Int64] = (0..<200).map { Int64(1_790_265_900_000) + Int64($0 * 5) }
            var seed: UInt64 = 0x5EED
            for _ in 0..<200 {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                milliseconds.append(Int64(946_684_800_000) + Int64(seed % 3_155_760_000_000))
            }

            let stamp = DateFormatter()
            stamp.locale = Locale(identifier: "en_US_POSIX")
            stamp.timeZone = TimeZone(identifier: "UTC")
            stamp.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            var captured: [String] = []
            for ms in milliseconds {
                let seconds = Date(timeIntervalSince1970: Double(ms / 1_000))
                captured.append(stamp.string(from: seconds) + String(format: ".%03dZ", Int(ms % 1_000)))
            }
            // Legacy and hand-edited forms.
            let extras = [
                "2026-09-24T16:05:00Z",
                "2026-09-24T11:05:00.387-05:00",
                "2026-09-24T21:35:00+05:30",
                "2026-09-24T16:05:00.9999Z",
                "2026-09-24T16:05:00.1Z",
            ]
            captured.append(contentsOf: extras)

            let url = dir.appendingPathComponent("Dictations_2026-09-24.md")
            var sections: [String] = []
            for (index, value) in captured.enumerated() {
                sections.append("""
                ## 9:00 AM - entry \(index)

                Entry ID: `id-\(index)`
                Captured: \(value)
                Source app: Notes
                Delivery: pasted
                Words: 1
                Characters: 4

                body
                """)
            }
            try? sections.joined(separator: "\n\n").write(to: url, atomically: true, encoding: .utf8)

            let entries = DictationTranscriptStore.recentSavedDictations(limit: captured.count + 10, directory: dir)
            assertEqual(entries.count, captured.count, "every fixture entry parses")
            var byID: [String: Date] = [:]
            for entry in entries {
                if let id = entry.entryID { byID[id] = entry.createdAt }
            }
            var mismatches = 0
            for (index, value) in captured.enumerated() {
                let expected = fractional.date(from: value) ?? plain.date(from: value)
                if byID["id-\(index)"] != expected { mismatches += 1 }
                if index < milliseconds.count,
                   byID["id-\(index)"] != Date(timeIntervalSince1970: Double(milliseconds[index]) / 1_000) {
                    mismatches += 1
                }
            }
            assertEqual(mismatches, 0, "createdAt is bit-identical to the previous parser and the saved millisecond")
        }
    }

    runSuite("Saved dictation createdAt — an out-of-format value falls back to the file date") {
        withTodayCountDirectorySync { dir in
            let url = dir.appendingPathComponent("Dictations_2026-09-24.md")
            try? """
            ## 9:00 AM - spaced

            Entry ID: `spaced`
            Captured: 2026-09-24 16:05:00.387Z
            Source app: Notes
            Delivery: pasted
            Words: 1

            body
            """.write(to: url, atomically: true, encoding: .utf8)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let entry = DictationTranscriptStore.recentSavedDictations(limit: 1, directory: dir).first
            assertEqual(entry?.createdAt, modified, "unparseable Captured falls back to the file's modification date")
        }
    }
}

private func todayCountNoon(year: Int, month: Int, day: Int) -> Date {
    Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? Date(timeIntervalSince1970: 0)
}

private func saveTodayCountDictation(_ text: String, at date: Date, in dir: URL) {
    _ = try? DictationTranscriptStore.save(
        text: text,
        sourceApp: nil,
        delivery: .pasted,
        createdAt: date,
        directory: dir
    )
}

private func todayCountDayFile(headings: [String]) -> String {
    let sections = headings.map { heading in
        """
        \(heading)

        Source app: Notes
        Delivery: pasted
        Words: 2

        two words
        """
    }
    return "# Dictations\n\n" + sections.joined(separator: "\n\n") + "\n"
}

private func makeTodayCountDirectory() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("TranscriptedDictationTodayCountTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func withTodayCountDirectorySync(_ body: (URL) -> Void) {
    let dir = makeTodayCountDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    body(dir)
}

private func withTodayCountDirectory(_ body: (URL) async -> Void) async {
    let dir = makeTodayCountDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    await body(dir)
}
