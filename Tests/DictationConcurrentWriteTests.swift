// DictationConcurrentWriteTests.swift
// Regression guard for DictationTranscriptMutationLock: concurrent same-day
// saves must serialize through the lock so no entry is lost and the day header
// is written exactly once. Without the lock, racing read-modify-write appends
// would clobber each other.

import Foundation

func testDictationConcurrentWrite() {
    runSuite("DictationTranscriptWriter.save — concurrent same-day writes keep every entry") {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent(
            "TranscriptedDictationConcurrentTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let outputDir = tempRoot.appendingPathComponent("dictations", isDirectory: true)
        try? fm.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let base = concurrentSameDayInstant()
        let iterations = 16

        DispatchQueue.concurrentPerform(iterations: iterations) { i in
            _ = try? DictationTranscriptWriter.save(
                text: "concurrent dictation marker\(i)end recorded for the shared day file",
                sourceApp: nil,
                delivery: .pasted,
                createdAt: base.addingTimeInterval(Double(i)),
                directory: outputDir
            )
        }

        let dayURL = DictationTranscriptWriter.dailyFileURL(for: base, in: outputDir)
        let contents = (try? String(contentsOf: dayURL, encoding: .utf8)) ?? ""

        var missing: [Int] = []
        for i in 0..<iterations where !contents.contains("marker\(i)end") {
            missing.append(i)
        }
        assertEqual(missing.count, 0, "every concurrent entry must survive the lock (missing: \(missing))")

        assertEqual(
            dictationOccurrences(of: "# Dictations for", in: contents),
            1,
            "concurrent writers must not duplicate the day header"
        )

        assertEqual(
            dictationOccurrences(of: "\n## ", in: contents),
            iterations,
            "each concurrent save should append exactly one section"
        )
    }
}

private func concurrentSameDayInstant() -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let components = DateComponents(
        calendar: calendar,
        year: 2026,
        month: 4,
        day: 7,
        hour: 9,
        minute: 15,
        second: 0
    )
    return components.date ?? Date(timeIntervalSince1970: 0)
}

private func dictationOccurrences(of needle: String, in haystack: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    return haystack.components(separatedBy: needle).count - 1
}
