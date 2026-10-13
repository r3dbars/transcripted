import Accelerate
import AVFoundation
import Foundation
import XCTest
@testable import TranscriptedCore

/// Promises for naming a speaker in a meeting the app didn't record itself:
///   - no embedder, no retained audio, or silent audio → transcript-only, no
///     person is created;
///   - usable retained audio + the active embedder → a voiceprint is written
///     (new person, or taught to a picked person / a same-named person whose
///     voice already clears the model's match floor);
///   - a typed name with no picker choice never teaches the busiest same-name
///     person, and never teaches a same-name person whose voice is far away;
///   - the transcript file is never given a biometric sidecar.
@available(macOS 14.0, *)
final class SpeakerTranscriptVoiceprintEnrollmentTests: XCTestCase {

    final class LevelEmbedder: SpeakerSegmentEmbedder, @unchecked Sendable {
        let dimension = 8
        let identifier = "test-level-voiceprint"
        let thresholds = SpeakerEmbeddingThresholds.eRes2Net

        func embed(samples: [Float], sampleRate: Int) -> [Float]? {
            guard sampleRate == 16_000, !samples.isEmpty else { return nil }
            var mean: Float = 0
            vDSP_meanv(samples, 1, &mean, vDSP_Length(samples.count))
            let slot = Int((mean * 10).rounded())
            guard (1..<dimension).contains(slot) else { return nil }
            return Self.vector(slot: slot)
        }

        static func vector(slot: Int, dimension: Int = 8) -> [Float] {
            var vector = [Float](repeating: 0, count: dimension)
            vector[0] = 0.1
            vector[slot] = 1
            return SpeakerVectorMath.l2Normalize(vector)
        }
    }

    func testMissingAudioOrEmbedderStaysTranscriptOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("enroll-none-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let db = SpeakerDatabase(path: root.appendingPathComponent("speakers.sqlite").path)
        let markdown = importedMarkdown(name: "Speaker 2")

        XCTAssertEqual(
            SpeakerTranscriptVoiceprintEnrollment.enroll(
                name: "Stephen",
                embedding: nil,
                targetProfileID: nil,
                transcriptID: UUID(),
                speakerDB: db,
                thresholds: LevelEmbedder().thresholds
            ),
            .transcriptOnly
        )
        XCTAssertTrue(db.allSpeakers().isEmpty)

        let tracks = SpeakerTranscriptVoiceprintEnrollment.tracks(fromAudioURLs: [])
        XCTAssertTrue(tracks.isEmpty)
        XCTAssertNil(
            SpeakerTranscriptVoiceprintEnrollment.embedding(
                markdown: markdown,
                labels: ["Speaker 2"],
                channel: .system,
                tracks: tracks,
                embedder: LevelEmbedder()
            )
        )
    }

    func testRetainedImportAudioWritesAVoiceprint() throws {
        let fixture = try makeImportedMeeting(level: 0.1)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let embedder = LevelEmbedder()
        let tracks = SpeakerTranscriptVoiceprintEnrollment.tracks(fromAudioURLs: [fixture.recordingURL])
        XCTAssertEqual(tracks[.system], fixture.recordingURL)
        XCTAssertNil(tracks[.mic])

        let embedding = try XCTUnwrap(
            SpeakerTranscriptVoiceprintEnrollment.embedding(
                markdown: fixture.markdown,
                labels: ["Speaker 2"],
                channel: .system,
                tracks: tracks,
                embedder: embedder
            )
        )
        XCTAssertGreaterThan(
            SpeakerVectorMath.cosineSimilarity(embedding, LevelEmbedder.vector(slot: 1)),
            0.99
        )

        let db = SpeakerDatabase(path: fixture.root.appendingPathComponent("speakers.sqlite").path)
        let transcriptID = UUID(uuidString: "00000000-0000-0000-0000-00000000A011")!
        let outcome = SpeakerTranscriptVoiceprintEnrollment.enroll(
            name: "Stephen",
            embedding: embedding,
            targetProfileID: nil,
            transcriptID: transcriptID,
            speakerDB: db,
            thresholds: embedder.thresholds
        )
        guard case .enrolled(let id) = outcome else {
            return XCTFail("expected a new person, got \(outcome)")
        }
        let profile = try XCTUnwrap(db.getSpeaker(id: id))
        XCTAssertEqual(profile.displayName, "Stephen")
        XCTAssertEqual(profile.nameSource, NameSource.userManual)
        XCTAssertEqual(profile.confirmedMeetingCount, 1)
        XCTAssertGreaterThan(
            SpeakerVectorMath.cosineSimilarity(profile.embedding, LevelEmbedder.vector(slot: 1)),
            0.99
        )
    }

