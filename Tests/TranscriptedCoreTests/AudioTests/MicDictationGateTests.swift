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
            writeContext: MicPCMWriteContext(generation: generation, muteTimeline: audio.meetingMicMuteSessions.timeline(for: generation), monoFormat: Self.format, inputChannelCount: 1)
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

    func testMeetingMutePreservesFramesInFileAndLivePreviewAcrossTapReplacement() async throws {
        let harness = try startRecording(root: try makeRoot())
        let audio = harness.audio
        let host = LockedSamples()
        audio.onMicPCMBuffer = { host.append($0) }
        let preview = LockedSamples()
        audio.onLivePCMBuffer = { buffer, source, _, _ in
            if source == .microphone { preview.append(buffer) }
        }
        audio.setLivePCMDeliveryEnabled(true, previewEpoch: 1)

        let speech = makeSpeech(level: 0.5)
        audio.handleMicBuffer(speech, writeContext: harness.writeContext)
        harness.writeContext.muteTimeline.setMuted(true)
        let generation = harness.writeContext.generation
        let replacementTap = MicPCMWriteContext(
            generation: generation, muteTimeline: audio.meetingMicMuteSessions.timeline(for: generation),
            monoFormat: Self.format, inputChannelCount: 1)
        audio.handleMicBuffer(speech, writeContext: replacementTap)
        audio.handleMicBuffer(speech, writeContext: replacementTap)
        audio.isMicGatedForBorrowedDictation = true
        audio.handleMicBuffer(speech, writeContext: replacementTap)
        audio.isMicGatedForBorrowedDictation = false
        audio.handleMicBuffer(speech, writeContext: replacementTap)
        harness.writeContext.muteTimeline.setMuted(false)
        audio.handleMicBuffer(speech, writeContext: replacementTap)

        await withCheckedContinuation { continuation in
            audio.livePCMDelivery.flush { continuation.resume() }
        }
        await audio.flushMicHostPCMBufferFanout()
        let saved = try savedSamples(harness)
        XCTAssertEqual(host.value.flatMap { $0 }, saved)
        XCTAssertEqual(saved.count, 6 * Int(Self.frames))
        XCTAssertEqual(preview.value.flatMap { $0 }, saved)
        XCTAssertEqual(preview.value.map { $0.map(abs).max() }, [0.5, 0, 0, 0, 0, 0])
    }

    func testPinnedRingDrainedAfterUnmuteProtectsEverySink() async throws {
        let harness = try startRecording(root: try makeRoot())
        let audio = harness.audio
        let hal = PinnedMicrophoneCaptureTests.HAL()
        hal.now = 1
        let capture = hal.makeCapture(deviceID: 41)
        let format = try capture.prepare()
        audio.pinnedMicrophoneCapture = capture
        let prepared = PreparedPinnedMeetingMicrophone(
            capture: capture, deviceID: 41, recordingFormat: format,
            recordingSnapshot: try XCTUnwrap(AudioRecordingFormatPolicy.snapshot(format))
        )
        try audio.startPinnedMeetingMicrophone(prepared, writeContext: harness.writeContext,
                                              sessionGeneration: harness.writeContext.generation)
        defer { capture.stop() }
        let host = LockedSamples(), preview = LockedSamples()
        audio.onMicPCMBuffer = { host.append($0) }
        audio.onLivePCMBuffer = { buffer, _, _, _ in preview.append(buffer) }
        audio.setLivePCMDeliveryEnabled(true, previewEpoch: 1)
        capture.receiveForTesting(hal.buffer(frames: 1, value: 0.125), hostSeconds: 0, received: 8)
        harness.writeContext.muteTimeline.setMuted(true)
        capture.receiveForTesting(hal.buffer(frames: 1, value: 0.5),
                                  hostSeconds: 11, received: 11.01)
        capture.receiveForTesting(hal.buffer(frames: 1, value: 0.75), hostSeconds: 9, received: 11.1)
        capture.receiveForTesting(hal.buffer(frames: 1, value: 0.75), hostSeconds: 0, received: 11.2)
        harness.writeContext.muteTimeline.setMuted(false)
        capture.receiveForTesting(hal.buffer(frames: 1, value: 0.25),
                                  hostSeconds: 13, received: 13.01)
        capture.drainForTesting()
        await audio.flushMicHostPCMBufferFanout()
        await withCheckedContinuation { continuation in
            audio.livePCMDelivery.flush { continuation.resume() }
        }
        XCTAssertEqual(try savedSamples(harness), [0.125, 0, 0, 0, 0])
        XCTAssertEqual(host.value.flatMap { $0 }, [0.125, 0, 0, 0, 0])
        XCTAssertEqual(preview.value.flatMap { $0 }, [0.125, 0, 0, 0, 0])
    }

    func testMisstampedEngineStaleEdgeStamp() async throws {
        try await assertPrivatePacketIsSilent(useConverter: false, delayedPastUnmute: false)
    }

    func testMisstampedEngineSuccessorStamp() async throws {
        try await assertPrivatePacketIsSilent(useConverter: false, delayedPastUnmute: true)
    }

    func testMisstampedConvertedRingStaleEdgeStamp() async throws {
        try await assertPrivatePacketIsSilent(useConverter: true, delayedPastUnmute: false)
    }

    func testMisstampedConvertedRingSuccessorStamp() async throws {
        try await assertPrivatePacketIsSilent(useConverter: true, delayedPastUnmute: true)
    }

    private func assertPrivatePacketIsSilent(useConverter: Bool, delayedPastUnmute: Bool) async throws {
        let reference = try await packetDelivery(useConverter: useConverter, delayedPastUnmute: delayedPastUnmute, mute: false)
        let protected = try await packetDelivery(useConverter: useConverter, delayedPastUnmute: delayedPastUnmute, mute: true)
        for (speech, silence) in zip(reference, protected) {
            XCTAssertGreaterThan(speech.map(abs).max() ?? 0, 0.4)
            XCTAssertEqual(silence.count, speech.count)
            XCTAssertEqual(silence.map(abs).max(), 0)
        }
    }

    private func packetDelivery(useConverter: Bool, delayedPastUnmute: Bool, mute: Bool) async throws -> [[Float]] {
        let harness = try startRecording(root: try makeRoot())
        let audio = harness.audio
        let host = LockedSamples(), preview = LockedSamples()
        audio.onMicPCMBuffer = { host.append($0) }
        audio.onLivePCMBuffer = { buffer, _, _, _ in preview.append(buffer) }
        audio.setLivePCMDeliveryEnabled(true, previewEpoch: 1)
        let hal = PinnedMicrophoneCaptureTests.HAL()
        hal.now = 9.97
        let capture = hal.makeCapture(deviceID: 41)
        if useConverter {
            let format = try capture.prepare()
            audio.pinnedMicrophoneCapture = capture
            try audio.startPinnedMeetingMicrophone(
                PreparedPinnedMeetingMicrophone(capture: capture, deviceID: 41, recordingFormat: format,
                                                recordingSnapshot: try XCTUnwrap(AudioRecordingFormatPolicy.snapshot(format))),
                writeContext: harness.writeContext, sessionGeneration: harness.writeContext.generation)
            hal.format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
            try capture.switchDevice(to: 42)
        }
        defer { capture.stop() }
        func submit(_ stamp: Double, _ receipt: Double, _ level: Float) {
            let packet = hal.buffer(frames: useConverter ? 160 : 480, value: level)
            if useConverter {
                capture.receiveForTesting(packet, hostSeconds: stamp, received: receipt)
            } else {
                audio.handleMicBuffer(packet, writeContext: harness.writeContext)
            }
        }
        submit(9.98, 9.995, 0)
        let timeline = harness.writeContext.muteTimeline
        timeline.setMuted(mute)
        if delayedPastUnmute {
            timeline.setMuted(false)
            submit(10.021, 10.04, 0.5)
        } else {
            submit(9.995, 10.025, 0.5)
        }
        if useConverter { capture.finishAndDrain() }
        await audio.flushMicHostPCMBufferFanout()
        await withCheckedContinuation { c in audio.livePCMDelivery.flush { c.resume() } }
        let saved = try savedSamples(harness)
        let borrowed = host.value.flatMap { $0 }
        let live = preview.value.flatMap { $0 }
        XCTAssertEqual(saved.count, borrowed.count)
        XCTAssertEqual(saved.count, live.count)
        return [saved, borrowed, live]
    }

    @MainActor
    func testPinnedMutedSpeechPublishesRoomActivityForCallEndWarning() async throws {
        let harness = try startRecording(root: try makeRoot())
        let hal = PinnedMicrophoneCaptureTests.HAL()
        hal.now = 1
        let capture = hal.makeCapture(deviceID: 41)
        let format = try capture.prepare()
        harness.audio.pinnedMicrophoneCapture = capture
        try harness.audio.startPinnedMeetingMicrophone(
            PreparedPinnedMeetingMicrophone(capture: capture, deviceID: 41, recordingFormat: format,
                                            recordingSnapshot: try XCTUnwrap(AudioRecordingFormatPolicy.snapshot(format))),
            writeContext: harness.writeContext, sessionGeneration: harness.writeContext.generation
        )
        defer { capture.stop() }
        harness.writeContext.muteTimeline.setMuted(true)
        capture.receiveForTesting(hal.buffer(frames: 128, value: 0.5), hostSeconds: 11)
        capture.drainForTesting()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertGreaterThan(harness.audio.audioLevel, 0.8)
        XCTAssertFalse(harness.audio.isSilent)
        XCTAssertEqual(try savedSamples(harness).map(abs).max(), 0)
    }

    func testMutedRouteChangeWithPacedPadAndConvertedFinishingTail() throws {
        // Identical runs with injected private speech versus silence must
        // match sample for sample, including resampler history after unmute.
        func run(privateLevel: Float) throws -> [Float] {
            let harness = try startRecording(root: try makeRoot())
            let audio = harness.audio
            let hal = PinnedMicrophoneCaptureTests.HAL()
            let capture = hal.makeCapture(deviceID: 41)
            let format = try capture.prepare()
            audio.pinnedMicrophoneCapture = capture
            try audio.startPinnedMeetingMicrophone(
                PreparedPinnedMeetingMicrophone(capture: capture, deviceID: 41, recordingFormat: format,
                                                recordingSnapshot: try XCTUnwrap(AudioRecordingFormatPolicy.snapshot(format))),
                writeContext: harness.writeContext, sessionGeneration: harness.writeContext.generation
            )
            capture.receiveForTesting(hal.buffer(frames: 480, value: 0.25), hostSeconds: 100, received: 100.01)
            capture.drainForTesting()
            hal.format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
            hal.now = 101
            try capture.switchDevice(to: 42)
            let timeline = harness.writeContext.muteTimeline
            timeline.setMuted(true)
            // Monotonic relative to the old route but before the new one began.
            capture.receiveForTesting(hal.buffer(frames: 480, value: privateLevel), hostSeconds: 100.5, received: 101.02)
            capture.receiveForTesting(hal.buffer(frames: 480, value: privateLevel), hostSeconds: 102, received: 102.02)
            timeline.setMuted(false)
            capture.drainForTesting() // One second of the 1.99 s pad is delivered.
            capture.receiveForTesting(hal.buffer(frames: 480, value: privateLevel), hostSeconds: 100.5, received: 102.02)
            capture.receiveForTesting(hal.buffer(frames: 480, value: 0.75), hostSeconds: 102.02, received: 102.04)
            audio.micAudioWriteBackpressure.beginFinishing(generation: harness.writeContext.generation)
            _ = audio.beginRecordingSessionGeneration()
            audio.isMeetingMicMuted = true // The successor must not silence the old tail.
            capture.finishAndDrain()
            return try savedSamples(harness)
        }
        let reference = try run(privateLevel: 0)
        XCTAssertEqual(try run(privateLevel: 0.5), reference)
        XCTAssertEqual(reference.first, 0.25)
        XCTAssertTrue(reference.count > 96_000)
        XCTAssertTrue(reference[480..<96_000].allSatisfy { $0 == 0 })
        XCTAssertEqual(reference.last, 0)
    }

    func testStopTailStaysMutedAndNextRecordingStartsUnmuted() throws {
        let harness = try startRecording(root: try makeRoot())
        let audio = harness.audio
        audio.handleMicBuffer(makeSpeech(level: 0.25), writeContext: harness.writeContext)
        harness.writeContext.muteTimeline.setMuted(true)
        XCTAssertTrue(audio.isMeetingMicMuted)
        audio.micAudioWriteBackpressure.beginFinishing(generation: harness.writeContext.generation)
        _ = audio.beginRecordingSessionGeneration()
        audio.handleMicBuffer(makeSpeech(level: 0.5), writeContext: harness.writeContext)
        let saved = try savedSamples(harness)
        XCTAssertEqual(saved.count, 2 * Int(Self.frames))
        XCTAssertEqual(saved.prefix(Int(Self.frames)).map(abs).max(), 0.25)
        XCTAssertEqual(saved.suffix(Int(Self.frames)).map(abs).max(), 0)
        audio.prepareForNewRecordingStart()
        XCTAssertFalse(audio.isMeetingMicMuted)
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

extension MicPCMWriteContext {
    init(generation: UInt64, monoFormat: AVAudioFormat, inputChannelCount: AVAudioChannelCount) {
        self.init(generation: generation, muteTimeline: MeetingMicMuteTimeline(),
                  monoFormat: monoFormat, inputChannelCount: inputChannelCount)
    }
}
