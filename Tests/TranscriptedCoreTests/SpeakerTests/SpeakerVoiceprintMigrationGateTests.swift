import Accelerate
import AVFoundation
import Foundation
import XCTest
@testable import TranscriptedCore

/// Promises of the gate that holds speaker-database writers while saved people
/// move into a new voiceprint model's database:
///   - a transcription asked for mid-move waits, then runs against the moved people;
///   - a failed move never holds anyone, never touches the old database, and the
///     next launch tries again;
///   - a second launch after a finished move embeds nothing and changes nothing;
///   - with nothing to move the gate never closes;
///   - a waiter that is cancelled (app quitting) is let go while the move runs;
///   - "needs one confirmation" counts people until they are confirmed or named again.
///
/// Everything lives in a temp folder. The fake embedder turns constant-level
/// audio into a one-hot vector, so a person's "voice" is their clip's level.
@available(macOS 14.0, *)
final class SpeakerVoiceprintMigrationGateTests: XCTestCase {

    // MARK: - Fake embedder

    /// Level 0.1 -> slot 1, 0.3 -> slot 3. With `holdsFirstCall`, the first
    /// embedding waits for `release()`, so a test can act mid-move.
    final class LevelEmbedder: SpeakerSegmentEmbedder, @unchecked Sendable {
        let dimension = 8
        let identifier = "test-level-voiceprint"
        let thresholds = SpeakerEmbeddingThresholds.eRes2Net
        private let lock = NSLock()
        private var callCount = 0
        private let hold: DispatchSemaphore?
        let reachedFirstCall = DispatchSemaphore(value: 0)

        init(holdsFirstCall: Bool = false) {
            hold = holdsFirstCall ? DispatchSemaphore(value: 0) : nil
        }

        var calls: Int {
            lock.lock()
            defer { lock.unlock() }
            return callCount
        }

        func release() { hold?.signal() }

        func embed(samples: [Float], sampleRate: Int) -> [Float]? {
            lock.lock()
            callCount += 1
            let isFirst = callCount == 1
            lock.unlock()
            if isFirst {
                reachedFirstCall.signal()
                hold?.wait()
            }
            guard sampleRate == 16_000, !samples.isEmpty else { return nil }
            var mean: Float = 0
            vDSP_meanv(samples, 1, &mean, vDSP_Length(samples.count))
            let slot = Int((mean * 10).rounded())
            guard (1..<dimension).contains(slot) else { return nil }
            return Self.vector(slot: slot)
        }

        static func vector(level: Float) -> [Float] {
            vector(slot: Int((level * 10).rounded()))
        }

        private static func vector(slot: Int) -> [Float] {
            var vector = [Float](repeating: 0, count: 8)
            vector[0] = 0.1
            vector[slot] = 1
            return SpeakerVectorMath.l2Normalize(vector)
        }
    }

    // MARK: - Fixture

    /// Ann has two review clips that agree (carried), Eve one clip (held until
    /// confirmed), Cat no audio at all (needs confirmation). Plus a voice the
    /// user never named, which doesn't move.
    struct Library {
        let root: URL
        let sourceURL: URL
        let targetURL: URL
        let sources: SpeakerVoiceprintMigrationSources
        let ann: UUID
        let eve: UUID
        let cat: UUID
    }

    private var roots: [URL] = []

