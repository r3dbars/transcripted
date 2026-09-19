import XCTest
@preconcurrency import AVFoundation
@testable import TranscriptedCore

@available(macOS 26.0, *)
final class LiveCaptureSmokeTests: XCTestCase {
    func testSavedSignalEvidenceDistinguishesToneFromValidSilentWAV() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TranscriptedSignalEvidence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tone = root.appendingPathComponent("tone.wav")
        try SystemToneFixture.writeSineWave(to: tone, duration: 1)
        let toneEvidence = try signalEvidence(at: tone)
        XCTAssertEqual(toneEvidence.duration, 1, accuracy: 0.001)
        XCTAssertGreaterThan(toneEvidence.peak, 0.001)
        XCTAssertTrue(toneEvidence.allSamplesFinite)

        let silence = root.appendingPathComponent("silence.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100))
        buffer.frameLength = 44100
        memset(try XCTUnwrap(buffer.floatChannelData)[0], 0, 44100 * MemoryLayout<Float>.size)
        do {
            let file = try AVAudioFile(forWriting: silence, settings: format.settings)
            try file.write(from: buffer)
        }
        let silentEvidence = try signalEvidence(at: silence)
        XCTAssertGreaterThan(try fileSize(at: silence), 44)
        XCTAssertEqual(silentEvidence.duration, 1, accuracy: 0.001)
        XCTAssertEqual(silentEvidence.peak, 0)
        XCTAssertTrue(silentEvidence.allSamplesFinite)
    }

    func testLiveMeetingAudioCaptureStartsStopsAndWritesScratchFiles() async throws {
        let config = LiveCaptureSmokeConfig.current
        guard config.enabled else {
            throw XCTSkip("Set TRANSCRIPTED_LIVE_CAPTURE_SMOKE=1 to run the local mic + system-audio smoke.")
        }

        let root = config.root
        let paths = CoreStoragePaths.liveSmoke(root: root)
        try FileManager.default.createDirectory(at: paths.transcripts, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.audioCaptures, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.logs, withIntermediateDirectories: true)
        defer {
            if !config.keepArtifacts {
                try? FileManager.default.removeItem(at: root)
            }
        }

        let previousSaveLocation = UserDefaults.standard.object(forKey: "transcriptSaveLocation")
        UserDefaults.standard.removeObject(forKey: "transcriptSaveLocation")
        defer {
            if let previousSaveLocation {
                UserDefaults.standard.set(previousSaveLocation, forKey: "transcriptSaveLocation")
            } else {
                UserDefaults.standard.removeObject(forKey: "transcriptSaveLocation")
            }
        }

        try assertMicrophoneIsReadyForNonInteractiveSmoke()
        try assertRecordingValidatorAcceptsLiveSmokePaths(paths)

        let audio = Audio(paths: paths)
        var stopped = false
        defer {
            if !stopped {
                audio.stop()
            }
        }

        // Keep the output device active before waiting for the tap's first
        // frame. Starting playback only after readiness can circularly wait
        // on an otherwise idle system-output device.
        let toneURL = root.appendingPathComponent("system-tone.wav", isDirectory: false)
        try SystemToneFixture.writeSineWave(to: toneURL, duration: config.startTimeout + config.recordingDuration + 0.5)
        let tonePlayer = SystemTonePlayer(url: toneURL)
        try tonePlayer.start()
        defer { tonePlayer.stop() }
        audio.start()

        let startOutcome = await waitForMeetingCaptureReadiness(audio: audio, timeout: config.startTimeout)
        switch startOutcome {
        case .ready:
            break
        case .waiting:
            XCTFail("Live capture did not become ready within \(config.startTimeout)s; recording=\(audio.isRecording), micFile=\(audio.micAudioFileURL != nil), micStreaming=\(audio.micAudioStreaming), systemFile=\(audio.systemAudioFileURL != nil), systemStreaming=\(audio.systemAudioStreaming), error=\(audio.error ?? "nil")")
            return
        case .failed(let message):
            XCTFail("Live capture failed before readiness: \(message)")
            return
        }

        let startedMicURL = try XCTUnwrap(audio.micAudioFileURL, "Live smoke should create a mic scratch file at start.")
        let startedSystemURL = try XCTUnwrap(audio.systemAudioFileURL, "Live smoke should create a system-audio scratch file at start.")

        try await Task.sleep(nanoseconds: UInt64(config.recordingDuration * 1_000_000_000))
        tonePlayer.stop()

        let stopRecorder = CaptureStopRecorder()
        audio.onRecordingComplete = { micURL, systemURL in
            stopRecorder.complete(micURL: micURL, systemURL: systemURL)
        }
        audio.stop()
        stopped = true

        let stopResult = await stopRecorder.wait(timeout: config.stopTimeout)
        guard stopResult.didComplete else {
            XCTFail("Live capture stop did not complete within \(config.stopTimeout)s.")
            return
        }

        let finalMicURL = stopResult.micURL ?? startedMicURL
        let finalSystemURL = stopResult.systemURL ?? startedSystemURL
        let micSize = try fileSize(at: finalMicURL)
        let systemSize = try fileSize(at: finalSystemURL)

        XCTAssertGreaterThan(micSize, 44, "Live mic WAV should contain more than an empty WAV header.")
        XCTAssertGreaterThan(systemSize, 44, "Live system-audio WAV should contain more than an empty WAV header.")

        // Permission-denied process taps can write a perfectly valid, entirely
        // silent WAV. File existence/size alone must never pass this live gate.
        let micEvidence = try signalEvidence(at: finalMicURL)
        let systemEvidence = try signalEvidence(at: finalSystemURL)
        let minimumDuration = max(0.1, config.recordingDuration * 0.9)
        XCTAssertGreaterThanOrEqual(micEvidence.duration, minimumDuration, "Mic capture should retain the recording interval.")
        XCTAssertGreaterThanOrEqual(systemEvidence.duration, minimumDuration, "System capture should retain the recording interval.")
        XCTAssertGreaterThan(systemEvidence.peak, 0.001, "The external test tone must reach the saved system-audio file; silent PCM is not permission proof.")
        XCTAssertTrue(systemEvidence.allSamplesFinite, "Saved system audio must contain finite PCM samples.")
        print("LIVE_CAPTURE_EVIDENCE mic_duration=\(micEvidence.duration) system_duration=\(systemEvidence.duration) system_peak=\(systemEvidence.peak)")

        let snapshot = audio.createPipelineDiagnosticsSnapshot()
        XCTAssertEqual(snapshot.systemBackend, "core_audio_tap", "Live smoke should exercise the shipping audio-only backend.")
    }

