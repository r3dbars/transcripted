import AVFoundation
import Combine
import FluidAudio
import XCTest
@testable import TranscriptedCore

@available(macOS 14.0, *)
@MainActor
final class TranscriptionTaskManagerRecoveryTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecoveryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
    }

    func testRecoversOrphanedRecordingWithCorruptHeader() async throws {
        let (manager, paths) = makeManager()

        let micURL = paths.audioCaptures.appendingPathComponent("meeting_crash_mic.wav")
        try writeMonoWAV(to: micURL, sampleRate: 48_000, samples: Array(repeating: 0.5, count: 9_600))
        try corruptHeaderSizes(at: micURL)
        try backdate(micURL)
        XCTAssertEqual(try AVAudioFile(forReading: micURL).length, 0)

        let startedAt = Date(timeIntervalSince1970: 1_750_000_000)
        let journalURL = try writeJournal(
            in: paths.audioCaptures,
            primaryMicFilename: "meeting_crash_mic.wav",
            segments: [.init(filename: "meeting_crash_mic.wav", gapBefore: 0)],
            startedAt: startedAt
        )

        let recovered = await manager.recoverOrphanedRecordings(in: paths.audioCaptures)

        XCTAssertEqual(recovered, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))

        let entry = try XCTUnwrap(manager.failedTranscriptionManager.failedTranscriptions.first)
        XCTAssertEqual(entry.micAudioURL, micURL)
        XCTAssertEqual(entry.recordingDate, startedAt)
        XCTAssertTrue(entry.isRetryable)

        // The header repair must make the recovered audio actually readable.
        XCTAssertEqual(try AVAudioFile(forReading: micURL).length, 9_600)
    }

    func testSkipsJournalWhoseAudioIsRecentlyWritten() async throws {
        let (manager, paths) = makeManager()

        let micURL = paths.audioCaptures.appendingPathComponent("meeting_live_mic.wav")
        try writeMonoWAV(to: micURL, sampleRate: 48_000, samples: Array(repeating: 0.5, count: 4_800))
        // No backdating: the file looks actively written, as it would if a
        // second Transcripted process were recording into the shared scratch.
        let journalURL = try writeJournal(
            in: paths.audioCaptures,
            primaryMicFilename: "meeting_live_mic.wav",
            segments: [.init(filename: "meeting_live_mic.wav", gapBefore: 0)],
            startedAt: Date()
        )

        let recovered = await manager.recoverOrphanedRecordings(in: paths.audioCaptures)

        XCTAssertEqual(recovered, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path))
        XCTAssertTrue(manager.failedTranscriptionManager.failedTranscriptions.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: micURL.path))
    }

    func testRemovesStaleJournalWithNoAudio() async throws {
        let (manager, paths) = makeManager()

        let journalURL = try writeJournal(
            in: paths.audioCaptures,
            primaryMicFilename: "meeting_gone_mic.wav",
            segments: [.init(filename: "meeting_gone_mic.wav", gapBefore: 0)],
            startedAt: Date(timeIntervalSince1970: 1_000)
        )

        let recovered = await manager.recoverOrphanedRecordings(in: paths.audioCaptures)

        XCTAssertEqual(recovered, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
        XCTAssertTrue(manager.failedTranscriptionManager.failedTranscriptions.isEmpty)
    }

    func testRecoversMultiSegmentRecordingByMerging() async throws {
        let (manager, paths) = makeManager()

        let primaryURL = paths.audioCaptures.appendingPathComponent("meeting_multi_mic.wav")
        let recoveryURL = paths.audioCaptures.appendingPathComponent("meeting_multi_mic_recovery.wav")
        try writeMonoWAV(to: primaryURL, sampleRate: 48_000, samples: Array(repeating: 0.3, count: 4_800))
        try writeMonoWAV(to: recoveryURL, sampleRate: 48_000, samples: Array(repeating: 0.6, count: 4_800))
        try backdate(primaryURL)
        try backdate(recoveryURL)

        _ = try writeJournal(
            in: paths.audioCaptures,
            primaryMicFilename: "meeting_multi_mic.wav",
            segments: [
                .init(filename: "meeting_multi_mic.wav", gapBefore: 0),
                .init(filename: "meeting_multi_mic_recovery.wav", gapBefore: 0.1)
            ],
            startedAt: Date(timeIntervalSince1970: 1_000)
        )

        let recovered = await manager.recoverOrphanedRecordings(in: paths.audioCaptures)

        XCTAssertEqual(recovered, 1)
        let entry = try XCTUnwrap(manager.failedTranscriptionManager.failedTranscriptions.first)
        XCTAssertEqual(entry.micAudioURL.lastPathComponent, "meeting_multi_mic_merged.wav")

        let merged = try AVAudioFile(forReading: entry.micAudioURL)
        XCTAssertGreaterThan(merged.length, 3_000)
    }

    func testLateJournalWriteAfterRecoveryHandoffDoesNotDuplicateFailedEntry() async throws {
        let (manager, paths) = makeManager()

        let micURL = paths.audioCaptures.appendingPathComponent("meeting_dup_mic.wav")
        try writeMonoWAV(to: micURL, sampleRate: 48_000, samples: Array(repeating: 0.5, count: 4_800))
        try backdate(micURL)

        // Go through a live store so its in-memory journal survives the
        // handoff the way it does in the app process.
        let store = MeetingRecordingJournalStore(directory: paths.audioCaptures)
        let session = store.begin(primaryMicURL: micURL)
        store.markStopping(session: session)
        store.flush()
        let journalURL = paths.audioCaptures.appendingPathComponent(
            "meeting_dup_mic" + MeetingRecordingJournalStore.filenameSuffix
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path))

        let recovered = await manager.recoverOrphanedRecordings(in: paths.audioCaptures)
        XCTAssertEqual(recovered, 1)
        XCTAssertEqual(manager.failedTranscriptionManager.failedTranscriptions.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))

        // A late stop-path write from the stale session (a timed-out bridge
        // stop finishing its merge) must not resurrect the journal...
        store.markFinalized(finalMicURL: micURL, session: session)
        store.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))

        // ...so the next scan finds nothing and the failed queue keeps a
        // single entry for this recording.
        let recoveredAgain = await manager.recoverOrphanedRecordings(in: paths.audioCaptures)
        XCTAssertEqual(recoveredAgain, 0)
        XCTAssertEqual(
            manager.failedTranscriptionManager.failedTranscriptions.count, 1,
            "a resurrected journal would re-recover the same audio into a duplicate failed-queue entry"
        )
    }

    // MARK: - Fixtures

    private func makeManager() -> (TranscriptionTaskManager, CoreStoragePaths) {
        let paths = CoreStoragePaths(
            transcripts: tempDirectory.appendingPathComponent("transcripts"),
            speakerDB: tempDirectory.appendingPathComponent("speakers.sqlite"),
            statsDB: tempDirectory.appendingPathComponent("stats.sqlite"),
            failedQueue: tempDirectory.appendingPathComponent("failed_transcriptions.json"),
            speakerClips: tempDirectory.appendingPathComponent("speaker_clips"),
            audioCaptures: tempDirectory.appendingPathComponent("audio"),
            logs: tempDirectory.appendingPathComponent("logs")
        )
        try? FileManager.default.createDirectory(at: paths.audioCaptures, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: paths.speakerClips, withIntermediateDirectories: true)

        let manager = TranscriptionTaskManager(
            failedTranscriptionManager: FailedTranscriptionManager(paths: paths),
            speechToText: RecoveryStubSpeechToTextEngine(),
            diarization: RecoveryStubDiarizationEngine(),
            speakerStore: SpeakerDatabase(path: paths.speakerDB.path),
            speakerClipsDirectory: paths.speakerClips,
            cleanupDirectories: [paths.audioCaptures, paths.speakerClips]
        )
        return (manager, paths)
    }

    private func writeJournal(
        in directory: URL,
        primaryMicFilename: String,
        segments: [MeetingRecordingJournal.SegmentRecord],
        startedAt: Date,
        state: MeetingRecordingJournal.State = .recording,
        systemAudioFilename: String? = nil
    ) throws -> URL {
        let journal = MeetingRecordingJournal(
            version: 1,
            state: state,
            startedAt: startedAt,
            updatedAt: startedAt,
            primaryMicFilename: primaryMicFilename,
            micSegments: segments,
            systemAudioFilename: systemAudioFilename,
            finalMicFilename: nil
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let stem = (primaryMicFilename as NSString).deletingPathExtension
        let url = directory.appendingPathComponent(stem + MeetingRecordingJournalStore.filenameSuffix)
        try encoder.encode(journal).write(to: url, options: .atomic)
        return url
    }

    private func backdate(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3_600)],
            ofItemAtPath: url.path
        )
    }

    private func corruptHeaderSizes(at url: URL) throws {
        let info = try WAVHeaderRepair.probe(at: url)
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let headerOnlyRIFFSize = UInt32(info.dataSizeFieldOffset - 4)
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: withUnsafeBytes(of: headerOnlyRIFFSize.littleEndian) { Data($0) })
        try handle.seek(toOffset: UInt64(info.dataSizeFieldOffset))
        try handle.write(contentsOf: Data([0, 0, 0, 0]))
    }

    private func writeMonoWAV(to url: URL, sampleRate: Double, samples: [Float]) throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ))
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channelData = try XCTUnwrap(buffer.floatChannelData?[0])
        samples.withUnsafeBufferPointer { pointer in
            guard let baseAddress = pointer.baseAddress else { return }
            channelData.update(from: baseAddress, count: samples.count)
        }
        try file.write(from: buffer)
        file.close()
    }
}

@available(macOS 14.0, *)
@MainActor
private final class RecoveryStubSpeechToTextEngine: SpeechToTextEngine {
    nonisolated let objectWillChange = ObservableObjectPublisher()
    var isReady = true

    func initialize() async {}
    func transcribeSegment(samples: [Float], source: AudioSource) async throws -> String { "" }
    func cleanup() {}
}

@available(macOS 14.0, *)
@MainActor
private final class RecoveryStubDiarizationEngine: DiarizationEngine {
    nonisolated let objectWillChange = ObservableObjectPublisher()
    var isReady = true

    func initialize() async {}
    func diarizeOffline(samples: [Float], sampleRate: Int) async throws -> [SpeakerSegment] { [] }
    func diarizeOffline(audioURL: URL) async throws -> [SpeakerSegment] { [] }
    func cleanup() {}
}
