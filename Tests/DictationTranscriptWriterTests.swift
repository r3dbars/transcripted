// DictationTranscriptWriterTests.swift
// Tests for daily dictation markdown aggregation.

import Foundation

func testDictationTranscriptWriter() {
    runSuite("DictationTranscriptWriter.save — groups dictations by day") {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("DraftDictationTests-\(UUID().uuidString)", isDirectory: true)
        let outputDir = tempRoot.appendingPathComponent("dictations", isDirectory: true)
        try? fm.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let firstDate = isoDate("2026-04-07T09:15:00-0500")
        let secondDate = isoDate("2026-04-07T16:45:00-0500")

        let firstSaved = try? DictationTranscriptWriter.save(
            text: "first note from the morning",
            sourceApp: nil,
            delivery: .pasted,
            createdAt: firstDate,
            directory: outputDir
        )
        let secondSaved = try? DictationTranscriptWriter.save(
            text: "second note from the afternoon",
            sourceApp: nil,
            delivery: .copied,
            createdAt: secondDate,
            directory: outputDir
        )

        let expectedURL = outputDir.appendingPathComponent("Dictations_2026-04-07.md")
        assertEqual(firstSaved?.url.path, expectedURL.path, "first dictation should use daily filename")
        assertEqual(secondSaved?.url.path, expectedURL.path, "second dictation should append to same daily file")

        let contents = (try? String(contentsOf: expectedURL, encoding: .utf8)) ?? ""
        assertTrue(contents.contains("# Dictations for"), "daily file should include a single day header")
        assertTrue(contents.contains("## 9:15 AM -"), "first dictation section should include time heading")
        assertTrue(contents.contains("## 4:45 PM -"), "second dictation section should include time heading")
        assertTrue(contents.contains("first note from the morning"), "first dictation text should be present")
        assertTrue(contents.contains("second note from the afternoon"), "second dictation text should be present")
    }

    runSuite("DictationTranscriptWriter.save — separates different days") {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("DraftDictationTests-\(UUID().uuidString)", isDirectory: true)
        let outputDir = tempRoot.appendingPathComponent("dictations", isDirectory: true)
        try? fm.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let firstDate = isoDate("2026-04-07T23:15:00-0500")
        let secondDate = isoDate("2026-04-08T00:05:00-0500")

        let firstSaved = try? DictationTranscriptWriter.save(
            text: "late night dictation",
            sourceApp: nil,
            delivery: .pasted,
            createdAt: firstDate,
            directory: outputDir
        )
        let secondSaved = try? DictationTranscriptWriter.save(
            text: "after midnight dictation",
            sourceApp: nil,
            delivery: .pasted,
            createdAt: secondDate,
            directory: outputDir
        )

        assertTrue(firstSaved?.url.lastPathComponent == "Dictations_2026-04-07.md", "first day filename")
        assertTrue(secondSaved?.url.lastPathComponent == "Dictations_2026-04-08.md", "second day filename")
    }
}

private func isoDate(_ string: String) -> Date {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
    return formatter.date(from: string) ?? Date(timeIntervalSince1970: 0)
}
