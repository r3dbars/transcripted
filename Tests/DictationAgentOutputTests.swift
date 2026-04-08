// DictationAgentOutputTests.swift
// Tests for machine-readable dictation sidecars.

import Foundation

func testDictationAgentOutput() {
    runSuite("DictationTranscriptWriter.save — writes JSON sidecar for agent use") {
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

        let sidecarURL = outputDir.appendingPathComponent("Dictations_2026-04-07.json")
        assertEqual(saved?.sidecarURL?.path, sidecarURL.path, "dictation save should report the sidecar path")

        guard
            let data = try? Data(contentsOf: sidecarURL),
            let payload = try? JSONDecoder().decode(AgentDictationDay.self, from: data)
        else {
            assertTrue(false, "expected decodable dictation agent sidecar")
            return
        }

        assertEqual(payload.captureType, "dictation_day", "sidecar capture type")
        assertEqual(payload.markdownFilename, "Dictations_2026-04-07.md", "sidecar should point at matching markdown file")
        assertEqual(payload.entryCount, 1, "single dictation should produce one entry")
        assertEqual(payload.entries.first?.delivery, "copied", "delivery should use machine-readable enum values")
        assertEqual(payload.entries.first?.sourceAppName, "Unknown", "missing app should be encoded predictably")
        assertEqual(payload.entries.first?.wordCount, 7, "entry word count")
        assertTrue(payload.entries.first?.id.hasPrefix("dictation-") == true, "entry id should be stable and namespaced")
    }

    runSuite("DictationTranscriptWriter.save — appends entries to existing JSON sidecar") {
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

        let sidecarURL = outputDir.appendingPathComponent("Dictations_2026-04-07.json")
        guard
            let data = try? Data(contentsOf: sidecarURL),
            let payload = try? JSONDecoder().decode(AgentDictationDay.self, from: data)
        else {
            assertTrue(false, "expected combined dictation sidecar")
            return
        }

        assertEqual(payload.entryCount, 2, "same-day dictations should aggregate")
        assertEqual(payload.entries.count, 2, "entry array should include both dictations")
        assertTrue(payload.entries[0].createdAt < payload.entries[1].createdAt, "entries should be chronological")
        assertEqual(payload.wordCount, payload.entries.reduce(0) { $0 + $1.wordCount }, "top-level word count should roll up entries")
    }
}

private func dictationISODate(_ string: String) -> Date {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
    return formatter.date(from: string) ?? Date(timeIntervalSince1970: 0)
}
