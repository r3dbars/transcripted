import Foundation

func testCaptureLibraryMeetingAudioCollision() {
    runSuite("A colliding meeting keeps its paired source audio while other captures still move") {
        withMeetingCollisionFixture { fixture in
            let transcript = "meetings/Collision.md"
            let audio = "meetings/audio/Collision_audio/microphone.m4a"
            let otherTranscript = "meetings/Collision extended.md"
            let otherAudio = "meetings/audio/Collision extended_audio/microphone.wav"
            let orphan = "meetings/audio/Orphan_audio/system.m4a"
            try fixture.write("source meeting", transcript, in: fixture.source)
            try fixture.write("source paired audio", audio, in: fixture.source)
            try fixture.write("different destination meeting", transcript, in: fixture.destination)
            try fixture.write("other source meeting", otherTranscript, in: fixture.source)
            try fixture.write("other paired audio", otherAudio, in: fixture.source)
            try fixture.write("orphan audio", orphan, in: fixture.source)
            let planner = fixture.planner()
            let plan = planner.makePlan(from: fixture.source, to: fixture.destination)

            assertEqual(plan.skippedExisting.map(\.sourceURL.lastPathComponent), ["Collision.md"])
            assertFalse(plan.itemsToCopy.contains { $0.sourceURL.lastPathComponent == "Collision_audio" },
                        "audio belonging to a skipped source transcript stays out of the plan")
            assertEqual(Set(plan.itemsToCopy.map(\.sourceURL.lastPathComponent)),
                        Set(["Collision extended.md", "Collision extended_audio", "Orphan_audio"]),
                        "matching is by the full source stem, and orphan behavior is preserved")
            let copied = try planner.copy(plan)
            let removed = planner.removeOriginals(of: copied.copiedItems)

            assertEqual(copied.copiedCount, 3)
            assertEqual(copied.skippedExistingCount, 1)
            assertEqual(removed, CaptureLibraryOriginalsRemovalResult(removedCount: 3, keptChangedCount: 0, failedCount: 0))
            assertEqual(try? fixture.read(transcript, in: fixture.source), "source meeting")
            assertEqual(try? fixture.read(audio, in: fixture.source), "source paired audio")
            assertEqual(try? fixture.read(transcript, in: fixture.destination), "different destination meeting")
            assertFalse(fixture.exists(audio, in: fixture.destination), "unrelated destination Markdown must not gain this audio")
            assertEqual(Set(fixture.removedNames), Set(["Collision extended.md", "Collision extended_audio", "Orphan_audio"]))
            assertEqual(try? fixture.read(otherTranscript, in: fixture.destination), "other source meeting")
            assertEqual(try? fixture.read(otherAudio, in: fixture.destination), "other paired audio")
            assertEqual(try? fixture.read(orphan, in: fixture.destination), "orphan audio")
            assertFalse(fixture.exists(otherTranscript, in: fixture.source))
            assertFalse(fixture.exists(otherAudio, in: fixture.source))
            assertFalse(fixture.exists(orphan, in: fixture.source))
        }
    }

    runSuite("A transcript collision arriving after planning also keeps its paired source audio") {
        withMeetingCollisionFixture { fixture in
            let transcript = "meetings/Late.md"
            let audio = "meetings/audio/Late_audio/microphone.m4a"
            try fixture.write("source late meeting", transcript, in: fixture.source)
            try fixture.write("source late audio", audio, in: fixture.source)
            let planner = fixture.planner()
            let plan = planner.makePlan(from: fixture.source, to: fixture.destination)
            assertEqual(plan.itemsToCopy.map(\.kind), [.meetingTranscript, .meetingAudioDirectory])
            assertEqual(plan.skippedExisting.count, 0)
            try fixture.write("late unrelated destination", transcript, in: fixture.destination)

            let copied = try planner.copy(plan)
            let removed = planner.removeOriginals(of: copied.copiedItems)
            assertEqual(copied.copiedCount, 0)
            assertEqual(copied.skippedExistingCount, 2, "the planned dependent audio is also skipped at copy time")
            assertTrue(copied.copiedItems.isEmpty)
            assertEqual(removed, CaptureLibraryOriginalsRemovalResult(removedCount: 0, keptChangedCount: 0, failedCount: 0))
            assertTrue(fixture.removedNames.isEmpty)
            assertEqual(try? fixture.read(transcript, in: fixture.source), "source late meeting")
            assertEqual(try? fixture.read(audio, in: fixture.source), "source late audio")
            assertEqual(try? fixture.read(transcript, in: fixture.destination), "late unrelated destination")
            assertFalse(fixture.exists(audio, in: fixture.destination))
        }
    }

    runSuite("Existing uppercase Markdown extensions still associate with their exact audio stem") {
        withMeetingCollisionFixture { fixture in
            let transcript = "meetings/Upper.MD"
            let audio = "meetings/audio/Upper_audio/microphone.wav"
            try fixture.write("uppercase source meeting", transcript, in: fixture.source)
            try fixture.write("uppercase source audio", audio, in: fixture.source)
            try fixture.write("uppercase destination meeting", transcript, in: fixture.destination)
            let planner = fixture.planner()
            let plan = planner.makePlan(from: fixture.source, to: fixture.destination)
            assertEqual(plan.skippedExisting.map(\.sourceURL.lastPathComponent), ["Upper.MD"])
            assertTrue(plan.itemsToCopy.isEmpty)
            let copied = try planner.copy(plan)
            let removed = planner.removeOriginals(of: copied.copiedItems)
            assertEqual(copied.copiedCount, 0)
            assertEqual(copied.skippedExistingCount, 1)
            assertEqual(removed.removedCount, 0)
            assertTrue(fixture.removedNames.isEmpty)
            assertEqual(try? fixture.read(transcript, in: fixture.source), "uppercase source meeting")
            assertEqual(try? fixture.read(audio, in: fixture.source), "uppercase source audio")
            assertEqual(try? fixture.read(transcript, in: fixture.destination), "uppercase destination meeting")
            assertFalse(fixture.exists(audio, in: fixture.destination))
        }
    }

    runSuite("Retrying a copy that stopped before a meeting's audio still copies that audio") {
        withMeetingCollisionFixture { fixture in
            let transcript = "meetings/Retry.md"
            let audio = "meetings/audio/Retry_audio/microphone.m4a"
            try fixture.write("retry meeting", transcript, in: fixture.source)
            try fixture.write("retry audio", audio, in: fixture.source)

            let failing = AudioCopyFailingFileManager()
            let firstPlanner = fixture.planner(fileManager: failing)
            let firstPlan = firstPlanner.makePlan(from: fixture.source, to: fixture.destination)
            assertEqual(firstPlan.itemsToCopy.map(\.kind), [.meetingTranscript, .meetingAudioDirectory])
            var firstAttemptThrew = false
            do { _ = try firstPlanner.copy(firstPlan) } catch { firstAttemptThrew = true }
            assertTrue(firstAttemptThrew, "the first attempt stops at the audio folder")
            assertEqual(try? fixture.read(transcript, in: fixture.destination), "retry meeting")
            assertFalse(fixture.exists(audio, in: fixture.destination))

            let planner = fixture.planner()
            let retryPlan = planner.makePlan(from: fixture.source, to: fixture.destination)
            assertEqual(retryPlan.skippedExisting.map(\.sourceURL.lastPathComponent), ["Retry.md"])
            assertEqual(retryPlan.itemsToCopy.map(\.sourceURL.lastPathComponent), ["Retry_audio"],
                        "an identical destination transcript is the same meeting, so its audio is still planned")
            let copied = try planner.copy(retryPlan)
            let removed = planner.removeOriginals(of: copied.copiedItems)

            assertEqual(copied.copiedCount, 1)
            assertEqual(copied.skippedExistingCount, 1)
            assertEqual(try? fixture.read(audio, in: fixture.destination), "retry audio")
            assertEqual(removed, CaptureLibraryOriginalsRemovalResult(removedCount: 1, keptChangedCount: 0, failedCount: 0))
            assertEqual(fixture.removedNames, ["Retry_audio"])
            assertEqual(try? fixture.read(transcript, in: fixture.source), "retry meeting",
                        "the skipped transcript is never removed")
        }
    }

    runSuite("A same-named destination transcript added after planning with identical bytes lets the audio copy") {
        withMeetingCollisionFixture { fixture in
            let transcript = "meetings/Twin.md"
            let audio = "meetings/audio/Twin_audio/microphone.m4a"
            try fixture.write("twin meeting", transcript, in: fixture.source)
            try fixture.write("twin audio", audio, in: fixture.source)
            let planner = fixture.planner()
            let plan = planner.makePlan(from: fixture.source, to: fixture.destination)
            try fixture.write("twin meeting", transcript, in: fixture.destination)

            let copied = try planner.copy(plan)
            assertEqual(copied.copiedCount, 1)
            assertEqual(copied.skippedExistingCount, 1)
            assertEqual(try? fixture.read(audio, in: fixture.destination), "twin audio")
        }
    }
}

