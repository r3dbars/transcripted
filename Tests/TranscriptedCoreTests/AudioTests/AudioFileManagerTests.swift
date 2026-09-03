import XCTest
import Combine
@preconcurrency import AVFoundation
import ScreenCaptureKit
@testable import TranscriptedCore

@available(macOS 14.0, *)
private final class URLResolutionStubSystemAudioCapture: SystemAudioCaptureEngine, @unchecked Sendable {
    var diagnosticBackendName: String { "url_resolution_stub" }
    var audioFormat: AVAudioFormat?
    var bufferSuccessRate: Double { 1 }
    var deliversOwnedAudioBuffers: Bool { true }
    var errorMessagePublisher: AnyPublisher<String?, Never> { Empty().eraseToAnyPublisher() }
    func prepare() throws {}
    func start(bufferCallback: @escaping (AVAudioPCMBuffer) -> Void) throws {}
    func stop() {}
    func stopSync() {}
}

@available(macOS 14.0, *)
final class AudioFileManagerTests: XCTestCase {
    private final class StubSystemCapture {}
    private final class StubSystemWriter {}

    func testSystemAudioStartFailureCopyReservesSettingsForExplicitDenial() {
        let denial = NSError(
            domain: SCStreamErrorDomain,
            code: SCStreamError.Code.userDeclined.rawValue
        )
        let transient = NSError(
            domain: SCStreamErrorDomain,
            code: SCStreamError.Code.failedToStart.rawValue
        )

        XCTAssertTrue(SystemAudioCaptureFailureCopy.message(for: denial).contains("System Settings"))
        XCTAssertFalse(SystemAudioCaptureFailureCopy.message(for: transient).contains("System Settings"))
        XCTAssertTrue(SystemAudioCaptureFailureCopy.isExplicitPermissionDenial(denial))
        XCTAssertFalse(SystemAudioCaptureFailureCopy.isExplicitPermissionDenial(transient))
        XCTAssertTrue(
            SystemAudioCaptureFailureCopy.message(for: transient)
                .localizedCaseInsensitiveContains("try recording again")
        )
    }

    func testSystemAudioStartFailureMarksStatusAndTypedStage() {
        let root = makeRoot(name: "SystemAudioStartFailure")
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = makeAudio(root: root)

        audio.systemAudioStatus = .healthy
        audio.systemAudioFailed = false

        audio.recordSystemAudioStartFailure()

        XCTAssertEqual(audio.systemAudioStatus, .failed)
        XCTAssertTrue(audio.systemAudioFailed)
        XCTAssertEqual(audio.startFailureStage, .systemAudio)
    }

    // MARK: - Test scaffolding

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

