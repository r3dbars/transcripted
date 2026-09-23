import XCTest
import Combine
@preconcurrency import AVFoundation
@testable import TranscriptedCore

@available(macOS 14.0, *)
private final class EarlyStopStubSystemAudioCapture: SystemAudioCaptureEngine, @unchecked Sendable {
    var diagnosticBackendName: String { "early_stop_stub" }
    var audioFormat: AVAudioFormat?
    var bufferSuccessRate: Double { 1 }
    var deliversOwnedAudioBuffers: Bool { true }
    var errorMessagePublisher: AnyPublisher<String?, Never> { Empty().eraseToAnyPublisher() }
    func prepare() throws {}
    func start(bufferCallback: @escaping (AVAudioPCMBuffer) -> Void) throws {}
    func stop() {}
    func stopSync() {}
}

/// Pins the handoff between `Audio.stop()` and a system-audio setup that is
/// still running on `systemAudioSetupQueue` when the user presses Stop.
///
/// Stop advances the recording generation, so the in-flight setup sees a
/// stale session and runs its abandoned-setup cleanup. That cleanup used to
/// close the writer, cancel the capture and delete the WAV even when Stop had
/// already resolved that same file and handed it to the pipeline. A meeting
/// stopped in its first instant then lost the other side of the call, and the
/// pipeline got a URL for a file that no longer existed.
///
/// The cleanup closure is private to the setup block, so these tests drive
/// the exact gate it consults (`mayDiscardAbandonedSetupFile`) in the two
/// orders the race can take.
@available(macOS 14.0, *)
final class SystemAudioEarlyStopHandoffTests: XCTestCase {
    private static let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
    )!

    private func makeAudio(root: URL) -> Audio {
        let paths = CoreStoragePaths(
            transcripts: root.appendingPathComponent("captures/meetings", isDirectory: true),
            speakerDB: root.appendingPathComponent("state/speakers.sqlite"),
            statsDB: root.appendingPathComponent("state/stats.sqlite"),
            failedQueue: root.appendingPathComponent("state/failed_transcriptions.json"),
            speakerClips: root.appendingPathComponent("tmp/recordings/speaker_clips", isDirectory: true),
            audioCaptures: root.appendingPathComponent("tmp/recordings", isDirectory: true),
            logs: root.appendingPathComponent("logs", isDirectory: true)
        )
        return Audio(paths: paths)
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SystemAudioEarlyStopHandoffTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("tmp/recordings", isDirectory: true),
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// Mirrors the setup block up to the point where the WAV is installed and
    /// a first slice of call audio has been written into it.
    private func installRecordingSystemFile(
        on audio: Audio,
        root: URL,
        frames: AVAudioFrameCount
    ) throws -> (attempt: SystemAudioCaptureStartAttempt, fileURL: URL) {
        audio.prepareForNewRecordingStart()
        let generation = audio.recordingSessionGeneration
        let fileURL = root.appendingPathComponent("tmp/recordings/meeting_early_stop_system.wav")
        let writer = try AVAudioFile(
            forWriting: fileURL,
            settings: Self.format.settings,
            commonFormat: Self.format.commonFormat,
            interleaved: Self.format.isInterleaved
        )
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: frames))
        buffer.frameLength = frames
        for index in 0..<Int(frames) {
            buffer.floatChannelData![0][index] = 0.25
        }
        try writer.write(from: buffer)

        let attempt = SystemAudioCaptureStartAttempt(capture: EarlyStopStubSystemAudioCapture())
        audio.systemAudioFileQueue.sync {
            _ = audio.systemAudioCaptureAttemptOwnership.begin(
                generation: generation,
                capture: attempt
            )
            XCTAssertTrue(
                audio.systemAudioCaptureAttemptOwnership.install(
                    writer,
                    generation: generation,
                    capture: attempt,
                    fileURL: fileURL
                )
            )
        }
        return (attempt, fileURL)
    }

    private func stopAndAwaitSystemURL(_ audio: Audio) -> URL? {
        let completed = expectation(description: "recording finalized")
        var systemURL: URL?
        audio.onRecordingCompleteWithGeneration = { _, _, url, _ in
            systemURL = url
            completed.fulfill()
        }
        audio.stop()
        wait(for: [completed], timeout: 5)
        return systemURL
    }

    func testStopThatClaimedTheSystemFileKeepsItFromTheAbandonedSetup() throws {
        let root = try makeRoot()
        let audio = makeAudio(root: root)
        let (attempt, fileURL) = try installRecordingSystemFile(on: audio, root: root, frames: 480)

        let completed = expectation(description: "recording finalized")
        var systemURL: URL?
        audio.onRecordingCompleteWithGeneration = { _, _, url, _ in
            systemURL = url
            completed.fulfill()
        }
        audio.stop()

        // The setup now wakes on a stale generation and asks before it closes,
        // cancels or deletes. Stop already handed this file off.
        XCTAssertFalse(
            attempt.mayDiscardAbandonedSetupFile(fileURL),
            "an abandoned setup must not discard the WAV Stop is saving"
        )

        wait(for: [completed], timeout: 5)
        XCTAssertEqual(systemURL, fileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let saved = try AVAudioFile(forReading: fileURL)
        XCTAssertEqual(saved.length, 480, "the audio captured before Stop must survive")
    }

    func testSetupThatDiscardedFirstKeepsStopFromHandingOffTheFile() throws {
        let root = try makeRoot()
        let audio = makeAudio(root: root)
        let (attempt, fileURL) = try installRecordingSystemFile(on: audio, root: root, frames: 480)

        // The setup noticed the boundary first and has committed to deleting
        // its file. The file is still on disk here, so only the claim, not the
        // existence check, can keep Stop from handing the pipeline a WAV that
        // is about to disappear.
        XCTAssertTrue(attempt.mayDiscardAbandonedSetupFile(fileURL))

        let systemURL = stopAndAwaitSystemURL(audio)
        XCTAssertNil(systemURL, "Stop must report no system track instead of a file being deleted")
    }

    func testClaimsOnlyCoverTheSameFile() throws {
        let attempt = SystemAudioCaptureStartAttempt(capture: EarlyStopStubSystemAudioCapture())
        let root = try makeRoot()
        let claimed = root.appendingPathComponent("claimed.wav")
        let other = root.appendingPathComponent("other.wav")

        XCTAssertNil(attempt.handOffRecordedFileToStop { nil })
        XCTAssertTrue(
            attempt.mayDiscardAbandonedSetupFile(other),
            "a Stop that resolved nothing must not pin the setup's file"
        )

        let fresh = SystemAudioCaptureStartAttempt(capture: EarlyStopStubSystemAudioCapture())
        XCTAssertEqual(fresh.handOffRecordedFileToStop { claimed }, claimed)
        XCTAssertTrue(fresh.mayDiscardAbandonedSetupFile(other))
        XCTAssertFalse(fresh.mayDiscardAbandonedSetupFile(claimed))
    }
}