/// Fails the copy of any retained `_audio` folder, like a drive unplugged
/// after the small transcripts already landed.
private final class AudioCopyFailingFileManager: FileManager {
    struct InjectedFailure: Error {}

    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        if srcURL.lastPathComponent.hasSuffix("_audio") { throw InjectedFailure() }
        try super.copyItem(at: srcURL, to: dstURL)
    }
}

private enum MeetingCollisionFixtureError: Error { case outsideOwnedRoot }

private final class MeetingCollisionFixture {
    let root: URL
    let source: URL
    let destination: URL
    private(set) var removedNames: [String] = []
    private let manager = FileManager.default

    init(root: URL) {
        self.root = root
        source = root.appendingPathComponent("source", isDirectory: true)
        destination = root.appendingPathComponent("destination", isDirectory: true)
    }

    func planner(fileManager: FileManager = .default) -> CaptureLibraryMigrationPlanner {
        CaptureLibraryMigrationPlanner(fileManager: fileManager, removeOriginal: { [self] url in
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            let ownedSource = source.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path.hasPrefix(ownedSource.path + "/"),
                  ownedSource.deletingLastPathComponent() == root,
                  (try manager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) != .typeSymbolicLink else {
                throw MeetingCollisionFixtureError.outsideOwnedRoot
            }
            removedNames.append(url.lastPathComponent)
            try manager.removeItem(at: url)
        })
    }