    private func signalEvidence(at url: URL) throws -> (duration: Double, peak: Float, allSamplesFinite: Bool) {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
        var peak: Float = 0
        var allSamplesFinite = true
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            let channels = try XCTUnwrap(buffer.floatChannelData)
            for channel in 0..<Int(buffer.format.channelCount) {
                for frame in 0..<Int(buffer.frameLength) {
                    let sample = channels[channel][frame]
                    if sample.isFinite { peak = max(peak, abs(sample)) }
                    else { allSamplesFinite = false }
                }
            }
        }
        return (Double(file.length) / file.processingFormat.sampleRate, peak, allSamplesFinite)
    }

    private func assertMicrophoneIsReadyForNonInteractiveSmoke() throws {
        guard AVCaptureDevice.default(for: .audio) != nil else {
            throw LiveCaptureSmokePreflightError("No default microphone is available for the live capture smoke.")
        }

        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return
        case .notDetermined:
            throw LiveCaptureSmokePreflightError(
                "Microphone permission is not determined for this test runner. Open Transcripted/Terminal once and grant microphone access before running the live smoke."
            )
        case .denied, .restricted:
            throw LiveCaptureSmokePreflightError("Microphone permission is \(status). Enable microphone access before running the live smoke.")
        @unknown default:
            throw LiveCaptureSmokePreflightError("Unknown microphone permission status: \(status.rawValue).")
        }
    }

    private func assertRecordingValidatorAcceptsLiveSmokePaths(_ paths: CoreStoragePaths) throws {
        let validation = RecordingValidator.validateRecordingConditions(paths: paths)
        if case .failure(let message) = validation {
            throw LiveCaptureSmokePreflightError("RecordingValidator rejected live smoke preflight: \(message)")
        }
    }

    private func waitForMeetingCaptureReadiness(
        audio: Audio,
        timeout: TimeInterval
    ) async -> AudioCaptureStartState.Outcome {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            let outcome = AudioCaptureStartState.meetingCaptureOutcome(
                isRecording: audio.isRecording,
                micAudioFileURL: audio.micAudioFileURL,
                micAudioStreaming: audio.micAudioStreaming,
                systemAudioFileURL: audio.systemAudioFileURL,
                systemAudioStreaming: audio.systemAudioStreaming,
                errorMessage: audio.error
            )

            if outcome != .waiting {
                return outcome
            }

            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        return .waiting
    }

    private func fileSize(at url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attributes[.size] as? UInt64 {
            return size
        }
        if let size = attributes[.size] as? NSNumber {
            return size.uint64Value
        }
        throw XCTSkip("Could not read file size for \(url.path)")
    }
}

private struct LiveCaptureSmokePreflightError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}

private struct LiveCaptureSmokeConfig {
    let enabled: Bool
    let keepArtifacts: Bool
    let root: URL
    let recordingDuration: TimeInterval
    let startTimeout: TimeInterval
    let stopTimeout: TimeInterval

