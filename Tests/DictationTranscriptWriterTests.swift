// DictationTranscriptWriterTests.swift
// Tests for daily dictation markdown aggregation.

import Foundation

func testDictationTranscriptWriter() {
    runSuite("DictationTranscriptWriter.save — groups dictations by day") {
        let fm = FileManager.default
        let tempRoot = temporaryDictationWriterTestRoot(fileManager: fm)
        let outputDir = tempRoot.appendingPathComponent("dictations", isDirectory: true)
        try? fm.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let firstDate = localDate(year: 2026, month: 4, day: 7, hour: 9, minute: 15)
        let secondDate = localDate(year: 2026, month: 4, day: 7, hour: 16, minute: 45)

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

    runSuite("DictationTranscriptWriter.save — keeps daily markdown owner-only") {
        let fm = FileManager.default
        let tempRoot = temporaryDictationWriterTestRoot(fileManager: fm)
        let outputDir = tempRoot.appendingPathComponent("dictations", isDirectory: true)
        try? fm.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let createdAt = localDate(year: 2026, month: 4, day: 7, hour: 9, minute: 15)
        let saved = try? DictationTranscriptWriter.save(
            text: "private dictation artifact",
            sourceApp: nil,
            delivery: .pasted,
            createdAt: createdAt,
            directory: outputDir
        )

        guard let dayFile = saved?.url else {
            assertionFailure("Expected dictation transcript file")
            return
        }

        assertEqual(
            dictationWriterFilePermissions(of: dayFile),
            NSNumber(value: 0o600),
            "new dictation markdown should be restricted to the owner"
        )

        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dayFile.path)
        _ = try? DictationTranscriptWriter.save(
            text: "second private dictation artifact",
            sourceApp: nil,
            delivery: .copied,
            createdAt: localDate(year: 2026, month: 4, day: 7, hour: 16, minute: 45),
            directory: outputDir
        )

        assertEqual(
            dictationWriterFilePermissions(of: dayFile),
            NSNumber(value: 0o600),
            "append path should restore owner-only permissions"
        )
    }

    runSuite("DictationTranscriptWriter.save — a failed append leaves the existing day intact") {
        let fm = FileManager.default
        let tempRoot = temporaryDictationWriterTestRoot(fileManager: fm)
        let outputDir = tempRoot.appendingPathComponent("dictations", isDirectory: true)
        try? fm.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: outputDir.path)
            try? fm.removeItem(at: tempRoot)
        }

        let firstDate = localDate(year: 2026, month: 4, day: 7, hour: 9, minute: 15)
        let firstSaved = try? DictationTranscriptWriter.save(
            text: "first note that must survive a crash",
            sourceApp: nil,
            delivery: .pasted,
            createdAt: firstDate,
            directory: outputDir
        )

        guard let dayFile = firstSaved?.url else {
            assertionFailure("Expected first dictation to save")
            return
        }

        let before = (try? String(contentsOf: dayFile, encoding: .utf8)) ?? ""
        assertTrue(before.contains("first note that must survive a crash"), "first dictation should be on disk")

        // Simulate an interrupted/failed write: make the day folder read-only so the atomic
        // write (write-temp-then-rename) cannot create its temp file and throws mid-append.
        try? fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: outputDir.path)

        let secondSaved = try? DictationTranscriptWriter.save(
            text: "second note from a doomed write",
            sourceApp: nil,
            delivery: .copied,
            createdAt: localDate(year: 2026, month: 4, day: 7, hour: 16, minute: 45),
            directory: outputDir
        )
        assertTrue(secondSaved == nil, "append into a read-only folder should fail rather than succeed")

        // Restore access and confirm the original day file is byte-for-byte intact: the
        // failed second write must not have truncated, partially overwritten, or appended
        // garbage to the existing entries.
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: outputDir.path)

        let after = (try? String(contentsOf: dayFile, encoding: .utf8)) ?? ""
        assertEqual(after, before, "existing day file must be unchanged after a failed append")
        assertTrue(after.contains("first note that must survive a crash"), "first dictation must survive")
        assertTrue(!after.contains("second note from a doomed write"), "no partial second entry should leak in")
    }

    runSuite("DictationTranscriptWriter.save — separates different days") {
        let fm = FileManager.default
        let tempRoot = temporaryDictationWriterTestRoot(fileManager: fm)
        let outputDir = tempRoot.appendingPathComponent("dictations", isDirectory: true)
        try? fm.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let firstDate = localDate(year: 2026, month: 4, day: 7, hour: 23, minute: 15)
        let secondDate = localDate(year: 2026, month: 4, day: 8, hour: 0, minute: 5)

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

private func temporaryDictationWriterTestRoot(fileManager: FileManager) -> URL {
    fileManager.temporaryDirectory.appendingPathComponent(
        "TranscriptedDictationWriterTests-\(UUID().uuidString)",
        isDirectory: true
    )
}

private func dictationWriterFilePermissions(of url: URL) -> NSNumber? {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return attributes?[.posixPermissions] as? NSNumber
}

// Build the instant for the given wall-clock time in the machine's *local* timezone.
// DictationTranscriptWriter groups day files and renders section times in the local
// zone, so anchoring the inputs to local time keeps these assertions deterministic on
// any machine instead of only passing where the local zone matches a hard-coded offset.
private func localDate(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let components = DateComponents(
        calendar: calendar,
        year: year,
        month: month,
        day: day,
        hour: hour,
        minute: minute,
        second: 0
    )
    return components.date ?? Date(timeIntervalSince1970: 0)
}
