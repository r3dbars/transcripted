import Accelerate
import AVFoundation
import Foundation
import SQLite3
import XCTest
@testable import TranscriptedCore

/// Promises of the carry-forward migration that moves user-named people from
/// one voiceprint model's speaker database to another's:
///   - every user-named person comes over under the same UUID, with their name
///     and confirmation count, and a voiceprint built from their audio;
///   - voices the user never named don't come over;
///   - running it again changes nothing;
///   - someone with no audio left is reported, not dropped;
///   - the source database file is never written;
///   - a cancelled run, run again, ends exactly where an uninterrupted run does;
///   - someone whose audio disagrees with itself under the new model keeps their
///     name but can't be silently named until the user confirms them once, and
///     that confirmation gives their carried confirmations back right away.
///
/// Everything lives in a temp folder. The fake embedder maps a stretch of
/// constant-level audio to a known one-hot vector, so each fixture person's
/// "voice" is the level their audio is written at.
@available(macOS 14.0, *)
final class SpeakerVoiceprintMigrationTests: XCTestCase {

    // MARK: - Fake embedder

    /// Level 0.1 -> slot 1, 0.2 -> slot 2, ... plus a small shared component.
    /// Different levels are near-orthogonal (cosine ~0.01), same level is 1.
    final class LevelEmbedder: SpeakerSegmentEmbedder, @unchecked Sendable {
        let dimension = 8
        let identifier = "test-level-voiceprint"
        let thresholds = SpeakerEmbeddingThresholds.eRes2Net
        private let lock = NSLock()
        private var callCount = 0
        private let cancelOnCall: Int?

        init(cancelOnCall: Int? = nil) {
            self.cancelOnCall = cancelOnCall
        }

        var calls: Int {
            lock.lock()
            defer { lock.unlock() }
            return callCount
        }

        func embed(samples: [Float], sampleRate: Int) -> [Float]? {
            lock.lock()
            callCount += 1
            let shouldCancel = callCount == cancelOnCall
            lock.unlock()
            if shouldCancel {
                withUnsafeCurrentTask { $0?.cancel() }
            }
            guard sampleRate == 16_000, !samples.isEmpty else { return nil }
            var mean: Float = 0
            vDSP_meanv(samples, 1, &mean, vDSP_Length(samples.count))
            let slot = Int((mean * 10).rounded())
            guard (1..<dimension).contains(slot) else { return nil }
            return Self.vector(slot: slot, dimension: dimension)
        }

        static func vector(level: Float) -> [Float] {
            vector(slot: Int((level * 10).rounded()), dimension: 8)
        }

        private static func vector(slot: Int, dimension: Int) -> [Float] {
            var vector = [Float](repeating: 0, count: dimension)
            vector[0] = 0.1
            vector[slot] = 1
            return SpeakerVectorMath.l2Normalize(vector)
        }
    }

    // MARK: - Fixture

    /// A small library: five named people, one unnamed voice, one name the old
    /// LLM guessed (not user-named), three meetings and three review clips.
    struct Fixture {
        let root: URL
        let sourceURL: URL
        let clipsDirectory: URL
        let meetingsDirectory: URL

        let ann: UUID   // level 0.1: two meetings (mic + an import) and a clip; 5 confirmations
        let bob: UUID   // level 0.2: one auto-recognized meeting and a 48 kHz clip; 1 confirmation
        let cat: UUID   // no audio at all; 3 confirmations
        let dan: UUID   // two meetings at different levels (0.5, 0.6): disagrees; 2 confirmations
        let eve: UUID   // level 0.3: one clip only; 1 confirmation
        let unnamed: UUID
        let guessed: UUID

        var namedIds: Set<UUID> { [ann, bob, cat, dan, eve] }
        var sources: SpeakerVoiceprintMigrationSources {
            SpeakerVoiceprintMigrationSources(
                speakerClipDirectories: [clipsDirectory],
                meetingsDirectory: meetingsDirectory
            )
        }
    }

    private var roots: [URL] = []