    func write(_ contents: String, _ relative: String, in library: URL) throws {
        let url = library.appendingPathComponent(relative)
        guard url.standardizedFileURL.path.hasPrefix(root.path + "/") else {
            throw MeetingCollisionFixtureError.outsideOwnedRoot
        }
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url, options: .atomic)
    }

    func read(_ relative: String, in library: URL) throws -> String {
        try String(contentsOf: library.appendingPathComponent(relative), encoding: .utf8)
    }

    func exists(_ relative: String, in library: URL) -> Bool {
        manager.fileExists(atPath: library.appendingPathComponent(relative).path)
    }
}

private func withMeetingCollisionFixture(_ body: (MeetingCollisionFixture) throws -> Void) {
    let manager = FileManager.default
    let parent = manager.temporaryDirectory.resolvingSymlinksInPath()
    let prefix = "MeetingAudioMigrationCollision-"
    let leaf = prefix + UUID().uuidString
    let root = parent.appendingPathComponent(leaf, isDirectory: true)
    do {
        try manager.createDirectory(at: root, withIntermediateDirectories: false)
        defer {
            do {
                let resolved = root.resolvingSymlinksInPath()
                let attributes = try manager.attributesOfItem(atPath: root.path)
                if resolved.deletingLastPathComponent() == parent, resolved.lastPathComponent == leaf,
                   UUID(uuidString: String(leaf.dropFirst(prefix.count))) != nil,
                   attributes[.type] as? FileAttributeType == .typeDirectory {
                    try manager.removeItem(at: root)
                } else { assertTrue(false, "Refusing cleanup outside the owned migration fixture") }
            } catch { assertTrue(false, "Could not remove the owned migration fixture") }
        }
        try body(MeetingCollisionFixture(root: root))
    } catch { assertTrue(false, "Could not prepare the owned migration fixture") }
}