    func testSameTypedNameWithCloseVoiceTeachesTheExistingPerson() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("enroll-teach-close-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let db = SpeakerDatabase(path: root.appendingPathComponent("speakers.sqlite").path)
        let existing = try seedPerson(named: "Stephen", slot: 1, callCount: 1, in: db)

        let outcome = SpeakerTranscriptVoiceprintEnrollment.enroll(
            name: "stephen",
            embedding: LevelEmbedder.vector(slot: 1),
            targetProfileID: nil,
            transcriptID: UUID(),
            speakerDB: db,
            thresholds: LevelEmbedder().thresholds
        )
        XCTAssertEqual(outcome, .taught(existing.id))
        XCTAssertEqual(db.allSpeakers().count, 1, "a matching same-named person must not be duplicated")
        XCTAssertEqual(db.getSpeaker(id: existing.id)?.displayName, "Stephen")
        XCTAssertEqual(db.getSpeaker(id: existing.id)?.callCount, 2)
    }

    func testSameTypedNameWithFarVoiceCreatesANewPerson() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("enroll-teach-far-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let db = SpeakerDatabase(path: root.appendingPathComponent("speakers.sqlite").path)
        let existing = try seedPerson(named: "Stephen", slot: 1, callCount: 3, in: db)
        let far = LevelEmbedder.vector(slot: 2)
        XCTAssertLessThan(
            SpeakerVectorMath.bestSimilarity(
                candidate: far,
                average: existing.embedding,
                exemplars: existing.exemplars
            ),
            LevelEmbedder().thresholds.matchManySegments
        )

        let outcome = SpeakerTranscriptVoiceprintEnrollment.enroll(
            name: "stephen",
            embedding: far,
            targetProfileID: nil,
            transcriptID: UUID(),
            speakerDB: db,
            thresholds: LevelEmbedder().thresholds
        )
        guard case .enrolled(let createdID) = outcome else {
            return XCTFail("a far same-name voice must mint a new person, got \(outcome)")
        }
        XCTAssertNotEqual(createdID, existing.id)
        XCTAssertEqual(db.allSpeakers().count, 2)
        XCTAssertEqual(db.getSpeaker(id: existing.id)?.callCount, 3, "the existing person must not be taught")
        XCTAssertGreaterThan(
            SpeakerVectorMath.cosineSimilarity(
                try XCTUnwrap(db.getSpeaker(id: existing.id)?.embedding),
                LevelEmbedder.vector(slot: 1)
            ),
            0.99,
            "the existing voiceprint must not be blended with the new voice"
        )
        XCTAssertEqual(db.getSpeaker(id: createdID)?.displayName, "stephen")
        XCTAssertEqual(db.getSpeaker(id: createdID)?.callCount, 1)
    }

    func testTwoSameNamePeopleTeachesTheClosestVoiceNotTheMostCalls() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("enroll-two-daniels-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let db = SpeakerDatabase(path: root.appendingPathComponent("speakers.sqlite").path)
        let wrongDaniel = try seedPerson(named: "Daniel", slot: 3, callCount: 5, in: db)
        let rightDaniel = try seedPerson(named: "Daniel", slot: 1, callCount: 1, in: db)
        let newVoice = LevelEmbedder.vector(slot: 1)
        let bars = LevelEmbedder().thresholds
        XCTAssertLessThan(
            SpeakerVectorMath.bestSimilarity(
                candidate: newVoice,
                average: wrongDaniel.embedding,
                exemplars: wrongDaniel.exemplars
            ),
            bars.matchManySegments
        )
        XCTAssertGreaterThan(
            SpeakerVectorMath.bestSimilarity(
                candidate: newVoice,
                average: rightDaniel.embedding,
                exemplars: rightDaniel.exemplars
            ),
            bars.matchManySegments
        )

        let outcome = SpeakerTranscriptVoiceprintEnrollment.enroll(
            name: "Daniel",
            embedding: newVoice,
            targetProfileID: nil,
            transcriptID: UUID(),
            speakerDB: db,
            thresholds: bars
        )
        XCTAssertEqual(outcome, .taught(rightDaniel.id), "the closer voice must be taught, not the busier Daniel")
        XCTAssertEqual(db.allSpeakers().count, 2, "must reuse a same-name person, not mint a third")
        XCTAssertEqual(db.getSpeaker(id: wrongDaniel.id)?.callCount, 5, "the busy wrong voice must stay untouched")
        XCTAssertEqual(db.getSpeaker(id: rightDaniel.id)?.callCount, 2)
        XCTAssertGreaterThan(
            SpeakerVectorMath.cosineSimilarity(
                try XCTUnwrap(db.getSpeaker(id: wrongDaniel.id)?.embedding),
                LevelEmbedder.vector(slot: 3)
            ),
            0.99,
            "the busy Daniel's voiceprint must not be poisoned"
        )
    }

