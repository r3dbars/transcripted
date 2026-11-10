import Foundation

@MainActor
func testMeetingRevealTargetScan() async {
    guard ProcessInfo.processInfo.environment["TRANSCRIPTED_DISABLE_FILE_LOGGER"] == "1" else {
        assertTrue(false, "Owned reveal scanner fixtures require the file logger to be disabled")
        return
    }
    do {
        let files = try MeetingRevealScanFiles()
        defer { files.removeOwnedRoot() }

        await runSuite("An ordinary meeting request keeps its bounded newest-first prefix") {
            let (result, listings) = await files.scan()
            assertEqual(result.items.map { canonicalMeetingRevealPath($0.transcriptURL) }, files.ordered.prefix(11).map(canonicalMeetingRevealPath))
            assertEqual(result.diagnosis, .ok)
            assertNil(result.revealMinimumCount)
            assertEqual(listings, 1)
        }
        await runSuite("A deep reveal includes its exact valid prefix and lookahead in one directory listing") {
            let (result, listings) = await files.scan(target: files.ordered[24])
            assertEqual(result.items.map { canonicalMeetingRevealPath($0.transcriptURL) }, files.ordered.prefix(26).map(canonicalMeetingRevealPath))
            assertEqual(result.revealMinimumCount, 25)
            assertEqual(result.diagnosis, .ok)
            assertEqual(listings, 1)
        }
        await runSuite("A reveal already inside the visible window does not enlarge the ordinary prefix") {
            let (result, listings) = await files.scan(target: files.ordered[2])
            assertEqual(result.items.map { canonicalMeetingRevealPath($0.transcriptURL) }, files.ordered.prefix(11).map(canonicalMeetingRevealPath))
            assertEqual(result.revealMinimumCount, 3)
            assertEqual(listings, 1)
        }
        await runSuite("Missing nonmeeting excluded and outside reveal targets cannot expand or enter the prefix") {
            let targets = [files.missing, files.nonmeeting, files.outside] + files.excluded
            for target in targets {
                let (result, listings) = await files.scan(target: target)
                assertEqual(result.items.map { canonicalMeetingRevealPath($0.transcriptURL) }, files.ordered.prefix(11).map(canonicalMeetingRevealPath))
                assertNil(result.revealMinimumCount)
                assertEqual(result.diagnosis, .ok)
                assertEqual(listings, 1, "each explicit reveal request owns one listing")
                assertFalse(result.items.contains { canonicalMeetingRevealPath($0.transcriptURL) == canonicalMeetingRevealPath(target) })
            }
        }
    } catch {
        let failure = error as NSError
        assertTrue(false, "Owned scanner fixture setup failed: \(failure.domain):\(failure.code)")
    }
}

private struct MeetingRevealScanFiles: Sendable {
    let parent: URL
    let root: URL
    let directory: URL
    let ordered: [URL]
    let nonmeeting: URL
    let outside: URL
    let missing: URL
    let excluded: [URL]

    init() throws {
        let manager = FileManager.default
        let parent = manager.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let root = parent.appendingPathComponent("transcripted-meeting-reveal-\(UUID().uuidString)", isDirectory: true)
        let directory = root.appendingPathComponent("meetings", isDirectory: true)
        var ordered: [URL] = []
        let nonmeeting = directory.appendingPathComponent("NotMeeting.md")
        let outside = root.appendingPathComponent("Outside.md")
        let excluded = [".hidden.md", "AGENT.md", "CLAUDE.md", "topic.summary.md"].map {
            directory.appendingPathComponent($0)
        }
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            for ordinal in 1...30 {
                let file = directory.appendingPathComponent(String(format: "Meeting%02d.md", ordinal))
                try Self.write(file, title: String(format: "Synthetic %02d", ordinal), ordinal: ordinal)
                ordered.append(file)
            }
            try Self.write(nonmeeting, title: "Synthetic nonmeeting", ordinal: -1, kind: "dictation_day")
            try Self.write(outside, title: "Synthetic outside", ordinal: -2)
            for (index, file) in excluded.enumerated() {
                try Self.write(file, title: "Synthetic excluded", ordinal: -3 - index)
            }
        } catch {
            removeMeetingRevealOwnedRoot(root, parent: parent)
            throw error
        }
        self.parent = parent
        self.root = root
        self.directory = directory
        self.ordered = ordered
        self.nonmeeting = nonmeeting
        self.outside = outside
        self.missing = directory.appendingPathComponent("Missing.md")
        self.excluded = excluded
    }

    private static func write(_ file: URL, title: String, ordinal: Int, kind: String = "meeting") throws {
        let markdown = """
        ---
        title: "\(title)"
        capture_type: \(kind)
        date: "2026-06-05"
        time: "14:00:00"
        duration: "10:00"
        total_word_count: 5
        mic_utterances: 1
        system_utterances: 1
        ---
        # \(title)
        ## \(kind == "meeting" ? "Transcript" : "Dictations")
        **00:01** [Mic/You]
        Synthetic fixture.
        """
        try markdown.write(to: file, atomically: true, encoding: .utf8)
        let date = Date(timeIntervalSince1970: 1_700_000_000 - Double(ordinal * 100))
        try FileManager.default.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: file.path)
    }

    func scan(target: URL? = nil) async -> (RecentMeetingsScanResult, Int) {
        let manager = MeetingRevealCountingFileManager(directory: directory)
        let directory = directory
        let result = await Task.detached {
            RecentMeetingsScanner.loadRecentWithDiagnosis(
                limit: 11, directory: directory, cache: nil,
                throughTranscriptURL: target, fileManager: manager, audioResolver: { _ in nil }
            )
        }.value
        return (result, manager.listings)
    }

    func removeOwnedRoot() { removeMeetingRevealOwnedRoot(root, parent: parent) }
}

private final class MeetingRevealCountingFileManager: FileManager, @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()
    private var count = 0
    var listings: Int { lock.withLock { count } }

    init(directory: URL) { self.directory = directory; super.init() }

    override func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?,
                                      options mask: FileManager.DirectoryEnumerationOptions = []) throws -> [URL] {
        guard url.resolvingSymlinksInPath().standardizedFileURL.path == directory.path else {
            throw CocoaError(.fileReadNoPermission)
        }
        lock.withLock { count += 1 }
        return try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
    }
}

private func removeMeetingRevealOwnedRoot(_ root: URL, parent: URL) {
    let prefix = "transcripted-meeting-reveal-"
    let canonical = root.resolvingSymlinksInPath().standardizedFileURL
    guard root.lastPathComponent.hasPrefix(prefix),
          UUID(uuidString: String(root.lastPathComponent.dropFirst(prefix.count))) != nil,
          canonical.path == root.path, canonical.deletingLastPathComponent().path == parent.path else {
        assertTrue(false, "Refusing cleanup outside the exact owned reveal fixture")
        return
    }
    guard FileManager.default.fileExists(atPath: root.path) else { return }
    do { try FileManager.default.removeItem(at: root) }
    catch { assertTrue(false, "Could not remove the owned reveal fixture") }
}

private func canonicalMeetingRevealPath(_ url: URL) -> String {
    url.resolvingSymlinksInPath().standardizedFileURL.path
}
