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

        assertEqual(DictationTranscriptStore.latestSavedText(directory: outputDir), "legacy text", "legacy dictation text")
    }
}

private func isoDate(_ string: String) -> Date {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
    return formatter.date(from: string) ?? Date(timeIntervalSince1970: 0)
}