    private func makeRoot(name: String = "AudioFileManagerTests") -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    }

    func testSystemAudioCaptureAttemptOwnershipRejectsStaleWriterMutation() {
        let ownership =
            SystemAudioCaptureAttemptOwnership<StubSystemCapture, StubSystemWriter>()
        let oldCapture = StubSystemCapture()
        let newCapture = StubSystemCapture()
        let oldWriter = StubSystemWriter()
        let newWriter = StubSystemWriter()

        XCTAssertNil(ownership.begin(generation: 1, capture: oldCapture))
        XCTAssertTrue(
            ownership.install(
                oldWriter,
                generation: 1,
                capture: oldCapture,
                fileURL: URL(fileURLWithPath: "/tmp/old-system.wav")
            )
        )
        XCTAssertEqual(
            ownership.fileURLOwned(by: 1)?.lastPathComponent,
            "old-system.wav"
        )

        let displaced = ownership.begin(generation: 2, capture: newCapture)
        XCTAssertTrue(displaced?.capture === oldCapture)
        XCTAssertTrue(displaced?.writer === oldWriter)
        XCTAssertTrue(
            ownership.install(newWriter, generation: 2, capture: newCapture)
        )

        XCTAssertNil(ownership.takeWriterOwned(by: 1, capture: oldCapture))
        XCTAssertTrue(
            ownership.writerOwned(by: 2, capture: newCapture) === newWriter
        )
    }

    func testSystemAudioCaptureAttemptOwnershipKeepsOldStopAwayFromNewCapture() {
        let ownership =
            SystemAudioCaptureAttemptOwnership<StubSystemCapture, StubSystemWriter>()
        let oldCapture = StubSystemCapture()
        let newCapture = StubSystemCapture()

        XCTAssertNil(ownership.begin(generation: 10, capture: oldCapture))
        XCTAssertNil(ownership.begin(generation: 11, capture: newCapture)?.writer)

        XCTAssertNil(ownership.takeAttemptOwned(by: 10))
        XCTAssertTrue(ownership.captureOwned(by: 11) === newCapture)
    }

    func testSystemAudioStopInvalidationRejectsLateOldAttempt() {
        let ownership =
            SystemAudioCaptureAttemptOwnership<StubSystemCapture, StubSystemWriter>()
        let oldCapture = StubSystemCapture()

        XCTAssertNil(ownership.begin(generation: 10, capture: oldCapture))
        XCTAssertTrue(
            ownership.takeAttemptOwned(by: 10, invalidatingFor: 11)?.capture === oldCapture
        )
        XCTAssertNil(
            ownership.begin(generation: 10, capture: oldCapture),
            "an old start callback must not reclaim ownership after stop"
        )
    }

    func testSystemAudioCaptureAttemptOwnershipRejectsLateCallbackInstall() {
        let ownership =
            SystemAudioCaptureAttemptOwnership<StubSystemCapture, StubSystemWriter>()
        let lateCapture = StubSystemCapture()
        let currentCapture = StubSystemCapture()
        let lateWriter = StubSystemWriter()
        let currentWriter = StubSystemWriter()

        XCTAssertNil(ownership.begin(generation: 10, capture: lateCapture))
        XCTAssertNil(ownership.begin(generation: 11, capture: currentCapture)?.writer)
        XCTAssertNil(ownership.begin(generation: 10, capture: lateCapture))

        XCTAssertFalse(
            ownership.install(lateWriter, generation: 10, capture: lateCapture)
        )
        XCTAssertFalse(ownership.owns(generation: 10, capture: lateCapture))
        XCTAssertTrue(
            ownership.install(currentWriter, generation: 11, capture: currentCapture)
        )
        XCTAssertTrue(
            ownership.writerOwned(by: 11, capture: currentCapture) === currentWriter
        )
    }

    func testResolvedSystemAudioURLUsesOwnershipWhenPublishedURLIsNil() throws {
        let root = makeRoot(name: "ResolvedSystemURL")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = makeAudio(root: root)
        audio.prepareForNewRecordingStart()
        let generation = audio.recordingSessionGeneration
        let fileURL = root.appendingPathComponent("owned-system.wav")
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ))
        let writer = try AVAudioFile(
            forWriting: fileURL,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        let attempt = SystemAudioCaptureStartAttempt(
            capture: URLResolutionStubSystemAudioCapture()
        )
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
        audio.systemAudioFileURL = nil
        audio.originalSystemAudioFileURL = nil

        XCTAssertEqual(
            audio.resolvedSystemAudioFileURL(generation: generation),
            fileURL,
            "stop must read the system URL from ownership when the published URL is still nil"
        )
        writer.close()
    }

    func testSystemRecoverySilencePadWritesBoundedZeroFrames() throws {
        let root = makeRoot(name: "SilencePad")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = makeAudio(root: root)
        audio.prepareForNewRecordingStart()
        let generation = audio.recordingSessionGeneration
        let fileURL = root.appendingPathComponent("pad-system.wav")
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let writer = try AVAudioFile(
            forWriting: fileURL,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        let attempt = SystemAudioCaptureStartAttempt(
            capture: URLResolutionStubSystemAudioCapture()
        )
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

        audio.writeSystemRecoverySilencePad(duration: 0.25, generation: generation)
        writer.close()

        let saved = try AVAudioFile(forReading: fileURL)
        XCTAssertEqual(saved.fileFormat.sampleRate, 16_000, accuracy: 0.1)
        XCTAssertEqual(saved.length, 4_000, "0.25s at 16kHz is 4000 frames")
    }

    func testSystemWriteFailureCapKeepsMicRecording() {
        let root = makeRoot(name: "SystemWriteKeepsMic")
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = makeAudio(root: root)
        audio.prepareForNewRecordingStart()
        audio.isRecording = true

        struct WriteFailure: Error {}
        for _ in 1..<audio.maxConsecutiveWriteErrors {
            XCTAssertFalse(audio.recordSystemWriteFailure(WriteFailure()))
        }
        XCTAssertTrue(audio.recordSystemWriteFailure(WriteFailure()))

        let settled = expectation(description: "system write failure settled")
        DispatchQueue.main.async { settled.fulfill() }
        wait(for: [settled], timeout: 1.0)

        XCTAssertTrue(audio.isRecording, "system write failure must keep the mic recording")
        XCTAssertTrue(audio.systemAudioFailed)
        XCTAssertEqual(audio.systemAudioStatus, .failed)
        XCTAssertNotNil(audio.error)
        XCTAssertFalse(
            (audio.error ?? "").localizedCaseInsensitiveContains("recording stopped"),
            "copy must not claim the whole meeting stopped"
        )
    }

    func testStalledSystemAudioSetupDoesNotBlockNextAttempt() {
        let root = makeRoot(name: "ConcurrentSystemAudioSetup")
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = makeAudio(root: root)
        let releaseFirst = DispatchSemaphore(value: 0)
        let firstStarted = expectation(description: "first setup started")
        let secondStarted = expectation(description: "second setup started")

        audio.systemAudioSetupQueue.async {
            firstStarted.fulfill()
            _ = releaseFirst.wait(timeout: .now() + 2)
        }
        wait(for: [firstStarted], timeout: 1)

        audio.systemAudioSetupQueue.async {
            secondStarted.fulfill()
        }
        wait(for: [secondStarted], timeout: 0.5)
        releaseFirst.signal()
    }

    private func makeNonInterleavedBuffer(
        channels: AVAudioChannelCount,
        sampleRate: Double,
        frameCount: AVAudioFrameCount,
        fill: (Int /* channel */, Int /* frame */) -> Float
    ) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        ))
        buffer.frameLength = frameCount
        let channelData = try XCTUnwrap(buffer.floatChannelData)
        for ch in 0..<Int(channels) {
            for frame in 0..<Int(frameCount) {
                channelData[ch][frame] = fill(ch, frame)
            }
        }
        return buffer
    }

    private func makeInterleavedBuffer(
        channels: AVAudioChannelCount,
        sampleRate: Double,
        frameCount: AVAudioFrameCount,
        fill: (Int /* channel */, Int /* frame */) -> Float
    ) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: true
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        ))
        buffer.frameLength = frameCount
        // Interleaved Float32 buffers expose a single contiguous channel-data pointer.
        let interleaved = try XCTUnwrap(buffer.floatChannelData?[0])
        let channelCount = Int(channels)
        for frame in 0..<Int(frameCount) {
            for ch in 0..<channelCount {
                interleaved[frame * channelCount + ch] = fill(ch, frame)
            }
        }
        return buffer
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
            guard let base = pointer.baseAddress else { return }
            channelData.update(from: base, count: samples.count)
        }
        try file.write(from: buffer)
    }

    func testQueuedMicTailKeepsItsCapturedGenerationFormat() throws {
        let root = makeRoot(name: "QueuedMicTailFormat")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let audio = makeAudio(root: root)
        audio.prepareForNewRecordingStart()
        let oldGeneration = audio.recordingSessionGeneration
        let oldMonoFormat = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 1,
                interleaved: false
            )
        )
        let fileURL = root.appendingPathComponent("old-tail.wav")
        let writer = try AVAudioFile(
            forWriting: fileURL,
            settings: oldMonoFormat.settings,
            commonFormat: oldMonoFormat.commonFormat,
            interleaved: oldMonoFormat.isInterleaved
        )
        XCTAssertTrue(
            audio.micAudioFileOwnership.installSessionWriter(
                writer,
                generation: oldGeneration
            ).didInstall
        )

        let queueBlocked = expectation(description: "old mic queue blocked")
        let releaseQueue = DispatchSemaphore(value: 0)
        audio.micAudioFileQueue.async {
            queueBlocked.fulfill()
            _ = releaseQueue.wait(timeout: .now() + 2)
        }
        wait(for: [queueBlocked], timeout: 1)

        let oldStereoBuffer = try makeNonInterleavedBuffer(
            channels: 2,
            sampleRate: 48_000,
            frameCount: 128
        ) { channel, _ in
            channel == 0 ? 0.5 : 0.25
        }
        audio.handleMicBuffer(
            oldStereoBuffer,
            writeContext: MicPCMWriteContext(
                generation: oldGeneration,
                monoFormat: oldMonoFormat,
                inputChannelCount: 2
            )
        )

        // Publish a deliberately incompatible successor format before the old
        // queue gets to run. The admitted old tail must ignore this state.
        audio.prepareForNewRecordingStart()
        audio.monoOutputFormat = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            )
        )
        audio.inputChannelCount = 1

        releaseQueue.signal()
        audio.micAudioFileQueue.sync {}
        XCTAssertTrue(
            audio.micAudioFileOwnership.takeWriterOwned(by: oldGeneration) === writer
        )
        writer.close()

        let saved = try AVAudioFile(forReading: fileURL)
        XCTAssertEqual(saved.length, 128)
        XCTAssertEqual(saved.fileFormat.sampleRate, 48_000)
        XCTAssertEqual(saved.fileFormat.channelCount, 1)
    }

    // MARK: - manualDownmix (AudioFileManager.swift:465)

    func testManualDownmixUsesDominantNonInterleavedChannelWithoutPhaseCancellation() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = makeAudio(root: root)

        // Left = 1.0, Right = -1.0 used to average to silence. For mic capture,
        // choose the dominant channel instead so opposite-polarity inputs do not
        // erase local speech.
        let stereo = try makeNonInterleavedBuffer(
            channels: 2,
            sampleRate: 48_000,
            frameCount: 256
        ) { ch, _ in ch == 0 ? 1.0 : -1.0 }

        let monoFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ))

        let mono = try XCTUnwrap(audio.manualDownmix(buffer: stereo, to: monoFormat))
        XCTAssertEqual(mono.frameLength, 256)
        XCTAssertEqual(mono.format.channelCount, 1)
        let monoData = try XCTUnwrap(mono.floatChannelData?[0])
        for frame in 0..<256 {
            XCTAssertEqual(monoData[frame], 1.0, accuracy: 1e-6)
        }
    }

    func testManualDownmixUsesDominantInterleavedStereoChannel() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = makeAudio(root: root)

        // Interleaved branch in manualDownmix (AudioFileManager.swift:479) reads
        // [L0,R0,L1,R1,...] and must preserve the dominant channel just like
        // the non-interleaved path.
        let stereo = try makeInterleavedBuffer(
            channels: 2,
            sampleRate: 44_100,
            frameCount: 128
        ) { ch, _ in ch == 0 ? 0.4 : 0.8 }

        let monoFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44_100,
            channels: 1,
            interleaved: false
        ))

        let mono = try XCTUnwrap(audio.manualDownmix(buffer: stereo, to: monoFormat))
        XCTAssertEqual(mono.frameLength, 128)
        let monoData = try XCTUnwrap(mono.floatChannelData?[0])
        for frame in 0..<128 {
            XCTAssertEqual(monoData[frame], 0.8, accuracy: 1e-6)
        }
    }

    func testManualDownmixDoesNotHalveSpeechWhenSecondChannelIsSilent() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = makeAudio(root: root)

        let stereo = try makeNonInterleavedBuffer(
            channels: 2,
            sampleRate: 48_000,
            frameCount: 128
        ) { ch, frame in
            ch == 0 ? Float(frame) / 128.0 : 0.0
        }

        let monoFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ))

        let mono = try XCTUnwrap(audio.manualDownmix(buffer: stereo, to: monoFormat))
        let monoData = try XCTUnwrap(mono.floatChannelData?[0])
        for frame in 0..<128 {
            XCTAssertEqual(monoData[frame], Float(frame) / 128.0, accuracy: 1e-6)
        }
    }

    func testManualDownmixReturnsNilForZeroFrameBuffer() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = makeAudio(root: root)

        let empty = try makeNonInterleavedBuffer(
            channels: 2,
            sampleRate: 48_000,
            frameCount: 0
        ) { _, _ in 0 }

        let monoFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ))

        // Guard at AudioFileManager.swift:469 rejects zero-frame buffers.
        XCTAssertNil(audio.manualDownmix(buffer: empty, to: monoFormat))
    }

    func testManualDownmixPreservesMonoFromSingleChannelInput() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = makeAudio(root: root)

        let monoIn = try makeNonInterleavedBuffer(
            channels: 1,
            sampleRate: 16_000,
            frameCount: 64
        ) { _, frame in Float(frame) / 64.0 }

        let monoFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))

        let mono = try XCTUnwrap(audio.manualDownmix(buffer: monoIn, to: monoFormat))
        XCTAssertEqual(mono.frameLength, 64)
        let monoData = try XCTUnwrap(mono.floatChannelData?[0])
        for frame in 0..<64 {
            XCTAssertEqual(monoData[frame], Float(frame) / 64.0, accuracy: 1e-6)
        }
    }

    // MARK: - deepCopyBuffer (AudioFileManager.swift:508)

    func testDeepCopyBufferProducesIndependentNonInterleavedCopy() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = makeAudio(root: root)

        let source = try makeNonInterleavedBuffer(
            channels: 2,
            sampleRate: 48_000,
            frameCount: 32
        ) { ch, frame in Float(ch + 1) * Float(frame) }

        let copy = try XCTUnwrap(audio.deepCopyBuffer(source))
        XCTAssertEqual(copy.frameLength, source.frameLength)
        XCTAssertEqual(copy.format.channelCount, source.format.channelCount)
        XCTAssertEqual(copy.format.sampleRate, source.format.sampleRate, accuracy: 0.1)
        XCTAssertFalse(copy.format.isInterleaved)

        // The copy must own distinct storage — mutating the source after the
        // copy completes must not bleed into the copy (AudioFileManager.swift:507).
        let srcChannels = try XCTUnwrap(source.floatChannelData)
        for ch in 0..<Int(source.format.channelCount) {
            for frame in 0..<Int(source.frameLength) {
                srcChannels[ch][frame] = -999
            }
        }

        let copyChannels = try XCTUnwrap(copy.floatChannelData)
        for ch in 0..<Int(copy.format.channelCount) {
            for frame in 0..<Int(copy.frameLength) {
                XCTAssertEqual(
                    copyChannels[ch][frame],
                    Float(ch + 1) * Float(frame),
                    accuracy: 1e-6
                )
            }
        }
    }

    func testDeepCopyBufferProducesIndependentInterleavedCopy() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = makeAudio(root: root)

        let source = try makeInterleavedBuffer(
            channels: 2,
            sampleRate: 48_000,
            frameCount: 16
        ) { ch, frame in Float(ch) + Float(frame) * 0.01 }

        let copy = try XCTUnwrap(audio.deepCopyBuffer(source))
        XCTAssertEqual(copy.frameLength, source.frameLength)
        XCTAssertTrue(copy.format.isInterleaved)

        // Overwrite source memory; the deep copy must remain intact.
        let srcInterleaved = try XCTUnwrap(source.floatChannelData?[0])
        let channelCount = Int(source.format.channelCount)
        for i in 0..<Int(source.frameLength) * channelCount {
            srcInterleaved[i] = -1
        }

        let copyInterleaved = try XCTUnwrap(copy.floatChannelData?[0])
        for frame in 0..<Int(copy.frameLength) {
            for ch in 0..<channelCount {
                XCTAssertEqual(
                    copyInterleaved[frame * channelCount + ch],
                    Float(ch) + Float(frame) * 0.01,
                    accuracy: 1e-6
                )
            }
        }
    }

    // MARK: - updateSystemAudioStatus (AudioFileManager.swift:539)

    func testUpdateSystemAudioStatusForcesUnknownWhenNotRecording() {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = makeAudio(root: root)

        audio.isRecording = false
        audio.systemAudioStatus = .healthy

        audio.updateSystemAudioStatus(fromError: nil)
        XCTAssertEqual(audio.systemAudioStatus, .unknown)

        audio.systemAudioStatus = .failed
        // Even with an error message, a non-recording session must collapse to unknown.
        audio.updateSystemAudioStatus(fromError: "anything unavailable")
        XCTAssertEqual(audio.systemAudioStatus, .unknown)
    }

    func testUpdateSystemAudioStatusMarksFailedOnUnavailableMessage() {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = makeAudio(root: root)

        audio.isRecording = true
        audio.systemAudioStatus = .healthy

        audio.updateSystemAudioStatus(fromError: "system audio unavailable")
        XCTAssertEqual(audio.systemAudioStatus, .failed)
    }

    func testUpdateSystemAudioStatusMarksFailedOnFailedMessage() {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = makeAudio(root: root)

        audio.isRecording = true
        audio.systemAudioStatus = .healthy

        audio.updateSystemAudioStatus(fromError: "capture failed mid-stream")
        XCTAssertEqual(audio.systemAudioStatus, .failed)
    }

    func testUpdateSystemAudioStatusMarksReconnectingOnSwitchedMessage() {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = makeAudio(root: root)

        audio.isRecording = true
        audio.systemAudioStatus = .healthy

        // The "Switched to" branch (AudioFileManager.swift:546) flips to reconnecting
        // synchronously; the 0.5s recovery back to healthy is async, so we only
        // assert the synchronous transition here.
        audio.updateSystemAudioStatus(fromError: "Switched to Built-in Output")
        XCTAssertEqual(audio.systemAudioStatus, .reconnecting)
    }

    func testUpdateSystemAudioStatusReturnsHealthyOnClearedError() {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = makeAudio(root: root)

        audio.isRecording = true
        audio.systemAudioStatus = .failed

        audio.updateSystemAudioStatus(fromError: nil)
        XCTAssertEqual(audio.systemAudioStatus, .healthy)
    }

    func testUpdateSystemAudioStatusKeepsSilentSticky() {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = makeAudio(root: root)

        audio.isRecording = true
        audio.systemAudioStatus = .silent

        // The else-branch at AudioFileManager.swift:560 explicitly avoids
        // clobbering `.silent` when there is no error.
        audio.updateSystemAudioStatus(fromError: nil)
        XCTAssertEqual(audio.systemAudioStatus, .silent)
    }

    func testUpdateSystemAudioStatusIgnoresUnrecognizedErrorMessages() {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = makeAudio(root: root)

        audio.isRecording = true
        audio.systemAudioStatus = .healthy

        // Neither "Switched to", "unavailable", nor "failed" appear -> no transition.
        audio.updateSystemAudioStatus(fromError: "warning: buffer underrun")
        XCTAssertEqual(audio.systemAudioStatus, .healthy)
    }

    // MARK: - finalizeMicRecording (AudioFileManager.swift:398)

    func testFinalizeMicRecordingReturnsNilWhenPrimaryAndSegmentsAreEmpty() {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = makeAudio(root: root)

        XCTAssertNil(audio.finalizeMicRecording(primaryURL: nil, segments: []))
    }

    func testFinalizeMicRecordingFallsBackToLastSegmentWhenPrimaryIsNil() {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = makeAudio(root: root)

        let a = root.appendingPathComponent("a.wav")
        let b = root.appendingPathComponent("b.wav")
        let result = audio.finalizeMicRecording(
            primaryURL: nil,
            segments: [MicRecordingSegment(url: a), MicRecordingSegment(url: b)]
        )
        XCTAssertEqual(result, b)
    }

    func testFinalizeMicRecordingReturnsPrimaryWhenOnlyOneSegment() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let audio = makeAudio(root: root)

        let primary = root.appendingPathComponent("primary.wav")
        try writeMonoWAV(to: primary, sampleRate: 48_000, samples: Array(repeating: 0.1, count: 4_800))

        // Single-segment branch at AudioFileManager.swift:400 must short-circuit
        // without invoking the merger or touching the file.
        let result = audio.finalizeMicRecording(
            primaryURL: primary,
            segments: [MicRecordingSegment(url: primary)]
        )
        XCTAssertEqual(result, primary)
        XCTAssertTrue(FileManager.default.fileExists(atPath: primary.path))
    }

    func testFinalizeMicRecordingMergesMultipleSegmentsAndRemovesOriginals() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let audio = makeAudio(root: root)

        let primary = root.appendingPathComponent("primary.wav")
        let recovery = root.appendingPathComponent("recovery.wav")
        try writeMonoWAV(to: primary, sampleRate: 48_000, samples: Array(repeating: 0.3, count: 4_800))
        try writeMonoWAV(to: recovery, sampleRate: 48_000, samples: Array(repeating: 0.6, count: 4_800))

        let mergedURL = try XCTUnwrap(audio.finalizeMicRecording(
            primaryURL: primary,
            segments: [
                MicRecordingSegment(url: primary),
                MicRecordingSegment(url: recovery, gapBeforeDuration: 0.0)
            ]
        ))

        // MicRecordingFileMerger writes <primary>_merged.wav next to the input.
        XCTAssertEqual(mergedURL.lastPathComponent, "primary_merged.wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: mergedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: primary.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: recovery.path))
    }

    func testFinalizeMicRecordingSalvagesAroundMissingSegment() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let audio = makeAudio(root: root)

        let primary = root.appendingPathComponent("primary.wav")
        let missing = root.appendingPathComponent("does-not-exist.wav")
        try writeMonoWAV(to: primary, sampleRate: 48_000, samples: Array(repeating: 0.4, count: 4_800))

        // The merger skips the missing segment instead of aborting, so the
        // primary's audio still lands in a merged file. Degraded salvage keeps
        // the source segment on disk for recovery.
        let result = try XCTUnwrap(audio.finalizeMicRecording(
            primaryURL: primary,
            segments: [
                MicRecordingSegment(url: primary),
                MicRecordingSegment(url: missing)
            ]
        ))
        XCTAssertEqual(result.lastPathComponent, "primary_merged.wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: primary.path))
    }

    func testFinalizeMicRecordingFallsBackToPrimaryWhenNothingIsMergeable() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let audio = makeAudio(root: root)

        // Neither segment exists, so the merger throws and finalizeMicRecording
        // swallows the error and returns the primary URL unchanged.
        let primary = root.appendingPathComponent("primary.wav")
        let missing = root.appendingPathComponent("does-not-exist.wav")
        let result = audio.finalizeMicRecording(
            primaryURL: primary,
            segments: [
                MicRecordingSegment(url: primary),
                MicRecordingSegment(url: missing)
            ]
        )
        XCTAssertEqual(result, primary)
    }

    // MARK: - stopTimer (AudioFileManager.swift:456)

    func testStopTimerClearsTimerAndResetsRecordingDuration() {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = makeAudio(root: root)

        audio.recordingDuration = 12.5
        // Install a real timer to be cleared; we don't fire it.
        audio.timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { _ in }

        audio.stopTimer()

        XCTAssertNil(audio.timer)
        XCTAssertEqual(audio.recordingDuration, 0.0)
    }
}
