// DictationAgentOutputTests.swift
// Tests for markdown-only dictation day captures.

import Foundation

func testDictationAgentOutput() {
    runSuite("DictationTranscriptWriter.save — writes markdown-only day captures") {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("DraftDictationAgentTests-\(UUID().uuidString)", isDirectory: true)
        let outputDir = tempRoot.appendingPathComponent("dictations", isDirectory: true)
        try? fm.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let createdAt = dictationISODate("2026-04-07T09:15:00-0500")
        let saved = try? DictationTranscriptWriter.save(
            text: "Ship the follow-up note to product today",
            sourceApp: nil,
            delivery: .copied,
            createdAt: createdAt,
            directory: outputDir
        )

        let markdownURL = outputDir.appendingPathComponent("Dictations_2026-04-07.md")
        assertEqual(saved?.url.path, markdownURL.path, "dictation save should report the markdown capture path")
        assertEqual(saved?.sidecarURL, nil, "dictation save should not report a JSON sidecar")

        guard
            let markdown = try? String(contentsOf: markdownURL, encoding: .utf8)
        else {
            assertTrue(false, "expected markdown dictation capture")
            return
        }

        assertTrue(markdown.contains("capture_type: dictation_day"), "frontmatter should label the capture type")
        assertTrue(markdown.contains("# Dictations for"), "markdown should include the day heading")
        assertTrue(markdown.contains("Entry ID: `dictation-"), "each dictation should receive a stable entry id")
        assertTrue(markdown.contains("Captured: 2026-04-07T14:15:00.000Z"), "captured timestamp should use ISO format")
        assertTrue(markdown.contains("Source app: Unknown"), "missing app should be encoded predictably")
        assertTrue(markdown.contains("Delivery: copied"), "delivery should use machine-readable enum values")
        assertTrue(markdown.contains("Words: 7"), "entry word count should be recorded")
        assertTrue(markdown.contains("Characters: 40"), "entry character count should be recorded")
        assertTrue(markdown.contains("Ship the follow-up note to product today"), "dictation text should be preserved")
    }

    runSuite("DictationTranscriptWriter.save — appends entries to the existing markdown day file") {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("DraftDictationAgentTests-\(UUID().uuidString)", isDirectory: true)
        let outputDir = tempRoot.appendingPathComponent("dictations", isDirectory: true)
        try? fm.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let morning = dictationISODate("2026-04-07T09:15:00-0500")
        let evening = dictationISODate("2026-04-07T18:30:00-0500")

        _ = try? DictationTranscriptWriter.save(
            text: "Morning dictation for triage",
            sourceApp: nil,
            delivery: .pasted,
            createdAt: morning,
            directory: outputDir
        )
        _ = try? DictationTranscriptWriter.save(
            text: "Evening dictation with more detail",
            sourceApp: nil,
            delivery: .failed,
            createdAt: evening,
            directory: outputDir
        )

        let markdownURL = outputDir.appendingPathComponent("Dictations_2026-04-07.md")
        guard
            let markdown = try? String(contentsOf: markdownURL, encoding: .utf8)
        else {
            assertTrue(false, "expected combined dictation markdown")
            return
        }

        let entryCount = markdown.components(separatedBy: "Entry ID: `dictation-").count - 1
        assertEqual(entryCount, 2, "same-day dictations should aggregate into one markdown day file")
        assertTrue(markdown.contains("Morning dictation for triage"), "first dictation should be preserved")
        assertTrue(markdown.contains("Evening dictation with more detail"), "second dictation should be preserved")

        let firstRange = markdown.range(of: "Morning dictation for triage")
        let secondRange = markdown.range(of: "Evening dictation with more detail")
        let firstStartsEarlier = (firstRange?.lowerBound ?? markdown.endIndex) < (secondRange?.lowerBound ?? markdown.startIndex)
        assertTrue(firstStartsEarlier, "entries should remain chronological")
    }
}

private func dictationISODate(_ string: String) -> Date {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
    return formatter.date(from: string) ?? Date(timeIntervalSince1970: 0)
}