    override func tearDown() {
        let tempRoot = FileManager.default.temporaryDirectory.standardizedFileURL.path
        for root in roots where root.standardizedFileURL.path.hasPrefix(tempRoot)
            && root.lastPathComponent.hasPrefix("voiceprint-gate-") {
            try? FileManager.default.removeItem(at: root)
        }
        roots.removeAll()
        super.tearDown()
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceprint-gate-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("state", isDirectory: true),
            withIntermediateDirectories: true
        )
        return root
    }

    private func makeLibrary() throws -> Library {
        let root = try makeRoot()
        let sourceURL = root.appendingPathComponent("state/speakers.sqlite")
        let clips = root.appendingPathComponent("tmp/recordings/speaker_clips", isDirectory: true)
        let olderClips = root.appendingPathComponent("state/speaker_clips", isDirectory: true)
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: olderClips, withIntermediateDirectories: true)

        var ids: [String: UUID] = [:]
        try writeSourceDatabase(at: sourceURL) { add in
            ids["ann"] = add("Ann Lee", NameSource.userManual)
            ids["eve"] = add("Eve Moss", NameSource.userManual)
            ids["cat"] = add("Cat Park", NameSource.userManual)
            _ = add(nil, nil)
        }
        let ann = try XCTUnwrap(ids["ann"]), eve = try XCTUnwrap(ids["eve"]), cat = try XCTUnwrap(ids["cat"])
        try writeClip(clips.appendingPathComponent("\(ann.uuidString).wav"), level: 0.1)
        try writeClip(olderClips.appendingPathComponent("\(ann.uuidString).wav"), level: 0.1)
        try writeClip(clips.appendingPathComponent("\(eve.uuidString).wav"), level: 0.3)

        return Library(
            root: root,
            sourceURL: sourceURL,
            targetURL: root.appendingPathComponent("state/speakers_test-level.sqlite"),
            sources: SpeakerVoiceprintMigrationSources(
                speakerClipDirectories: [clips, olderClips],
                meetingsDirectory: root.appendingPathComponent("captures/meetings", isDirectory: true)
            ),
            ann: ann,
            eve: eve,
            cat: cat
        )
    }

    /// The old model's database: 256-d vectors, like WeSpeaker, each person
    /// confirmed in one meeting.
    private func writeSourceDatabase(
        at url: URL,
        _ people: ((String?, String?) -> UUID) throws -> Void
    ) throws {
        let source = SpeakerDatabase(path: url.path)
        var count = 0
        try people { name, nameSource in
            count += 1
            let seed = Float(count)
            let created = source.addOrUpdateSpeaker(
                embedding: (0..<256).map { sinf(Float($0) * seed) },
                existingId: nil
            )
            source.restoreProfile(SpeakerProfile(
                id: created.id,
                displayName: name,
                nameSource: nameSource,
                embedding: created.embedding,
                firstSeen: Date(timeIntervalSince1970: 1_780_000_000),
                lastSeen: Date(timeIntervalSince1970: 1_780_000_000 + Double(count) * 3_600),
                callCount: 2,
                confidence: 0.9,
                disputeCount: 0
            ))
            if name != nil {
                try? source.recordUserConfirmations([
                    SpeakerUserConfirmation(profileId: created.id, transcriptId: UUID(), kind: .confirmed),
                ])
            }
            return created.id
        }
    }

    /// Six seconds of 16 kHz mono float audio at a constant level.
    private func writeClip(_ url: URL, level: Float) throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        ))
        let frames = 6 * 16_000
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        try XCTUnwrap(buffer.floatChannelData)[0].update(repeating: level, count: frames)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private func target(_ library: Library, _ embedder: LevelEmbedder) -> SpeakerDatabase {
        SpeakerDatabase(path: library.targetURL.path, thresholds: embedder.thresholds)
    }

    @MainActor
    private func start(
        _ gate: SpeakerVoiceprintMigrationGate,
        _ library: Library,
        into target: SpeakerDatabase,
        with embedder: LevelEmbedder
    ) {
        gate.start(
            sourceDatabaseURL: library.sourceURL,
            targetDatabase: target,
            embedder: embedder,
            sources: library.sources
        )
    }

    /// Lets main-actor tasks run until `condition` holds; a bounded number of turns, no clock.
    @MainActor
    private func settle(until condition: () -> Bool) async {
        for _ in 0..<10_000 where !condition() {
            await Task.yield()
        }
    }

    /// Waits off the main actor for the fake embedder to be reached. The wide
    /// bound only stops a broken run from hanging the suite.
    private func waitForFirstEmbedding(_ embedder: LevelEmbedder) async -> Bool {
        await Task.detached { embedder.reachedFirstCall.wait(timeout: .now() + 120) == .success }.value
    }

    private func sourceBytes(_ library: Library) throws -> [String: Data] {
        let directory = library.sourceURL.deletingLastPathComponent()
        var files: [String: Data] = [:]
        // The database and its WAL. `-shm` is SQLite's shared-memory index,
        // rewritten by any reader, so it isn't compared.
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path)
        where name == "speakers.sqlite" || name == "speakers.sqlite-wal" {
            files[name] = try Data(contentsOf: directory.appendingPathComponent(name))
        }
        return files
    }

    // MARK: - Promises

    @MainActor
    func testTranscriptionAskedForMidMoveWaitsThenRunsAgainstTheMovedPeople() async throws {
        let library = try makeLibrary()
        let embedder = LevelEmbedder(holdsFirstCall: true)
        let database = target(library, embedder)
        let gate = SpeakerVoiceprintMigrationGate()

        start(gate, library, into: database, with: embedder)
        let reachedEmbedding = await waitForFirstEmbedding(embedder)
        XCTAssertTrue(reachedEmbedding, "the move should reach its first embedding")
        XCTAssertFalse(gate.isOpen)
        XCTAssertNil(database.getSpeaker(id: library.ann), "Ann hasn't moved yet")

        // A queued meeting's transcription: waits on the gate, then names speakers.
        let transcription = Task { @MainActor () -> (waited: Bool, named: UUID?) in
            let waited = await gate.waitUntilOpen()
            let match = database.matchSpeaker(embedding: LevelEmbedder.vector(level: 0.1), threshold: 0.9)
            return (waited, match?.profile.id)
        }
        await settle { gate.waitingCount == 1 }
        XCTAssertEqual(gate.waitingCount, 1, "the transcription is held, not running")

        embedder.release()
        let result = await transcription.value

        XCTAssertTrue(result.waited)
        XCTAssertEqual(result.named, library.ann, "it ran against the database with Ann moved in")
        XCTAssertTrue(gate.isOpen)
        guard case .finished(let summary) = gate.phase else {
            return XCTFail("expected a finished move, got \(gate.phase)")
        }
        XCTAssertEqual(summary.movedThisRun, 3)
        XCTAssertFalse(summary.wasCancelled)
    }

    @MainActor
    func testFailedMoveLetsTranscriptionThroughLeavesTheOldDatabaseAloneAndRunsAgainNextLaunch() async throws {
        let root = try makeRoot()
        let sourceURL = root.appendingPathComponent("state/speakers.sqlite")
        let unreadable = Data("not a database".utf8)
        try unreadable.write(to: sourceURL)
        let embedder = LevelEmbedder()
        let targetURL = root.appendingPathComponent("state/speakers_test-level.sqlite")
        let database = SpeakerDatabase(path: targetURL.path, thresholds: embedder.thresholds)
        let sources = SpeakerVoiceprintMigrationSources()

        let gate = SpeakerVoiceprintMigrationGate()
        gate.start(sourceDatabaseURL: sourceURL, targetDatabase: database, embedder: embedder, sources: sources)
        XCTAssertFalse(gate.isOpen)
        let waited = await gate.waitUntilOpen()

        XCTAssertTrue(waited, "the transcription waited for the move to end")
        XCTAssertTrue(gate.isOpen, "a failure never holds anyone")
        XCTAssertEqual(gate.phase, .failed(reason: "source_database_unreadable"))
        XCTAssertEqual(try Data(contentsOf: sourceURL), unreadable, "the old database is never written")
        let laterWorkWaited = await gate.waitUntilOpen()
        XCTAssertFalse(laterWorkWaited, "later work doesn't wait at all")

        // Next launch, with the old database readable again: nothing left over
        // from the failure stops the move.
        try FileManager.default.removeItem(at: sourceURL)
        var named: UUID?
        try writeSourceDatabase(at: sourceURL) { add in named = add("Ann Lee", NameSource.userManual) }
        let nextLaunch = SpeakerVoiceprintMigrationGate()
        nextLaunch.start(sourceDatabaseURL: sourceURL, targetDatabase: database, embedder: embedder, sources: sources)
        await nextLaunch.waitUntilOpen()

        guard case .finished(let summary) = nextLaunch.phase else {
            return XCTFail("expected the next launch to finish, got \(nextLaunch.phase)")
        }
        XCTAssertEqual(summary.movedThisRun, 1)
        XCTAssertEqual(database.voiceprintMigrationLedger().map(\.profileId), [try XCTUnwrap(named)])
    }

    @MainActor
    func testSecondLaunchAfterAFinishedMoveEmbedsNothingAndChangesNothing() async throws {
        let library = try makeLibrary()
        let sourceBefore = try sourceBytes(library)

        let firstEmbedder = LevelEmbedder()
        let database = target(library, firstEmbedder)
        let firstLaunch = SpeakerVoiceprintMigrationGate()
        start(firstLaunch, library, into: database, with: firstEmbedder)
        await firstLaunch.waitUntilOpen()
        let speakersBefore = database.allSpeakers().sorted { $0.id.uuidString < $1.id.uuidString }
        let ledgerBefore = database.voiceprintMigrationLedger()
        XCTAssertEqual(ledgerBefore.count, 3)

        let secondEmbedder = LevelEmbedder()
        let secondLaunch = SpeakerVoiceprintMigrationGate()
        start(secondLaunch, library, into: database, with: secondEmbedder)
        await secondLaunch.waitUntilOpen()

        guard case .finished(let summary) = secondLaunch.phase else {
            return XCTFail("expected the second launch to finish, got \(secondLaunch.phase)")
        }
        XCTAssertEqual(summary.movedThisRun, 0)
        XCTAssertEqual(summary.alreadyMoved, 3)
        XCTAssertEqual(secondEmbedder.calls, 0, "nothing is embedded again")
        XCTAssertEqual(database.voiceprintMigrationLedger(), ledgerBefore)
        let speakersAfter = database.allSpeakers().sorted { $0.id.uuidString < $1.id.uuidString }
        XCTAssertEqual(speakersAfter.map(\.id), speakersBefore.map(\.id))
        XCTAssertEqual(speakersAfter.map(\.embedding), speakersBefore.map(\.embedding))
        XCTAssertEqual(speakersAfter.map(\.displayName), speakersBefore.map(\.displayName))
        XCTAssertEqual(speakersAfter.map(\.confirmedMeetingCount), speakersBefore.map(\.confirmedMeetingCount))
        XCTAssertEqual(try sourceBytes(library), sourceBefore, "the old database is never written")
    }

    @MainActor
    func testNothingToMoveNeverClosesTheGate() async throws {
        let root = try makeRoot()
        let embedder = LevelEmbedder()
        let database = SpeakerDatabase(
            path: root.appendingPathComponent("state/speakers_test-level.sqlite").path,
            thresholds: embedder.thresholds
        )
        let gate = SpeakerVoiceprintMigrationGate()

        gate.start(
            sourceDatabaseURL: root.appendingPathComponent("state/speakers.sqlite"),
            targetDatabase: database,
            embedder: embedder,
            sources: SpeakerVoiceprintMigrationSources()
        )

        XCTAssertTrue(gate.isOpen)
        XCTAssertEqual(gate.phase, .idle)
        let waited = await gate.waitUntilOpen()
        XCTAssertFalse(waited)
    }

    @MainActor
    func testCancelledWaiterIsLetGoWhileTheMoveRuns() async throws {
        let library = try makeLibrary()
        let embedder = LevelEmbedder(holdsFirstCall: true)
        let database = target(library, embedder)
        let gate = SpeakerVoiceprintMigrationGate()
        start(gate, library, into: database, with: embedder)
        let reachedEmbedding = await waitForFirstEmbedding(embedder)
        XCTAssertTrue(reachedEmbedding)

        let waiter = Task { @MainActor in await gate.waitUntilOpen() }
        await settle { gate.waitingCount == 1 }
        waiter.cancel()
        _ = await waiter.value

        XCTAssertFalse(gate.isOpen, "the move is still running")
        XCTAssertEqual(gate.waitingCount, 0)

        embedder.release()
        await gate.waitUntilOpen()
        XCTAssertTrue(gate.isOpen)
    }

    @MainActor
    func testPeopleNeedOneConfirmationUntilConfirmedOrNamedAgain() async throws {
        let library = try makeLibrary()
        let embedder = LevelEmbedder()
        let database = target(library, embedder)
        let gate = SpeakerVoiceprintMigrationGate()
        start(gate, library, into: database, with: embedder)
        await gate.waitUntilOpen()

        guard case .finished(let summary) = gate.phase else {
            return XCTFail("expected a finished move, got \(gate.phase)")
        }
        // Eve's single clip can't be checked against anything; Cat had no audio.
        XCTAssertEqual(summary.peopleNeedingConfirmation, 2)
        func count() -> Int {
            SpeakerVoiceprintMigrationGate.peopleNeedingConfirmation(
                ledger: database.voiceprintMigrationLedger(),
                profiles: database.allSpeakers()
            )
        }

        try database.recordUserConfirmations([
            SpeakerUserConfirmation(profileId: library.eve, transcriptId: UUID(), kind: .confirmed),
        ])
        XCTAssertEqual(count(), 1, "Eve is confirmed under the new model")

        let renamed = database.addOrUpdateSpeaker(embedding: LevelEmbedder.vector(level: 0.5), existingId: nil)
        try database.requireDisplayNameUpdate(id: renamed.id, name: " cat park ", source: NameSource.userManual)
        XCTAssertEqual(count(), 0, "Cat was named again")
    }
}
