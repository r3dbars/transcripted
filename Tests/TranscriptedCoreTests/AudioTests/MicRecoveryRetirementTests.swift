import XCTest
import AVFoundation
@testable import TranscriptedCore

/// Promise: when a mic recovery retires the segment it is replacing, that
/// segment's WAV is already closed by the time any later work on the mic file
/// queue runs. Stop's writer close and the segment merge both run behind that
/// queue, so a Stop that lands right after the retirement must read the
/// retired segment complete, never with an unpatched header.
final class MicRecoveryRetirementTests: XCTestCase {
    private static let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
    )!

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MicRecoveryRetirementTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func makeAudio(root: URL) -> Audio {
        Audio(paths: CoreStoragePaths(
            transcripts: root.appendingPathComponent("captures/meetings", isDirectory: true),
            speakerDB: root.appendingPathComponent("state/speakers.sqlite"),
            statsDB: root.appendingPathComponent("state/stats.sqlite"),
            failedQueue: root.appendingPathComponent("state/failed_transcriptions.json"),
            speakerClips: root.appendingPathComponent("tmp/recordings/speaker_clips", isDirectory: true),
            audioCaptures: root.appendingPathComponent("tmp/recordings", isDirectory: true),
            logs: root.appendingPathComponent("logs", isDirectory: true)
        ))
    }

    func testRetiredSegmentIsCompleteForTheNextMicQueueWork() throws {
        let root = try makeRoot()
        let audio = makeAudio(root: root)
        audio.prepareForNewRecordingStart()
        let generation = audio.recordingSessionGeneration

        let url = root.appendingPathComponent("meeting_test_mic.wav")
        let writer = try AVAudioFile(
            forWriting: url,
            settings: Self.format.settings,
            commonFormat: Self.format.commonFormat,
            interleaved: Self.format.isInterleaved
        )
        let frames: AVAudioFrameCount = 4_800
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: frames))
        buffer.frameLength = frames
        try writer.write(from: buffer)
        XCTAssertTrue(
            audio.micAudioFileOwnership.installSessionWriter(writer, generation: generation).didInstall
        )

        // Stands in for Stop reaching the mic file queue the moment the
        // retirement returns: its close and the merger read the file there.
        var lengthSeenByNextQueueWork: Int64?
        audio.afterMicRecoveryWriterRetiredForTesting = { [unowned audio] in
            audio.micAudioFileQueue.sync {
                lengthSeenByNextQueueWork = (try? AVAudioFile(forReading: url))?.length
            }
        }
        defer { audio.afterMicRecoveryWriterRetiredForTesting = nil }

        let retirement = audio.retireMicWriterForRecovery(sessionGeneration: generation)

        guard case .retired = retirement else {
            return XCTFail("The recording's own writer must be retired, got \(retirement)")
        }
        XCTAssertEqual(
            lengthSeenByNextQueueWork,
            Int64(frames),
            "Work queued right after retirement must see the retired segment's full length"
        )
        XCTAssertNil(audio.micAudioFileOwnership.writerOwned(by: generation))
    }

    func testRetirementLeavesAnotherRecordingsWriterAlone() throws {
        let root = try makeRoot()
        let audio = makeAudio(root: root)
        audio.prepareForNewRecordingStart()
        let staleGeneration = audio.recordingSessionGeneration
        audio.prepareForNewRecordingStart()
        let currentGeneration = audio.recordingSessionGeneration

        let url = root.appendingPathComponent("meeting_current_mic.wav")
        let writer = try AVAudioFile(
            forWriting: url,
            settings: Self.format.settings,
            commonFormat: Self.format.commonFormat,
            interleaved: Self.format.isInterleaved
        )
        XCTAssertTrue(
            audio.micAudioFileOwnership.installSessionWriter(writer, generation: currentGeneration).didInstall
        )

        let retirement = audio.retireMicWriterForRecovery(sessionGeneration: staleGeneration)

        guard case .notOwned = retirement else {
            return XCTFail("A stale recovery must not retire the current writer, got \(retirement)")
        }
        XCTAssertTrue(audio.micAudioFileOwnership.writerOwned(by: currentGeneration) === writer)
    }
}
