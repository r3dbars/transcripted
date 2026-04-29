// DictationTranscriptStoreTests.swift
// Tests for newest-saved-dictation lookup.

import Foundation

func testDictationTranscriptStore() {
    runSuite("DictationTranscriptStore.latestSavedText — returns the newest saved dictation across days") {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("DraftDictationStoreTests-\(UUID().uuidString)", isDirectory: true)
        let outputDir = tempRoot.appendingPathComponent("dictations", isDirectory: true)
        try? fm.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        _ = try? DictationTranscriptStore.save(
            text: "older saved dictation",
            sourceApp: nil,
            delivery: .pasted,
            createdAt: isoDate("2026-04-07T09:15:00-0500"),
            directory: outputDir
        )
        _ = try? DictationTranscriptStore.save(
            text: "newest saved dictation",
            sourceApp: nil,
            delivery: .copied,
            createdAt: isoDate("2026-04-08T08:30:00-0500"),
            directory: outputDir
        )

        let latest = DictationTranscriptStore.latestSavedDictation(directory: outputDir)

        assertEqual(latest?.text, "newest saved dictation", "latest saved dictation text")
        assertEqual(latest?.delivery, .copied, "latest saved dictation delivery")
        assertEqual(latest?.url.lastPathComponent, "Dictations_2026-04-08.md", "latest saved dictation file")
        assertEqual(DictationTranscriptStore.latestSavedText(directory: outputDir), "newest saved dictation", "text-only helper")
    }

    runSuite("DictationTranscriptStore.latestSavedText — reads older Timestamp metadata too") {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("DraftDictationStoreTests-\(UUID().uuidString)", isDirectory: true)
        let outputDir = tempRoot.appendingPathComponent("dictations", isDirectory: true)
        try? fm.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let legacyFile = outputDir.appendingPathComponent("Dictations_2026-04-09.md")
        let legacyMarkdown = """
        ---
        title: "Dictations for April 9, 2026"
        date: 2026-04-09
        capture_type: dictation_day
        ---

        # Dictations for April 9, 2026

        ## 10:05 AM - Legacy entry

        Entry ID: `dictation-legacy`
        Timestamp: 2026-04-09T10:05:00Z
        Source app: Notes
        Delivery: failed
        Words: 2
        Characters: 11

        legacy text
        """
        try? legacyMarkdown.write(to: legacyFile, atomically: true, encoding: .utf8)

        let latest = DictationTranscriptStore.latestSavedDictation(directory: outputDir)
        assertEqual(latest?.text, "legacy text", "legacy dictation text")
        assertEqual(latest?.entryID, "dictation-legacy", "legacy dictation entry ID")
    }

    runSuite("DictationTranscriptStore.recentSavedDictations — returns the newest entries across day files and same-day sections") {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("DraftDictationStoreTests-\(UUID().uuidString)", isDirectory: true)
        let outputDir = tempRoot.appendingPathComponent("dictations", isDirectory: true)
        try? fm.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        _ = try? DictationTranscriptStore.save(
            text: "older notes entry",
            sourceApp: nil,
            delivery: .copied,
            createdAt: isoDate("2026-04-06T09:00:00-0500"),
            directory: outputDir
        )
        _ = try? DictationTranscriptStore.save(
            text: "same day first entry",
            sourceApp: nil,
            delivery: .pasted,
            createdAt: isoDate("2026-04-08T08:30:00-0500"),
            directory: outputDir
        )
        _ = try? DictationTranscriptStore.save(
            text: "same day newest entry",
            sourceApp: nil,
            delivery: .failed,
            createdAt: isoDate("2026-04-08T09:15:00-0500"),
            directory: outputDir
        )
        _ = try? DictationTranscriptStore.save(
            text: "latest day entry",
            sourceApp: nil,
            delivery: .copied,
            createdAt: isoDate("2026-04-09T07:45:00-0500"),
            directory: outputDir
        )

        let recent = DictationTranscriptStore.recentSavedDictations(limit: 3, directory: outputDir)

        assertEqual(recent.count, 3, "recent dictation count")
        assertEqual(recent[0].text, "latest day entry", "first recent dictation")
        assertEqual(recent[1].text, "same day newest entry", "second recent dictation")
        assertEqual(recent[2].text, "same day first entry", "third recent dictation")
        assertEqual(recent[1].url.lastPathComponent, "Dictations_2026-04-08.md", "same-day dictations reuse the day file")
    }

    runSuite("DictationTranscriptStore.latestSavedText — preserves markdown headings inside dictation body") {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("DraftDictationStoreTests-\(UUID().uuidString)", isDirectory: true)
        let outputDir = tempRoot.appendingPathComponent("dictations", isDirectory: true)
        try? fm.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let text = """
        Start with this.
        ## Follow-up heading
        Keep this line too.
        """

        _ = try? DictationTranscriptStore.save(
            text: text,
            sourceApp: nil,
            delivery: .pasted,
            createdAt: isoDate("2026-04-10T11:20:00-0500"),
            directory: outputDir
        )

        assertEqual(
            DictationTranscriptStore.latestSavedText(directory: outputDir),
            text,
            "body headings should not split one saved dictation into multiple entries"
        )
    }

    runSuite("DictationTranscriptStore.savedDictationCounts — totals entries and dictated words") {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("DraftDictationStoreTests-\(UUID().uuidString)", isDirectory: true)
        let outputDir = tempRoot.appendingPathComponent("dictations", isDirectory: true)
        try? fm.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let today = isoDate("2026-04-11T12:00:00-0500")
        _ = try? DictationTranscriptStore.save(
            text: "one two three",
            sourceApp: nil,
            delivery: .pasted,
            createdAt: isoDate("2026-04-10T11:20:00-0500"),
            directory: outputDir
        )
        _ = try? DictationTranscriptStore.save(
            text: "four five",
            sourceApp: nil,
            delivery: .pasted,
            createdAt: today,
            directory: outputDir
        )

        let counts = DictationTranscriptStore.savedDictationCounts(directory: outputDir, today: today)

        assertEqual(counts.total, 2, "total dictation count")
        assertEqual(counts.today, 1, "today dictation count")
        assertEqual(counts.totalWords, 5, "total dictated word count")
    }

    runSuite("DictationTranscriptStore.deleteEntry — removes only the matching entry ID") {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("DraftDictationStoreTests-\(UUID().uuidString)", isDirectory: true)
        let outputDir = tempRoot.appendingPathComponent("dictations", isDirectory: true)
        try? fm.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let dayFile = outputDir.appendingPathComponent("Dictations_2026-04-12.md")
        let markdown = """
        ---
        title: "Dictations for April 12, 2026"
        date: 2026-04-12
        capture_type: dictation_day
        ---

        # Dictations for April 12, 2026

        ## 10:05 AM - First duplicate timestamp

        Entry ID: `dictation-first`
        Captured: 2026-04-12T10:05:00Z
        Source app: Notes
        Delivery: pasted
        Words: 2
        Characters: 11

        first text

        ## 10:05 AM - Second duplicate timestamp

        Entry ID: `dictation-second`
        Captured: 2026-04-12T10:05:00Z
        Source app: Notes
        Delivery: pasted
        Words: 2
        Characters: 12

        second text
        """
        try? markdown.write(to: dayFile, atomically: true, encoding: .utf8)

        let entries = DictationTranscriptStore.recentSavedDictations(limit: 2, directory: outputDir)
        guard let second = entries.first(where: { $0.entryID == "dictation-second" }) else {
            assertionFailure("Expected second dictation entry")
            return
        }

        do {
            try DictationTranscriptStore.deleteEntry(second)
        } catch {
            assertionFailure("deleteEntry should not throw: \(error)")
        }

        let remainingContent = (try? String(contentsOf: dayFile, encoding: .utf8)) ?? ""
        assertTrue(remainingContent.contains("dictation-first"), "first entry ID remains")
        assertTrue(remainingContent.contains("first text"), "first entry body remains")
        assertFalse(remainingContent.contains("dictation-second"), "second entry ID removed")
        assertFalse(remainingContent.contains("second text"), "second entry body removed")
    }

    runSuite("DictationTranscriptStore.deleteEntry — same-timestamp saved entries keep distinct IDs") {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("DraftDictationStoreTests-\(UUID().uuidString)", isDirectory: true)
        let outputDir = tempRoot.appendingPathComponent("dictations", isDirectory: true)
        try? fm.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let createdAt = isoDate("2026-04-12T10:05:00Z")
        _ = try? DictationTranscriptWriter.save(
            text: "first saved text",
            sourceApp: nil,
            delivery: .pasted,
            createdAt: createdAt,
            directory: outputDir
        )
        _ = try? DictationTranscriptWriter.save(
            text: "second saved text",
            sourceApp: nil,
            delivery: .pasted,
            createdAt: createdAt,
            directory: outputDir
        )

        let entries = DictationTranscriptStore.recentSavedDictations(limit: 5, directory: outputDir)
        assertEqual(entries.count, 2, "both same-timestamp entries should be readable")
        let uniqueEntryIDs = Set(entries.compactMap(\.entryID))
        assertEqual(uniqueEntryIDs.count, 2, "same-timestamp saves should still get unique entry IDs")

        guard let second = entries.first(where: { $0.text == "second saved text" }) else {
            assertionFailure("Expected second saved dictation entry")
            return
        }

        do {
            try DictationTranscriptStore.deleteEntry(second)
        } catch {
            assertionFailure("deleteEntry should not throw for unique same-timestamp save: \(error)")
        }

        let remainingEntries = DictationTranscriptStore.recentSavedDictations(limit: 5, directory: outputDir)
        assertEqual(remainingEntries.count, 1, "deleting one same-timestamp entry should keep the other")
        assertEqual(remainingEntries.first?.text, "first saved text", "first same-timestamp entry should remain")
    }
}

private func isoDate(_ string: String) -> Date {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
    return formatter.date(from: string) ?? Date(timeIntervalSince1970: 0)
}
