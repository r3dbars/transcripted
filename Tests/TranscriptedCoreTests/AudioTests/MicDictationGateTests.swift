import XCTest
import AVFoundation
@testable import TranscriptedCore

/// Lock-owned list of first samples from callbacks that arrive off the test thread.
private final class LockedSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [[Float]] = []

    var value: [[Float]] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let samples = Array(UnsafeBufferPointer(
            start: buffer.floatChannelData![0],
            count: Int(buffer.frameLength)
        ))
        lock.lock()
        stored.append(samples)
        lock.unlock()
    }
}

/// Promise: dictated audio during a meeting is silent in the saved meeting
/// mic track. While dictation borrows the meeting mic, the saved WAV and the
/// live preview get silence of the same length (so the mic track stays aligned
/// with system audio), and the borrowing consumer still gets the real words.
final class MicDictationGateTests: XCTestCase {
    private static let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
    )!
    private static let frames: AVAudioFrameCount = 128

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MicDictationGateTests-\(UUID().uuidString)", isDirectory: true)
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

    /// A buffer that is loud on every frame, so a single surviving sample
    /// would show up in the saved track.
    private func makeSpeech(level: Float) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: Self.frames)!
        buffer.frameLength = Self.frames
        let samples = buffer.floatChannelData![0]
        for frame in 0..<Int(Self.frames) {
            samples[frame] = frame.isMultiple(of: 2) ? level : -level
        }
        return buffer
    }

    private struct Harness {
        let audio: Audio
        let url: URL
        let writer: AVAudioFile
        let writeContext: MicPCMWriteContext
    }

    private func startRecording(root: URL) throws -> Harness {
        let audio = makeAudio(root: root)
        audio.prepareForNewRecordingStart()
        // Keep the saved samples equal to the input so values are exact.
        audio.realtimeAGC = nil
        let generation = audio.recordingSessionGeneration
        let url = root.appendingPathComponent("mic.wav")
        let writer = try AVAudioFile(
            forWriting: url,
            settings: Self.format.settings,
            commonFormat: Self.format.commonFormat,
            interleaved: Self.format.isInterleaved
        )
        XCTAssertTrue(
            audio.micAudioFileOwnership.installSessionWriter(writer, generation: generation).didInstall
        )
        return Harness(
            audio: audio,
            url: url,
            writer: writer,
            writeContext: MicPCMWriteContext(generation: generation, monoFormat: Self.format, inputChannelCount: 1)
        )
    }

    private func savedSamples(_ harness: Harness) throws -> [Float] {
        harness.audio.micAudioFileQueue.sync {}
        harness.writer.close()
        let saved = try AVAudioFile(forReading: harness.url)
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: saved.processingFormat,
            frameCapacity: AVAudioFrameCount(saved.length)
        ))
        try saved.read(into: pcm)
        return Array(UnsafeBufferPointer(start: pcm.floatChannelData![0], count: Int(pcm.frameLength)))
    }

    func testDictationWhileMeetingRecordsIsSilentInSavedMicTrack() async throws {
        let harness = try startRecording(root: try makeRoot())
        let audio = harness.audio
        let borrowed = LockedSamples()
        audio.onMicPCMBuffer = { borrowed.append($0) }
        defer { audio.onMicPCMBuffer = nil }

        // Meeting speech, then dictation borrows the mic, then meeting again.
        audio.handleMicBuffer(makeSpeech(level: 0.25), writeContext: harness.writeContext)
        audio.isMicGatedForBorrowedDictation = true
        audio.handleMicBuffer(makeSpeech(level: 0.5), writeContext: harness.writeContext)
        audio.handleMicBuffer(makeSpeech(level: 0.5), writeContext: harness.writeContext)
        audio.isMicGatedForBorrowedDictation = false
        audio.handleMicBuffer(makeSpeech(level: 0.75), writeContext: harness.writeContext)
        await audio.flushMicHostPCMBufferFanout()

        let saved = try savedSamples(harness)
        let n = Int(Self.frames)
        XCTAssertEqual(saved.count, 4 * n, "Gated time must stay in the track as silence, not be cut out")
        XCTAssertEqual(saved[0..<n].map(abs).max() ?? 0, 0.25, accuracy: 0.0001, "Meeting speech before dictation is kept")
        XCTAssertEqual(saved[n..<(3 * n)].map(abs).max(), 0, "Dictated words must not reach the saved mic track")
        XCTAssertEqual(saved[(3 * n)...].map(abs).max() ?? 0, 0.75, accuracy: 0.0001, "Meeting speech after dictation is kept")

        // Dictation still hears the real words.
        let delivered = borrowed.value
        XCTAssertEqual(delivered.count, 4)
        XCTAssertEqual(delivered[1].map(abs).max() ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(delivered[2].map(abs).max() ?? 0, 0.5, accuracy: 0.0001)
    }

    func testGateDoesNotLookLikeASilentMic() async throws {
        let harness = try startRecording(root: try makeRoot())
        let audio = harness.audio
        audio.isMicGatedForBorrowedDictation = true
        for _ in 0..<4 {
            audio.handleMicBuffer(makeSpeech(level: 0.5), writeContext: harness.writeContext)
        }
        _ = try savedSamples(harness)

        // The meter and watchdog keep seeing a live mic, so the silent-mic
        // warning and the watchdog's no-buffer recovery don't fire.
        XCTAssertEqual(audio.micBufferCount, 4)
        XCTAssertGreaterThan(audio.lastBufferTime, 0)
        let peaks = audio.signalDiagnosticsSnapshot
        XCTAssertEqual(peaks.micRawPeak, 0.5, accuracy: 0.0001)
        XCTAssertEqual(peaks.micProcessedPeak, 0.5, accuracy: 0.0001, "Signal health reads the real mic, not the gated track")
    }
}