    func testPickedPersonIsTaughtEvenWhenTheTypedNameDiffers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("enroll-pick-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let db = SpeakerDatabase(path: root.appendingPathComponent("speakers.sqlite").path)
        let picked = db.addOrUpdateSpeaker(embedding: LevelEmbedder.vector(slot: 1), existingId: nil)
        db.setDisplayName(id: picked.id, name: "Alex", source: NameSource.userManual)

        let outcome = SpeakerTranscriptVoiceprintEnrollment.enroll(
            name: "Jordan",
            embedding: LevelEmbedder.vector(slot: 2),
            targetProfileID: picked.id,
            transcriptID: nil,
            speakerDB: db,
            thresholds: LevelEmbedder().thresholds
        )
        XCTAssertEqual(outcome, .taught(picked.id))
        XCTAssertEqual(db.getSpeaker(id: picked.id)?.displayName, "Alex", "teaching must not rename the picked person")
        XCTAssertTrue(db.allSpeakers().allSatisfy { $0.displayName != "Jordan" })
    }

    func testPlaybackMixIsNotUsedAsAVoiceprintSource() {
        let playback = URL(fileURLWithPath: "/tmp/audio/playback.m4a")
        let tracks = SpeakerTranscriptVoiceprintEnrollment.tracks(fromAudioURLs: [playback])
        XCTAssertTrue(tracks.isEmpty, "the mix is not a single voice")
    }

    private struct ImportedMeeting {
        let root: URL
        let recordingURL: URL
        let markdown: String
    }

    private func makeImportedMeeting(level: Float) throws -> ImportedMeeting {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("enroll-audio-\(UUID().uuidString)")
        let audioDir = root.appendingPathComponent("audio/imported_audio")
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        let recordingURL = audioDir.appendingPathComponent("recording.wav")
        try writeTrack(recordingURL, seconds: 8, segments: [(0, 8, level)])
        return ImportedMeeting(
            root: root,
            recordingURL: recordingURL,
            markdown: importedMarkdown(name: "Speaker 2")
        )
    }

    private func seedPerson(
        named name: String,
        slot: Int,
        callCount: Int,
        in db: SpeakerDatabase
    ) throws -> SpeakerProfile {
        XCTAssertGreaterThanOrEqual(callCount, 1)
        let embedding = LevelEmbedder.vector(slot: slot)
        var profile = db.addOrUpdateSpeaker(embedding: embedding, existingId: nil)
        db.setDisplayName(id: profile.id, name: name, source: NameSource.userManual)
        for _ in 1..<callCount {
            profile = db.addOrUpdateSpeaker(embedding: embedding, existingId: profile.id)
        }
        let saved = try XCTUnwrap(db.getSpeaker(id: profile.id))
        XCTAssertEqual(saved.callCount, callCount)
        XCTAssertEqual(saved.displayName, name)
        return saved
    }

    private func importedMarkdown(name: String) -> String {
        """
        ---
        title: "Imported"
        capture_type: meeting
        transcript_id: "00000000-0000-0000-0000-00000000A011"
        speakers:
          - id: "2"
            channel: system
            name: "\(name)"
            source: unknown
        ---

        ## Transcript

        **00:00**  [System/\(name)]
        Hello from an imported meeting.

        **00:06**  [System/\(name)]
        Still talking.
        """
    }

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
}
