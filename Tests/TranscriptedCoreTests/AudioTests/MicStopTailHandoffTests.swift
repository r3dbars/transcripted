import XCTest
import AVFoundation
@testable import TranscriptedCore

/// Lock-owned counter for callbacks that may arrive off the test thread.
private final class LockedCount: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func advance() {
        lock.lock()
        stored += 1
        lock.unlock()
    }
}

/// Mic-side pin for the recording-end tail, the twin of
/// `SystemAudioStopTailHandoffTests`.
///
/// `Audio.stop()` advances the recording generation on the calling thread,
/// but the input tap is only removed later, on a background queue behind the
/// audio-graph lock. Until then the tap keeps delivering buffers it captured
/// before Stop, stamped with the old generation. Those used to be dropped at
/// the first line of `handleMicBuffer`, so the last words on the user's side
/// of every meeting could go missing. Two orderings keep them now:
///
/// 1. `micAudioWriteBackpressure.beginFinishing(...)` runs before the
///    generation advances, so the tail has an open admission to land in.
/// 2. `micAudioWriteBackpressure.close(...)` runs in `closeMicrophone`, on the
///    serial mic file queue, after the tap is torn down and behind every tail
///    write it admitted.
final class MicStopTailHandoffTests: XCTestCase {
    private static let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
    )!

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MicStopTailHandoffTests-\(UUID().uuidString)", isDirectory: true)
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

    private func makeBuffer(marker: Float, frames: AVAudioFrameCount = 128) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: frames)!
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        for frame in 0..<Int(frames) {
            samples[frame] = 0
        }
        samples[0] = marker
        return buffer
    }

    /// End-to-end through the real `Audio.stop()`: buffers the tap delivers
    /// after Stop but before teardown must be in the saved mic WAV, and must
    /// not reach the live host consumer for a session that has ended.
    func testStopWritesMicBuffersDeliveredBeforeTheTapIsTornDown() throws {
        let root = try makeRoot()
        let audio = makeAudio(root: root)
        audio.prepareForNewRecordingStart()
        // Keep the saved samples equal to the input so markers are exact.
        audio.realtimeAGC = nil
        let generation = audio.recordingSessionGeneration
        let writeContext = MicPCMWriteContext(
            generation: generation,
            monoFormat: Self.format,
            inputChannelCount: 1
        )

        let url = root.appendingPathComponent("mic.wav")
        let writer = try AVAudioFile(
            forWriting: url,
            settings: Self.format.settings,
            commonFormat: Self.format.commonFormat,
            interleaved: Self.format.isInterleaved
        )
        XCTAssertTrue(
            audio.micAudioFileOwnership.installSessionWriter(
                writer,
                generation: generation
            ).didInstall
        )

        let hostDeliveries = LockedCount()
        audio.onMicPCMBuffer = { _ in hostDeliveries.advance() }
        defer { audio.onMicPCMBuffer = nil }

        // No real input graph exists here: holding its serialization lock
        // stands in for a tap that has not been removed yet.
        let graphBlocked = expectation(description: "microphone graph blocked")
        let unblockGraph = DispatchSemaphore(value: 0)
        defer { unblockGraph.signal() }
        DispatchQueue.global(qos: .userInitiated).async {
            audio.withAudioGraphLock {
                graphBlocked.fulfill()
                _ = unblockGraph.wait(timeout: .now() + 5)
            }
        }
        wait(for: [graphBlocked], timeout: 1)

        let completed = expectation(description: "recording finalized")
        audio.onRecordingComplete = { _, _ in completed.fulfill() }
        audio.stop()
        XCTAssertNotEqual(
            audio.recordingSessionGeneration,
            generation,
            "stop() must have advanced the generation for this to exercise the tail path"
        )

        // The tap is still installed: these are the user's last words.
        audio.handleMicBuffer(makeBuffer(marker: 0.25), writeContext: writeContext)
        audio.handleMicBuffer(makeBuffer(marker: 0.5), writeContext: writeContext)

        unblockGraph.signal()
        wait(for: [completed], timeout: 5)

        let saved = try AVAudioFile(forReading: url)
        XCTAssertEqual(saved.length, 256, "Both tail buffers must reach the WAV before the writer closes")
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: saved.processingFormat, frameCapacity: 256))
        try saved.read(into: pcm)
        guard pcm.frameLength == 256 else {
            return XCTFail("Expected 256 saved frames before inspecting tail markers")
        }
        let samples = try XCTUnwrap(pcm.floatChannelData)[0]
        XCTAssertEqual(samples[0], 0.25, accuracy: 0.0001)
        XCTAssertEqual(samples[128], 0.5, accuracy: 0.0001)
        XCTAssertEqual(hostDeliveries.value, 0, "The ended session's live consumer must not see the tail")

        // Once cleanup has closed admission, a straggler is dropped and does
        // not leave bytes reserved against the next recording's budget.
        audio.handleMicBuffer(makeBuffer(marker: 0.75), writeContext: writeContext)
        audio.micAudioFileQueue.sync {}
        XCTAssertFalse(audio.micAudioWriteBackpressure.isFinishing(generation: generation))
        XCTAssertEqual(audio.micAudioWriteBackpressure.pendingBytesForTesting, 0)
        XCTAssertEqual(try AVAudioFile(forReading: url).length, 256)
    }

    /// A buffer from an older recording that was never stopped into
    /// finishing (a successor already began) must still be dropped.
    func testStaleBufferWithoutFinishingAdmissionIsDropped() throws {
        let root = try makeRoot()
        let audio = makeAudio(root: root)
        audio.prepareForNewRecordingStart()
        let oldGeneration = audio.recordingSessionGeneration
        let url = root.appendingPathComponent("old.wav")
        let writer = try AVAudioFile(
            forWriting: url,
            settings: Self.format.settings,
            commonFormat: Self.format.commonFormat,
            interleaved: Self.format.isInterleaved
        )
        XCTAssertTrue(
            audio.micAudioFileOwnership.installSessionWriter(
                writer,
                generation: oldGeneration
            ).didInstall
        )

        audio.prepareForNewRecordingStart()
        audio.handleMicBuffer(
            makeBuffer(marker: 0.25),
            writeContext: MicPCMWriteContext(
                generation: oldGeneration,
                monoFormat: Self.format,
                inputChannelCount: 1
            )
        )
        audio.micAudioFileQueue.sync {}
        writer.close()

        XCTAssertEqual(try AVAudioFile(forReading: url).length, 0)
        XCTAssertEqual(audio.micAudioWriteBackpressure.pendingBytesForTesting, 0)
    }

    // MARK: - Arming order

    /// The end-to-end test above delivers its tail after `stop()` returns, so
    /// it can't tell whether admission was armed a moment too late. Deliver
    /// one buffer at the exact instant the generation advances: that is the
    /// earliest a stale buffer can arrive, and it must still be saved.
    func testBufferDeliveredTheInstantTheGenerationAdvancesIsSaved() throws {
        let root = try makeRoot()
        let audio = makeAudio(root: root)
        audio.prepareForNewRecordingStart()
        audio.realtimeAGC = nil
        let generation = audio.recordingSessionGeneration
        let writeContext = MicPCMWriteContext(
            generation: generation,
            monoFormat: Self.format,
            inputChannelCount: 1
        )

        let url = root.appendingPathComponent("mic.wav")
        let writer = try AVAudioFile(
            forWriting: url,
            settings: Self.format.settings,
            commonFormat: Self.format.commonFormat,
            interleaved: Self.format.isInterleaved
        )
        XCTAssertTrue(
            audio.micAudioFileOwnership.installSessionWriter(
                writer,
                generation: generation
            ).didInstall
        )

        let advances = LockedCount()
        audio.afterRecordingSessionGenerationAdvanceForTesting = { [unowned audio] _ in
            advances.advance()
            audio.handleMicBuffer(self.makeBuffer(marker: 0.25), writeContext: writeContext)
        }
        defer { audio.afterRecordingSessionGenerationAdvanceForTesting = nil }

        let completed = expectation(description: "recording finalized")
        audio.onRecordingComplete = { _, _ in completed.fulfill() }
        audio.stop()
        audio.afterRecordingSessionGenerationAdvanceForTesting = nil
        XCTAssertEqual(advances.value, 1, "stop() must advance the generation exactly once")
        wait(for: [completed], timeout: 5)

        let saved = try AVAudioFile(forReading: url)
        XCTAssertEqual(saved.length, 128, "the buffer from the instant of the generation bump must be saved")
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: saved.processingFormat, frameCapacity: 128))
        try saved.read(into: pcm)
        guard pcm.frameLength == 128 else {
            return XCTFail("Expected 128 saved frames before inspecting the marker")
        }
        XCTAssertEqual(try XCTUnwrap(pcm.floatChannelData)[0][0], 0.25, accuracy: 0.0001)
    }
}