    static var current: LiveCaptureSmokeConfig {
        let environment = ProcessInfo.processInfo.environment
        let configuredRoot = environment["TRANSCRIPTED_LIVE_CAPTURE_ROOT"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        let rootParent = configuredRoot ?? FileManager.default.temporaryDirectory
        let root = rootParent.appendingPathComponent("TranscriptedLiveCaptureSmoke-\(UUID().uuidString)", isDirectory: true)

        return LiveCaptureSmokeConfig(
            enabled: environment["TRANSCRIPTED_LIVE_CAPTURE_SMOKE"] == "1",
            keepArtifacts: environment["TRANSCRIPTED_LIVE_CAPTURE_KEEP"] == "1",
            root: root,
            recordingDuration: environment.timeInterval("TRANSCRIPTED_LIVE_CAPTURE_DURATION", default: 2.0),
            startTimeout: environment.timeInterval("TRANSCRIPTED_LIVE_CAPTURE_START_TIMEOUT", default: 12.0),
            stopTimeout: environment.timeInterval("TRANSCRIPTED_LIVE_CAPTURE_STOP_TIMEOUT", default: 8.0)
        )
    }
}

private extension Dictionary where Key == String, Value == String {
    func timeInterval(_ key: String, default fallback: TimeInterval) -> TimeInterval {
        guard let rawValue = self[key],
              let value = TimeInterval(rawValue),
              value > 0 else {
            return fallback
        }
        return value
    }
}

private extension CoreStoragePaths {
    static func liveSmoke(root: URL) -> CoreStoragePaths {
        CoreStoragePaths(
            transcripts: root.appendingPathComponent("captures/meetings", isDirectory: true),
            speakerDB: root.appendingPathComponent("state/speakers.sqlite"),
            statsDB: root.appendingPathComponent("state/stats.sqlite"),
            failedQueue: root.appendingPathComponent("state/failed_transcriptions.json"),
            speakerClips: root.appendingPathComponent("tmp/recordings/speaker_clips", isDirectory: true),
            audioCaptures: root.appendingPathComponent("tmp/recordings", isDirectory: true),
            logs: root.appendingPathComponent("logs", isDirectory: true)
        )
    }
}

private struct CaptureStopResult {
    let micURL: URL?
    let systemURL: URL?
    let didComplete: Bool
}

private final class CaptureStopRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CaptureStopResult, Never>?
    private var completedResult: CaptureStopResult?

    func complete(micURL: URL?, systemURL: URL?) {
        resumeIfNeeded(CaptureStopResult(
            micURL: micURL,
            systemURL: systemURL,
            didComplete: true
        ))
    }

    func wait(timeout: TimeInterval) async -> CaptureStopResult {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let completedResult {
                lock.unlock()
                continuation.resume(returning: completedResult)
                return
            }
            self.continuation = continuation
            lock.unlock()

            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.resumeIfNeeded(CaptureStopResult(micURL: nil, systemURL: nil, didComplete: false))
            }
        }
    }

    private func resumeIfNeeded(_ result: CaptureStopResult) {
        lock.lock()
        guard completedResult == nil else {
            lock.unlock()
            return
        }
        completedResult = result
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        continuation?.resume(returning: result)
    }
}

private enum SystemToneFixture {
    static func writeSineWave(to url: URL, duration: TimeInterval) throws {
        let sampleRate = 44_100
        let frames = max(Int(Double(sampleRate) * duration), sampleRate)
        var pcm = Data()
        pcm.reserveCapacity(frames * 2)

        for frame in 0..<frames {
            let phase = (Double(frame) / Double(sampleRate)) * 440.0 * 2.0 * Double.pi
            var sample = Int16(Double(Int16.max) * 0.35 * sin(phase)).littleEndian
            withUnsafeBytes(of: &sample) { bytes in
                pcm.append(contentsOf: bytes)
            }
        }

        var data = Data()
        data.appendASCII("RIFF")
        data.appendLittleEndianUInt32(UInt32(36 + pcm.count))
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendLittleEndianUInt32(16)
        data.appendLittleEndianUInt16(1)
        data.appendLittleEndianUInt16(1)
        data.appendLittleEndianUInt32(UInt32(sampleRate))
        data.appendLittleEndianUInt32(UInt32(sampleRate * 2))
        data.appendLittleEndianUInt16(2)
        data.appendLittleEndianUInt16(16)
        data.appendASCII("data")
        data.appendLittleEndianUInt32(UInt32(pcm.count))
        data.append(pcm)

        try data.write(to: url, options: .atomic)
    }
}

private final class SystemTonePlayer {
    private let process = Process()

    init(url: URL) {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        process.arguments = [url.path]
    }

    func start() throws {
        try process.run()
    }

    func stop() {
        guard process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
    }
}

private extension Data {
    mutating func appendASCII(_ value: String) {
        append(contentsOf: value.utf8)
    }

    mutating func appendLittleEndianUInt16(_ value: UInt16) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            append(contentsOf: bytes)
        }
    }

    mutating func appendLittleEndianUInt32(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            append(contentsOf: bytes)
        }
    }
}