    override func tearDown() {
        let tempRoot = FileManager.default.temporaryDirectory.standardizedFileURL.path
        for root in roots where root.standardizedFileURL.path.hasPrefix(tempRoot)
            && root.lastPathComponent.hasPrefix("voiceprint-migration-") {
            try? FileManager.default.removeItem(at: root)
        }
        roots.removeAll()
        super.tearDown()
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceprint-migration-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        let meetings = root.appendingPathComponent("captures/meetings", isDirectory: true)
        let clips = root.appendingPathComponent("tmp/recordings/speaker_clips", isDirectory: true)
        try FileManager.default.createDirectory(at: meetings, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        let sourceURL = root.appendingPathComponent("state/speakers.sqlite")

        let t1 = UUID(), t2 = UUID(), t3 = UUID()
        var ids: [String: UUID] = [:]
        do {
            // The old model's database: 256-d vectors, like WeSpeaker.
            let source = SpeakerDatabase(path: sourceURL.path)
            func person(_ name: String?, source nameSource: String?, callCount: Int, disputes: Int = 0) -> UUID {
                let seed = Float(ids.count + 1)
                let vector = (0..<256).map { sinf(Float($0) * seed) }
                let created = source.addOrUpdateSpeaker(embedding: vector, existingId: nil)
                source.restoreProfile(SpeakerProfile(
                    id: created.id,
                    displayName: name,
                    nameSource: nameSource,
                    embedding: created.embedding,
                    firstSeen: Date(timeIntervalSince1970: 1_780_000_000),
                    lastSeen: Date(timeIntervalSince1970: 1_780_000_000 + Double(ids.count) * 3_600),
                    callCount: callCount,
                    confidence: 0.9,
                    disputeCount: disputes
                ))
                ids[name ?? "unnamed-\(ids.count)"] = created.id
                return created.id
            }
            let ann = person("Ann Lee", source: NameSource.userManual, callCount: 9)
            let bob = person("Bob Stone", source: NameSource.userManual, callCount: 4)
            let cat = person("Cat Park", source: NameSource.userManual, callCount: 3)
            let dan = person("Dan Ruiz", source: NameSource.userManual, callCount: 2)
            let eve = person("Eve Moss", source: NameSource.userManual, callCount: 1)
            _ = person(nil, source: nil, callCount: 2)
            _ = person("Maybe Frank", source: "qwen_inferred", callCount: 5)

            func confirm(_ id: UUID, _ transcripts: [UUID]) throws {
                try source.recordUserConfirmations(transcripts.map {
                    SpeakerUserConfirmation(profileId: id, transcriptId: $0, kind: .confirmed)
                })
            }
            try confirm(ann, [t1, t2, UUID(), UUID(), UUID()])
            try confirm(bob, [UUID()])
            try confirm(cat, [UUID(), UUID(), UUID()])
            try confirm(dan, [t3, UUID()])
            try confirm(eve, [UUID()])
            source.recordMatchOutcome(SpeakerMatchOutcome(
                profileId: ann, kind: .confirmed, similarity: 0.91, transcriptId: t1
            ))
        }
        let fixture = Fixture(
            root: root,
            sourceURL: sourceURL,
            clipsDirectory: clips,
            meetingsDirectory: meetings,
            ann: ids["Ann Lee"]!,
            bob: ids["Bob Stone"]!,
            cat: ids["Cat Park"]!,
            dan: ids["Dan Ruiz"]!,
            eve: ids["Eve Moss"]!,
            unnamed: ids["unnamed-5"]!,
            guessed: ids["Maybe Frank"]!
        )

        // Meeting 1 (raw form): Ann on the mic, Bob (auto-recognized) and an
        // unnamed voice on the call.
        try writeMeeting(
            fixture, stem: "Call_2026-09-01_10-00-00", transcriptId: t1, date: "2026-09-01",
            speakers: [
                (.mic, fixture.ann, "Ann Lee", "user_manual"),
                (.system, fixture.bob, "Bob Stone", "db"),
                (.system, fixture.unnamed, "Speaker 2", "db_pending"),
            ],
            body: """
            ## Full Transcript

            [00:00] [Mic/Ann Lee] Morning everyone.

            [00:02] [System/Bob Stone] Hey Ann, quick update from our side.

            [00:10] [System/Speaker 2] I can take that one.

            [00:20] [Mic/Ann Lee] Sounds good, let's keep going.
            """,
            tracks: [
                "microphone": (30, [(0, 30, 0.1)]),
                "system_audio": (30, [(2, 10, 0.2), (10, 20, 0.7)]),
            ]
        )
        // Meeting 2 (styled form, an import): Ann confirmed, Dan auto-recognized at level 0.6.
        try writeMeeting(
            fixture, stem: "2026-09-02 Ann interview", transcriptId: t2, date: "2026-09-02",
            speakers: [
                (.system, fixture.ann, "Ann Lee", "user_manual"),
                (.system, fixture.dan, "Dan Ruiz", "db"),
            ],
            body: """
            # Ann interview

            Recorded Sep 2, 2026 at 9:00 AM  •  30 sec

            ## Transcript

            **00:00**  [System/Ann Lee]
            Welcome to the show.

            **00:12**  [System/Dan Ruiz]
            Thanks for having me.

            **00:20**  [System/Ann Lee]
            Great, let's start.
            """,
            tracks: ["recording": (30, [(0, 12, 0.1), (12, 20, 0.6), (20, 30, 0.1)])]
        )
        // Meeting 3 (raw form): Dan on the call at level 0.5.
        try writeMeeting(
            fixture, stem: "Call_2026-09-03_15-00-00", transcriptId: t3, date: "2026-09-03",
            speakers: [(.system, fixture.dan, "Dan Ruiz", "user_manual")],
            body: """
            ## Full Transcript

            [00:00] [System/Dan Ruiz] Can everyone hear me?

            [00:15] [System/Dan Ruiz] Okay, first item.
            """,
            tracks: ["system_audio": (30, [(0, 30, 0.5)])]
        )

        try writeTrack(clips.appendingPathComponent("\(fixture.ann.uuidString).wav"), seconds: 6, segments: [(0, 6, 0.1)])
        try writeTrack(
            clips.appendingPathComponent("\(fixture.bob.uuidString).wav"),
            sampleRate: 48_000, seconds: 6, segments: [(0, 6, 0.2)]
        )
        try writeTrack(clips.appendingPathComponent("\(fixture.eve.uuidString).wav"), seconds: 6, segments: [(0, 6, 0.3)])
        return fixture
    }

    private func writeMeeting(
        _ fixture: Fixture,
        stem: String,
        transcriptId: UUID,
        date: String,
        speakers: [(UtteranceChannel, UUID, String, String)],
        body: String,
        tracks: [String: (seconds: Double, segments: [(Double, Double, Float)])]
    ) throws {
        var frontmatter = """
        ---
        capture_id: "\(transcriptId.uuidString)"
        capture_type: meeting
        format_version: 1
        transcript_id: "\(transcriptId.uuidString)"
        date: \(date)
        time: 10:00:00
        duration: "0:30"
        speakers:
        """
        for (index, speaker) in speakers.enumerated() {
            frontmatter += """

              - id: "\(index)"
                channel: \(speaker.0.rawValue)
                db_id: "\(speaker.1.uuidString)"
                name: "\(speaker.2)"
                confidence: high
                source: \(speaker.3)
            """
        }
        frontmatter += "\n---\n\n"
        let url = fixture.meetingsDirectory.appendingPathComponent("\(stem).md")
        try (frontmatter + body + "\n").write(to: url, atomically: true, encoding: .utf8)

        let audio = fixture.meetingsDirectory
            .appendingPathComponent("audio/\(stem)_audio", isDirectory: true)
        for (trackStem, track) in tracks {
            try writeTrack(
                audio.appendingPathComponent("\(trackStem).wav"),
                seconds: track.seconds,
                segments: track.segments
            )
        }
    }

    /// Mono float WAV, silent except for constant-level `segments` (start, end, level).
    private func writeTrack(
        _ url: URL,
        sampleRate: Double = 16_000,
        seconds: Double,
        segments: [(Double, Double, Float)]
    ) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
        ))
        let frames = Int(seconds * sampleRate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let data = try XCTUnwrap(buffer.floatChannelData)[0]
        data.update(repeating: 0, count: frames)
        for (start, end, level) in segments {
            let first = Int(start * sampleRate)
            let count = min(Int(end * sampleRate), frames) - first
            if count > 0 { (data + first).update(repeating: level, count: count) }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private func makeTarget(_ fixture: Fixture, _ embedder: LevelEmbedder) -> SpeakerDatabase {
        SpeakerDatabase(
            path: fixture.root.appendingPathComponent("state/speakers_test-level.sqlite").path,
            thresholds: embedder.thresholds
        )
    }

    private func migrate(
        _ fixture: Fixture,
        into target: SpeakerDatabase,
        with embedder: LevelEmbedder
    ) async throws -> SpeakerVoiceprintMigrationReport {
        let migration = try SpeakerVoiceprintMigration(
            sourceDatabaseURL: fixture.sourceURL,
            targetDatabase: target,
            embedder: embedder,
            sources: fixture.sources
        )
        // Its own task, so a cancel from inside the embedder stops only the migration.
        return try await Task { try await migration.run() }.value
    }

    private func statuses(_ target: SpeakerDatabase) -> [UUID: SpeakerVoiceprintMigrationStatus] {
        Dictionary(uniqueKeysWithValues: target.voiceprintMigrationLedger().map { ($0.profileId, $0.status) })
    }

    private let expectedStatuses: (Fixture) -> [UUID: SpeakerVoiceprintMigrationStatus] = { fixture in
        [
            fixture.ann: .carried,
            fixture.bob: .carried,
            fixture.cat: .needsConfirmation,
            fixture.dan: .held,
            fixture.eve: .held,
        ]
    }

    // MARK: - Promises

    func testNamedPeopleCarryOverWithTheirIdsNamesCountsAndConfirmations() async throws {
        let fixture = try makeFixture()
        let embedder = LevelEmbedder()
        let target = makeTarget(fixture, embedder)

        let report = try await migrate(fixture, into: target, with: embedder)

        XCTAssertFalse(report.wasCancelled)
        XCTAssertEqual(Set(report.ids(.carried)), [fixture.ann, fixture.bob])
        let ann = try XCTUnwrap(target.getSpeaker(id: fixture.ann))
        XCTAssertEqual(ann.displayName, "Ann Lee")
        XCTAssertEqual(ann.nameSource, NameSource.userManual)
        XCTAssertEqual(ann.callCount, 9)
        XCTAssertEqual(ann.confirmedMeetingCount, 5)
        XCTAssertEqual(ann.embedding.count, embedder.dimension)
        XCTAssertGreaterThan(SpeakerVectorMath.cosineSimilarity(ann.embedding, LevelEmbedder.vector(level: 0.1)), 0.99)

        let bob = try XCTUnwrap(target.getSpeaker(id: fixture.bob))
        XCTAssertEqual(bob.displayName, "Bob Stone")
        XCTAssertEqual(bob.confirmedMeetingCount, 1)
        XCTAssertGreaterThan(SpeakerVectorMath.cosineSimilarity(bob.embedding, LevelEmbedder.vector(level: 0.2)), 0.99)

        // The carried voiceprint is what the new model recognizes.
        XCTAssertEqual(target.matchSpeaker(embedding: LevelEmbedder.vector(level: 0.1), threshold: 0.9)?.profile.id, fixture.ann)
        // Health comes over too: Ann's latest verdict is still on file.
        XCTAssertEqual(target.recentMatchOutcomes(profileId: fixture.ann, limit: 5).map(\.kind), [.confirmed])
    }

    func testVoicesTheUserNeverNamedAreNotCarried() async throws {
        let fixture = try makeFixture()
        let embedder = LevelEmbedder()
        let target = makeTarget(fixture, embedder)

        let report = try await migrate(fixture, into: target, with: embedder)

        XCTAssertNil(target.getSpeaker(id: fixture.unnamed))
        XCTAssertNil(target.getSpeaker(id: fixture.guessed))
        XCTAssertEqual(report.peopleInScope, 5)
        XCTAssertEqual(Set(report.people.map(\.profileId)), fixture.namedIds)
        XCTAssertEqual(Set(target.allSpeakers().map(\.id)), [fixture.ann, fixture.bob, fixture.dan, fixture.eve])
    }

    func testRunningAgainChangesNothing() async throws {
        let fixture = try makeFixture()
        let first = LevelEmbedder()
        let target = makeTarget(fixture, first)
        _ = try await migrate(fixture, into: target, with: first)
        let before = target.allSpeakers().sorted { $0.id.uuidString < $1.id.uuidString }
        let ledgerBefore = target.voiceprintMigrationLedger()

        let second = LevelEmbedder()
        let report = try await migrate(fixture, into: target, with: second)

        XCTAssertTrue(report.people.isEmpty)
        XCTAssertEqual(report.alreadyMigrated, 5)
        XCTAssertEqual(second.calls, 0, "a finished migration must not re-embed anything")
        XCTAssertEqual(target.voiceprintMigrationLedger(), ledgerBefore)
        let after = target.allSpeakers().sorted { $0.id.uuidString < $1.id.uuidString }
        XCTAssertEqual(after.map(\.id), before.map(\.id))
        XCTAssertEqual(after.map(\.embedding), before.map(\.embedding))
        XCTAssertEqual(after.map(\.exemplars), before.map(\.exemplars))
        XCTAssertEqual(after.map(\.callCount), before.map(\.callCount))
        XCTAssertEqual(after.map(\.confirmedMeetingCount), before.map(\.confirmedMeetingCount))
    }

    func testPersonWithNoAudioIsReportedAsNeedingOneConfirmation() async throws {
        let fixture = try makeFixture()
        let embedder = LevelEmbedder()
        let target = makeTarget(fixture, embedder)

        let report = try await migrate(fixture, into: target, with: embedder)

        XCTAssertEqual(report.ids(.needsConfirmation), [fixture.cat])
        let entry = try XCTUnwrap(target.voiceprintMigrationLedger().first { $0.profileId == fixture.cat })
        XCTAssertEqual(entry.status, .needsConfirmation)
        XCTAssertEqual(entry.displayName, "Cat Park")
        XCTAssertEqual(entry.sessions, 0)
        XCTAssertNil(target.getSpeaker(id: fixture.cat), "no voiceprint can be built without audio")
    }

    func testSourceDatabaseBytesAreUnchanged() async throws {
        let fixture = try makeFixture()
        let directory = fixture.sourceURL.deletingLastPathComponent()
        func sourceFiles() throws -> [String: Data] {
            var files: [String: Data] = [:]
            for name in try FileManager.default.contentsOfDirectory(atPath: directory.path)
            where name == "speakers.sqlite" || name == "speakers.sqlite-wal" {
                files[name] = try Data(contentsOf: directory.appendingPathComponent(name))
            }
            return files
        }
        let before = try sourceFiles()
        XCTAssertNotNil(before["speakers.sqlite"])

        let embedder = LevelEmbedder()
        let target = makeTarget(fixture, embedder)
        let migration = try SpeakerVoiceprintMigration(
            sourceDatabaseURL: fixture.sourceURL,
            targetDatabase: target,
            embedder: embedder,
            sources: fixture.sources
        )
        _ = try await migration.inventory()
        _ = try await migration.run()
        _ = try await migration.run()

        XCTAssertEqual(try sourceFiles(), before)
    }

    func testTheSourceFileIsRefusedAsTheTarget() throws {
        let fixture = try makeFixture()
        XCTAssertThrowsError(try SpeakerVoiceprintMigration(
            sourceDatabaseURL: fixture.sourceURL,
            targetDatabaseURL: fixture.sourceURL,
            embedder: LevelEmbedder(),
            sources: fixture.sources
        )) { error in
            XCTAssertEqual(error as? SpeakerVoiceprintMigrationError, .targetIsSource)
        }
    }

    func testCancelledRunResumesToTheSameResultAsAnUninterruptedRun() async throws {
        let fixture = try makeFixture()
        let cancelling = LevelEmbedder(cancelOnCall: 3)
        let target = makeTarget(fixture, cancelling)

        let first = try await migrate(fixture, into: target, with: cancelling)
        XCTAssertTrue(first.wasCancelled)
        XCTAssertEqual(cancelling.calls, 3, "nothing more is embedded once the run is cancelled")
        XCTAssertLessThan(first.people.count, 5)
        let finishedFirst = Set(first.people.map(\.profileId))
        XCTAssertEqual(Set(statuses(target).keys), finishedFirst, "only finished people are in the ledger")

        let second = try await migrate(fixture, into: target, with: LevelEmbedder())
        XCTAssertFalse(second.wasCancelled)
        XCTAssertTrue(finishedFirst.isDisjoint(with: second.people.map(\.profileId)), "nobody is done twice")
        XCTAssertEqual(first.people.count + second.people.count, 5)

        // Same end state as a clean run on an identical library.
        XCTAssertEqual(statuses(target), expectedStatuses(fixture))
        let ann = try XCTUnwrap(target.getSpeaker(id: fixture.ann))
        XCTAssertEqual(ann.confirmedMeetingCount, 5)
        XCTAssertGreaterThan(SpeakerVectorMath.cosineSimilarity(ann.embedding, LevelEmbedder.vector(level: 0.1)), 0.99)
        XCTAssertEqual(Set(target.allSpeakers().map(\.id)), [fixture.ann, fixture.bob, fixture.dan, fixture.eve])
    }

    func testAudioThatDisagreesKeepsTheNameButWaitsForOneConfirmation() async throws {
        let fixture = try makeFixture()
        let embedder = LevelEmbedder()
        let target = makeTarget(fixture, embedder)

        let report = try await migrate(fixture, into: target, with: embedder)

        // Dan's two meetings sound like two different people; Eve has one clip,
        // which can't be checked against anything.
        XCTAssertEqual(Set(report.ids(.held)), [fixture.dan, fixture.eve])
        let dan = try XCTUnwrap(target.getSpeaker(id: fixture.dan))
        XCTAssertEqual(dan.displayName, "Dan Ruiz")
        XCTAssertEqual(dan.confirmedMeetingCount, 0, "held people can't be silently named")
        XCTAssertFalse(SpeakerNamingPolicy.isAutoRecognizable(
            profile: dan, recentOutcomes: [], requiredConfirmations: 1
        ))
        let danReport = try XCTUnwrap(report.people.first { $0.profileId == fixture.dan })
        XCTAssertLessThan(try XCTUnwrap(danReport.selfSimilarity), embedder.thresholds.matchManySegments)

        // The user confirms Dan once under the new model. His two carried
        // confirmations come back with that confirmation, in the same session,
        // not at the next launch.
        try target.recordUserConfirmations([
            SpeakerUserConfirmation(profileId: fixture.dan, transcriptId: UUID(), kind: .confirmed),
        ])

        XCTAssertEqual(target.getSpeaker(id: fixture.dan)?.confirmedMeetingCount, 3)
        XCTAssertEqual(target.getSpeaker(id: fixture.eve)?.confirmedMeetingCount, 0, "Eve wasn't confirmed yet")
        XCTAssertEqual(statuses(target)[fixture.dan], .carried)
        XCTAssertNotNil(target.voiceprintMigrationLedger().first { $0.profileId == fixture.dan }?.releasedAt)

        // The next launch's run has nothing left to release and changes nothing.
        let next = try await migrate(fixture, into: target, with: LevelEmbedder())
        XCTAssertEqual(next.released, [])
        XCTAssertEqual(target.getSpeaker(id: fixture.dan)?.confirmedMeetingCount, 3)
        XCTAssertEqual(statuses(target)[fixture.eve], .held)
    }

    func testConfirmingSomeoneElseReleasesNobody() async throws {
        let fixture = try makeFixture()
        let embedder = LevelEmbedder()
        let target = makeTarget(fixture, embedder)
        _ = try await migrate(fixture, into: target, with: embedder)

        try target.recordUserConfirmations([
            SpeakerUserConfirmation(profileId: fixture.ann, transcriptId: UUID(), kind: .confirmed),
        ])

        XCTAssertEqual(target.getSpeaker(id: fixture.ann)?.confirmedMeetingCount, 6)
        XCTAssertEqual(statuses(target)[fixture.dan], .held)
        XCTAssertEqual(statuses(target)[fixture.eve], .held)
        XCTAssertEqual(target.getSpeaker(id: fixture.dan)?.confirmedMeetingCount, 0)
        XCTAssertEqual(target.getSpeaker(id: fixture.eve)?.confirmedMeetingCount, 0)
    }

    func testConfirmingThePersonAHeldProfileWasMergedIntoReleasesIt() async throws {
        let fixture = try makeFixture()
        let embedder = LevelEmbedder()
        let target = makeTarget(fixture, embedder)
        _ = try await migrate(fixture, into: target, with: embedder)
        // In review the user says Eve's voice is really Bob, then confirms Bob.
        try target.mergeProfiles(sourceId: fixture.eve, into: fixture.bob)
        let bobBefore = try XCTUnwrap(target.getSpeaker(id: fixture.bob)).confirmedMeetingCount

        try target.recordUserConfirmations([
            SpeakerUserConfirmation(profileId: fixture.bob, transcriptId: UUID(), kind: .confirmed),
        ])

        XCTAssertEqual(statuses(target)[fixture.eve], .carried, "Eve's hold ends where her voice went")
        XCTAssertEqual(
            target.getSpeaker(id: fixture.bob)?.confirmedMeetingCount, bobBefore + 2,
            "the new confirmation plus Eve's one carried confirmation"
        )
        XCTAssertEqual(statuses(target)[fixture.dan], .held)
    }

    func testAnUnreadableHeldRowStaysHeldAndDoesNotBlockTheConfirmation() async throws {
        let fixture = try makeFixture()
        let embedder = LevelEmbedder()
        let target = makeTarget(fixture, embedder)
        _ = try await migrate(fixture, into: target, with: embedder)
        try corruptHeldRecord(of: fixture.eve, in: fixture)

        try target.recordUserConfirmations([
            SpeakerUserConfirmation(profileId: fixture.eve, transcriptId: UUID(), kind: .confirmed),
            SpeakerUserConfirmation(profileId: fixture.dan, transcriptId: UUID(), kind: .confirmed),
        ])

        XCTAssertEqual(target.getSpeaker(id: fixture.eve)?.confirmedMeetingCount, 1, "the user's own confirmation is kept")
        XCTAssertEqual(statuses(target)[fixture.eve], .held)
        XCTAssertEqual(statuses(target)[fixture.dan], .carried, "one bad row doesn't hold anyone else back")
        XCTAssertEqual(target.getSpeaker(id: fixture.dan)?.confirmedMeetingCount, 3)
    }

    /// Overwrites one held person's saved record with bytes that don't decode,
    /// through a second connection to the temp target database.
    private func corruptHeldRecord(of profileId: UUID, in fixture: Fixture) throws {
        let path = fixture.root.appendingPathComponent("state/speakers_test-level.sqlite").path
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            sqlite3_close(db)
            throw XCTSkip("could not open the temp target database")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5_000)
        let sql = "UPDATE speaker_voiceprint_migrations SET held_record = 'not json' WHERE profile_id = '\(profileId.uuidString)';"
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_changes(db), 1)
    }

    func testInventoryCountsEachPersonsClipsMeetingsAndSpeech() async throws {
        let fixture = try makeFixture()
        let embedder = LevelEmbedder()
        let migration = try SpeakerVoiceprintMigration(
            sourceDatabaseURL: fixture.sourceURL,
            targetDatabase: makeTarget(fixture, embedder),
            embedder: embedder,
            sources: fixture.sources
        )

        let inventory = try await migration.inventory()
        let byId = Dictionary(uniqueKeysWithValues: inventory.people.map { ($0.profileId, $0) })

        XCTAssertEqual(Set(byId.keys), fixture.namedIds)
        let ann = try XCTUnwrap(byId[fixture.ann])
        XCTAssertEqual(ann.clipSeconds, 6, accuracy: 0.01)
        XCTAssertEqual(ann.meetingsNamingThem, 2)
        XCTAssertEqual(ann.confirmedMeetings, 2)
        XCTAssertEqual(ann.meetingsWithAudio, 2)
        // Mic 00:00+00:20 run: 1..28 s (27 s). Import: 1..12 and 21..28 (18 s).
        XCTAssertEqual(ann.meetingSpeechSeconds, 45, accuracy: 0.01)
        XCTAssertEqual(ann.confirmations, 5)

        let dan = try XCTUnwrap(byId[fixture.dan])
        XCTAssertEqual(dan.clipSeconds, 0)
        XCTAssertEqual(dan.meetingsNamingThem, 2)
        XCTAssertEqual(dan.confirmedMeetings, 1, "confirmed in meeting 3 only")
        XCTAssertEqual(dan.meetingSpeechSeconds, 29, accuracy: 0.01)

        XCTAssertEqual(try XCTUnwrap(byId[fixture.bob]).meetingSpeechSeconds, 7, accuracy: 0.01)
        XCTAssertFalse(try XCTUnwrap(byId[fixture.cat]).hasUsableAudio)
        XCTAssertEqual(inventory.fractionWithUsableAudio, 0.8, accuracy: 1e-9)
        XCTAssertEqual(embedder.calls, 0, "the inventory embeds nothing")
    }

    func testCompressedStereoRetainedAudioReadsAsSixteenKilohertzMono() throws {
        // Retained meeting audio is kept as .m4a after save; the call side is 48 kHz.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceprint-migration-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("system_audio.m4a")
        let sampleRate = 48_000.0
        do {
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2))
            let frames = Int(30 * sampleRate)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
            buffer.frameLength = AVAudioFrameCount(frames)
            let channels = try XCTUnwrap(buffer.floatChannelData)
            for channel in 0..<2 {
                channels[channel].update(repeating: 0, count: frames)
                for frame in Int(10 * sampleRate)..<Int(20 * sampleRate) {
                    channels[channel][frame] = 0.3 * sinf(2 * .pi * 440 * Float(frame) / Float(sampleRate))
                }
            }
            let writer = try AVAudioFile(
                forWriting: url,
                settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 96_000,
                ],
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            try writer.write(from: buffer)
        }

        let file = try XCTUnwrap(SpeakerVoiceprintAudioReader.open(url))
        let voiced = try XCTUnwrap(SpeakerVoiceprintAudioReader.samples(from: file, range: .init(start: 11, end: 19)))
        XCTAssertEqual(Double(voiced.count), 8 * 16_000, accuracy: 16)
        var rms: Float = 0
        vDSP_rmsqv(voiced, 1, &rms, vDSP_Length(voiced.count))
        XCTAssertEqual(Double(rms), 0.3 / 2.0.squareRoot(), accuracy: 0.03)
        XCTAssertNil(SpeakerVoiceprintAudioReader.samples(from: file, range: .init(start: 23, end: 29)), "silence is not a voice")
        XCTAssertNil(SpeakerVoiceprintAudioReader.samples(from: file, range: .init(start: 40, end: 45)), "past the end")
    }

    // MARK: - Policy

    func testTranscriptRowsBecomeRangesOnTheirOwnTrack() {
        typealias Row = SpeakerVoiceprintMigrationPolicy.TranscriptRow
        let rows = [
            Row(start: 0, channel: .system, label: "Ann"),
            Row(start: 3, channel: .mic, label: "You"),        // other track: doesn't end Ann's turn
            Row(start: 6, channel: .system, label: "Ann"),     // joins the same run
            Row(start: 30, channel: .system, label: "Bob"),
            Row(start: 40, channel: .system, label: "Ann"),
            Row(start: 41, channel: .system, label: "Bob"),    // leaves Ann under the minimum
        ]
        let ranges = SpeakerVoiceprintMigrationPolicy.ranges(
            forLabels: ["Ann"], on: .system, rows: rows,
            limits: .init(leadTrimSeconds: 1, minSeconds: 1.5, maxSeconds: 15, openEndSeconds: 8, maxTotalSeconds: 60)
        )
        XCTAssertEqual(ranges, [.init(start: 1, end: 16), .init(start: 16, end: 30)])

        let capped = SpeakerVoiceprintMigrationPolicy.ranges(
            forLabels: ["Ann"], on: .system, rows: rows,
            limits: .init(leadTrimSeconds: 1, minSeconds: 1.5, maxSeconds: 15, openEndSeconds: 8, maxTotalSeconds: 20)
        )
        XCTAssertEqual(capped.reduce(0) { $0 + $1.seconds }, 20, accuracy: 1e-9)
    }

    func testSavedTranscriptRowsParseInBothBodyForms() {
        let raw = SpeakerVoiceprintTranscriptScan.transcriptRows(in: """
        ---
        capture_type: meeting
        ---

        [01:05] [System/[[Ann Lee]]] hi
        [1:02:03] [Mic/You] ok
        - **Ann Lee:** 3 utterances
        """)
        XCTAssertEqual(raw, [
            .init(start: 65, channel: .system, label: "Ann Lee"),
            .init(start: 3723, channel: .mic, label: "You"),
        ])
        let styled = SpeakerVoiceprintTranscriptScan.transcriptRows(in: "**00:04**  [System/Bob] Jr]\nHello\n")
        XCTAssertEqual(styled, [.init(start: 4, channel: .system, label: "Bob] Jr")])
    }

    func testQualityGateNeedsAMajorityOfAgreeingSessions() throws {
        typealias Piece = SpeakerVoiceprintMigrationPolicy.Piece
        let a = LevelEmbedder.vector(level: 0.1)
        let b = LevelEmbedder.vector(level: 0.2)
        func session(_ vectors: [[Float]]) -> [Piece] { vectors.map { Piece(embedding: $0, seconds: 5) } }

        let twoOfThree = try XCTUnwrap(SpeakerVoiceprintMigrationPolicy.assess(
            sessions: [session([a]), session([b]), session([a])], agreementBar: 0.55
        ))
        XCTAssertTrue(twoOfThree.isConsistent)
        XCTAssertEqual(twoOfThree.agreeingSessions, [0, 2])
        XCTAssertGreaterThan(SpeakerVectorMath.cosineSimilarity(twoOfThree.centroid, a), 0.99, "the outlier stays out")

        let split = try XCTUnwrap(SpeakerVoiceprintMigrationPolicy.assess(
            sessions: [session([a]), session([b])], agreementBar: 0.55
        ))
        XCTAssertFalse(split.isConsistent)

        let oneSessionAgreeing = try XCTUnwrap(SpeakerVoiceprintMigrationPolicy.assess(
            sessions: [session([a, a, a])], agreementBar: 0.55
        ))
        XCTAssertTrue(oneSessionAgreeing.isConsistent)

        let onePiece = try XCTUnwrap(SpeakerVoiceprintMigrationPolicy.assess(
            sessions: [session([a])], agreementBar: 0.55
        ))
        XCTAssertFalse(onePiece.isConsistent)
        XCTAssertNil(onePiece.selfSimilarity)

        XCTAssertNil(SpeakerVoiceprintMigrationPolicy.assess(sessions: [], agreementBar: 0.55))
    }
}
