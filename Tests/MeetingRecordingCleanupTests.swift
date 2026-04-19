import Foundation

func testMeetingRecordingCleanup() {
    runSuite("MeetingRecordingCleanup.discardFiles removes mic and system scratch audio") {
        let root = makeMeetingCleanupTestDirectory(prefix: "meeting-cleanup")
        defer { try? FileManager.default.removeItem(at: root) }

        let micURL = root.appendingPathComponent("meeting_mic.wav")
        let systemURL = root.appendingPathComponent("meeting_system.wav")
        FileManager.default.createFile(atPath: micURL.path, contents: Data("mic".utf8))
        FileManager.default.createFile(atPath: systemURL.path, contents: Data("system".utf8))

        let discarded = MeetingRecordingCleanup.discardFiles(
            micURL: micURL,
            systemURL: systemURL
        )

        assertEqual(Set(discarded), Set([micURL, systemURL]), "both scratch files should be reported as discarded")
        assertFalse(FileManager.default.fileExists(atPath: micURL.path), "mic scratch file should be removed")
        assertFalse(FileManager.default.fileExists(atPath: systemURL.path), "system scratch file should be removed")
    }

    runSuite("MeetingRecordingCleanup.discardFiles deduplicates matching mic/system URLs") {
        let root = makeMeetingCleanupTestDirectory(prefix: "meeting-cleanup-dedupe")
        defer { try? FileManager.default.removeItem(at: root) }

        let sharedURL = root.appendingPathComponent("shared.wav")
        FileManager.default.createFile(atPath: sharedURL.path, contents: Data("audio".utf8))

        let discarded = MeetingRecordingCleanup.discardFiles(
            micURL: sharedURL,
            systemURL: sharedURL
        )

        assertEqual(discarded, [sharedURL], "the same file should only be removed once")
        assertFalse(FileManager.default.fileExists(atPath: sharedURL.path), "shared scratch file should be removed")
    }
}

private func makeMeetingCleanupTestDirectory(prefix: String) -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
