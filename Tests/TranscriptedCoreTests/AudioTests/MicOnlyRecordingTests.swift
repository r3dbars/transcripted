import XCTest
@preconcurrency import AVFoundation
import Combine
@testable import TranscriptedCore

/// "Record Just My Mic" must record the mic alone. Building the system-audio
/// tap anyway raised the macOS System Audio Recording box right after the user
/// declined it, and held a silent tap open for the whole meeting.
@available(macOS 14.0, *)
final class MicOnlyRecordingTests: XCTestCase {

    // MARK: - Start readiness

    private let micURL = URL(fileURLWithPath: "/tmp/mic.wav")

    func testMicOnlyStartIsReadyOnceTheMicStreams() {
        XCTAssertEqual(
            AudioCaptureStartState.meetingCaptureOutcome(
                isRecording: true,
                micAudioFileURL: micURL,
                micAudioStreaming: true,
                systemAudioFileURL: nil,
                systemAudioStreaming: false,
                errorMessage: nil,
                requiresSystemAudio: false
            ),
            .ready,
            "a mic-only start has no tap to wait for"
        )
    }

    func testMicOnlyStartStillWaitsForTheMic() {
        XCTAssertEqual(
            AudioCaptureStartState.meetingCaptureOutcome(
                isRecording: true,
                micAudioFileURL: micURL,
                micAudioStreaming: false,
                systemAudioFileURL: nil,
                systemAudioStreaming: false,
                errorMessage: nil,
                requiresSystemAudio: false
            ),
            .waiting,
            "a header-only mic file is still not a recording"
        )
        XCTAssertEqual(
            AudioCaptureStartState.meetingCaptureOutcome(
                isRecording: true,
                micAudioFileURL: nil,
                micAudioStreaming: true,
                systemAudioFileURL: nil,
                systemAudioStreaming: false,
                errorMessage: nil,
                requiresSystemAudio: false
            ),
            .waiting
        )
    }

    func testMicOnlyStartStillFailsOnAnError() {
        XCTAssertEqual(
            AudioCaptureStartState.meetingCaptureOutcome(
                isRecording: true,
                micAudioFileURL: micURL,
                micAudioStreaming: true,
                systemAudioFileURL: nil,
                systemAudioStreaming: false,
                errorMessage: "Microphone access denied.",
                requiresSystemAudio: false
            ),
            .failed("Microphone access denied.")
        )
    }

    func testBothSidesStartStillNeedsTheSystemTap() {
        XCTAssertEqual(
            AudioCaptureStartState.meetingCaptureOutcome(
                isRecording: true,
                micAudioFileURL: micURL,
                micAudioStreaming: true,
                systemAudioFileURL: nil,
                systemAudioStreaming: false,
                errorMessage: nil
            ),
            .waiting,
            "the default still requires both sides"
        )
    }

    func testMicOnlyTimeoutNeverBlamesSystemAudio() {
        let micMessage = "Microphone capture did not become ready in time. Check your input device, then try again."
        XCTAssertEqual(
            AudioCaptureStartState.timeoutFailureMessage(
                existingErrorMessage: nil,
                micAudioStreaming: false,
                systemAudioStreaming: false,
                requiresSystemAudio: false
            ),
            micMessage
        )
        XCTAssertEqual(
            AudioCaptureStartState.timeoutFailureMessage(
                existingErrorMessage: "Recording failed to start.",
                micAudioStreaming: false,
                systemAudioStreaming: false,
                requiresSystemAudio: false
            ),
            "Recording failed to start.",
            "an error that already landed wins"
        )
        XCTAssertEqual(
            AudioCaptureStartState.timeoutFailureStage(
                micAudioStreaming: false,
                systemAudioStreaming: false,
                requiresSystemAudio: false
            ),
            .microphoneGraph
        )
        XCTAssertEqual(
            AudioCaptureStartState.timeoutFailureStage(
                micAudioStreaming: true,
                systemAudioStreaming: false,
                requiresSystemAudio: false
            ),
            .unknown,
            "a streaming mic with no tap is not a system-audio failure"
        )
    }

    // MARK: - Audio

    func testMicOnlyChoiceIsFixedAtStartAndAppliesToTheNextRecording() {
        let audio = Audio(paths: makePaths())
        XCTAssertTrue(audio.capturesSystemAudio, "meetings record both sides by default")
        XCTAssertTrue(audio.currentRecordingCapturesSystemAudio)

        audio.capturesSystemAudio = false
        XCTAssertTrue(audio.currentRecordingCapturesSystemAudio, "nothing changes until the next start")

        audio.prepareForNewRecordingStart()
        XCTAssertFalse(audio.currentRecordingCapturesSystemAudio)

        audio.capturesSystemAudio = true
        XCTAssertFalse(
            audio.currentRecordingCapturesSystemAudio,
            "changing the request mid-recording must not strand the active one"
        )

        audio.prepareForNewRecordingStart()
        XCTAssertTrue(audio.currentRecordingCapturesSystemAudio)
    }

    func testMicOnlyRecordingDoesNotCallTheMissingSystemTrackHealthy() {
        let audio = Audio(paths: makePaths())
        audio.capturesSystemAudio = false
        audio.prepareForNewRecordingStart()
        XCTAssertEqual(audio.systemAudioStatus, .unknown)

        audio.isRecording = true
        audio.restoreSystemAudioHealthyStatusAfterSuccessfulStart()
        XCTAssertEqual(audio.systemAudioStatus, .unknown)
    }

    func testMicOnlyRecordingIgnoresTheLastMeetingsTap() {
        // `systemAudioCapture` keeps the previous meeting's tap. A mic-only
        // recording must not grade, report, or reconnect it as its own.
        let previousTap = MicOnlyStubSystemAudioCapture(successRate: 0)
        let audio = Audio(paths: makePaths(), systemAudioCaptureForTesting: previousTap)

        audio.capturesSystemAudio = false
        audio.prepareForNewRecordingStart()

        XCTAssertNil(audio.recordingSystemAudioCapture)
        XCTAssertEqual(
            audio.createHealthInfo().captureQuality,
            .excellent,
            "the previous meeting's dropped buffers must not degrade a mic-only meeting"
        )
        let snapshot = audio.createPipelineDiagnosticsSnapshot()
        XCTAssertEqual(snapshot.systemBackend, "none")

        audio.capturesSystemAudio = true
        audio.prepareForNewRecordingStart()
        XCTAssertTrue((audio.recordingSystemAudioCapture as AnyObject?) === previousTap)
    }

    func testMicOnlyRecordingIgnoresALateErrorFromTheLastMeetingsTap() {
        let audio = Audio(paths: makePaths())
        audio.capturesSystemAudio = false
        audio.prepareForNewRecordingStart()
        audio.isRecording = true

        audio.updateSystemAudioStatus(fromError: "System audio failed - capture could not finalize safely; earlier audio was retained.")
        XCTAssertEqual(audio.systemAudioStatus, .unknown)
        XCTAssertFalse(audio.systemAudioFailed, "a mic-only meeting has no system track to fail")

        audio.updateSystemAudioStatus(fromError: "System audio reconnecting after capture interruption.")
        XCTAssertEqual(audio.systemAudioStatus, .unknown)
    }

    func testMicOnlyRecordingLeavesTheTapAloneAcrossSleep() {
        let tap = MicOnlyStubSystemAudioCapture(successRate: 1)
        let center = NotificationCenter()
        let notifications = AudioSleepWakeNotifications(
            center: center,
            willSleepName: Notification.Name("MicOnlyRecordingTests.WillSleep"),
            didWakeName: Notification.Name("MicOnlyRecordingTests.DidWake")
        )
        let audio = Audio(
            paths: makePaths(),
            systemAudioCaptureForTesting: tap,
            sleepWakeNotifications: notifications
        )
        audio.installWorkspaceSleepWakeObservers()
        audio.capturesSystemAudio = false
        audio.prepareForNewRecordingStart()
        audio.isRecording = true

        center.post(name: notifications.willSleepName, object: nil)
        let delivered = expectation(description: "will-sleep observer ran on main")
        DispatchQueue.main.async { delivered.fulfill() }
        wait(for: [delivered], timeout: 1.0)

        XCTAssertEqual(tap.prepareForSystemSleepCallCount, 0, "a mic-only recording has no tap to release")
        XCTAssertTrue(
            audio.isSystemSleepPending(for: audio.recordingSessionGeneration),
            "the mic still holds its recovery for the wake"
        )
    }

    // MARK: - Saved meeting health

    func testMicOnlyChoiceIsNotSavedAsADegradedCapture() {
        let chosen = RecordingHealthInfo.perfect
            .markingSystemAudioSkippedByChoice()
            .markingSystemAudioMissing()
        XCTAssertEqual(chosen.captureQuality, .excellent, "the user asked for just the mic")
        XCTAssertEqual(chosen.qualityReason, .none)
        XCTAssertNil(chosen.systemAudioMissing)
        XCTAssertEqual(chosen.systemAudioSkippedByChoice, true)

        let lost = RecordingHealthInfo.perfect.markingSystemAudioMissing()
        XCTAssertEqual(lost.captureQuality, .degraded, "a system track lost by accident still degrades")
        XCTAssertEqual(lost.qualityReason, .systemAudioMissing)
        XCTAssertEqual(lost.systemAudioMissing, true)
    }

    func testMicOnlyChoiceKeepsOtherHealthMarks() {
        let chosen = RecordingHealthInfo.perfect
            .markingSystemAudioSkippedByChoice()
            .markingMicrophoneAudioUnusable()
        XCTAssertEqual(chosen.captureQuality, .degraded, "a bad mic is still a bad capture")
        XCTAssertEqual(chosen.qualityReason, .microphoneUnusable)
        XCTAssertEqual(chosen.systemAudioSkippedByChoice, true, "marks carry the choice forward")
    }

    func testSavedTranscriptResolutionKeepsAMicOnlyChoiceClean() {
        let resolution = TranscriptionTaskManager.savedTranscriptAudioResolution(
            microphoneURLWasProvided: true,
            microphoneOutcome: .usable,
            systemOutcome: .unusable,
            healthInfo: RecordingHealthInfo.perfect.markingSystemAudioSkippedByChoice()
        )
        XCTAssertTrue(resolution.includesMicrophone)
        XCTAssertFalse(resolution.includesSystemAudio)
        XCTAssertEqual(resolution.healthInfo?.captureQuality, .excellent)
    }

    // MARK: - Silent system track

    func testSilentSystemTrackMatchesTheMicLengthAndIsSilent() throws {
        let directory = try makeDirectory()
        let micURL = directory.appendingPathComponent("meeting_2026-09-23_21-00-00-000_mic.wav")
        try writeMicFile(at: micURL, seconds: 3, sampleRate: 48_000)

        let systemURL = try MicOnlySilentSystemTrack.write(matching: micURL)

        XCTAssertEqual(systemURL.lastPathComponent, "meeting_2026-09-23_21-00-00-000_system.wav",
                       "named like a live tap's file so scratch cleanup treats both tracks alike")
        XCTAssertEqual(systemURL.deletingLastPathComponent().standardizedFileURL, directory.standardizedFileURL)
        let file = try AVAudioFile(forReading: systemURL)
        XCTAssertEqual(file.fileFormat.sampleRate, 48_000, accuracy: 0.1,
                       "Home's playback mix takes its rate from the system track, so it must match the mic")
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(file.length, 144_000, "3 s at 48 kHz, as long as the mic")

        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        let peak = (0..<Int(buffer.frameLength)).reduce(Float(0)) { max($0, abs(samples[$1])) }
        XCTAssertEqual(peak, 0, "the stand-in track is pure silence")
    }

    func testSilentSystemTrackNeverOverwritesAFile() throws {
        let directory = try makeDirectory()
        let micURL = directory.appendingPathComponent("meeting_x_mic.wav")
        try writeMicFile(at: micURL, seconds: 1, sampleRate: 16_000)
        let existing = MicOnlySilentSystemTrack.destinationURL(forMicrophone: micURL)
        try Data("keep".utf8).write(to: existing)

        XCTAssertThrowsError(try MicOnlySilentSystemTrack.write(matching: micURL)) { error in
            XCTAssertEqual(error as? MicOnlySilentSystemTrack.WriteError, .destinationExists)
        }
        XCTAssertEqual(try Data(contentsOf: existing), Data("keep".utf8))
    }

    func testSilentSystemTrackNeedsAReadableMic() throws {
        let directory = try makeDirectory()
        let micURL = directory.appendingPathComponent("meeting_y_mic.wav")
        try Data("not audio".utf8).write(to: micURL)

        XCTAssertThrowsError(try MicOnlySilentSystemTrack.write(matching: micURL)) { error in
            XCTAssertEqual(error as? MicOnlySilentSystemTrack.WriteError, .unreadableMicrophoneAudio)
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: MicOnlySilentSystemTrack.destinationURL(forMicrophone: micURL).path
        ))
    }

    func testSilentSystemTrackFollowsALowerMicRate() throws {
        let directory = try makeDirectory()
        let micURL = directory.appendingPathComponent("meeting_z_mic.wav")
        try writeMicFile(at: micURL, seconds: 2, sampleRate: 16_000)

        let file = try AVAudioFile(forReading: MicOnlySilentSystemTrack.write(matching: micURL))

        XCTAssertEqual(file.fileFormat.sampleRate, 16_000, accuracy: 0.1)
        XCTAssertEqual(file.length, 32_000)
    }

    func testSilentSystemTrackRateFallsBackForAnUnusableMicRate() {
        XCTAssertEqual(MicOnlySilentSystemTrack.sampleRate(matching: 44_100), 44_100)
        XCTAssertEqual(MicOnlySilentSystemTrack.sampleRate(matching: 0), MicOnlySilentSystemTrack.fallbackSampleRate)
        XCTAssertEqual(MicOnlySilentSystemTrack.sampleRate(matching: .nan), MicOnlySilentSystemTrack.fallbackSampleRate)
    }

    func testSilentSystemTrackHeaderStaysInside32Bits() {
        let dataBytes = MicOnlySilentSystemTrack.maxFrames * MicOnlySilentSystemTrack.bytesPerSample
        XCTAssertLessThanOrEqual(36 + dataBytes, Int(UInt32.max))
        XCTAssertEqual(dataBytes % 2, 0)
        XCTAssertEqual(MicOnlySilentSystemTrack.header(dataByteCount: dataBytes, sampleRate: 48_000).count, 44)
    }

    func testSilentSystemTrackNameForAMergedMic() {
        let url = MicOnlySilentSystemTrack.destinationURL(
            forMicrophone: URL(fileURLWithPath: "/tmp/captures/meeting_a_mic_merged.wav")
        )
        XCTAssertEqual(url.path, "/tmp/captures/meeting_a_system.wav")
    }

    func testSilentSystemTrackNameForAnUnusualMicName() {
        let url = MicOnlySilentSystemTrack.destinationURL(
            forMicrophone: URL(fileURLWithPath: "/tmp/captures/merged.caf")
        )
        XCTAssertEqual(url.path, "/tmp/captures/merged_system.wav")
    }

    // MARK: - Start path shape

    /// The tap is built in exactly one place. The mic-only check must sit in
    /// front of it, or a mic-only meeting still asks macOS for system audio.
    func testStartAudioCaptureChecksMicOnlyBeforeBuildingTheTap() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // AudioTests
            .deletingLastPathComponent() // TranscriptedCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repository root
            .appendingPathComponent("Sources/TranscriptedCore/Audio/AudioFileManager.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "func startAudioCapture(sessionGeneration: UInt64)"))
        let body = source[start.upperBound...]

        let micOnlyCheck = try XCTUnwrap(body.range(of: "if !currentRecordingCapturesSystemAudio {"))
        let buildTap = try XCTUnwrap(body.range(of: "} else if let capture = makeSystemAudioCaptureForRecordingAttempt() {"))
        XCTAssertLessThan(micOnlyCheck.lowerBound, buildTap.lowerBound)
        XCTAssertEqual(
            source.components(separatedBy: "makeSystemAudioCaptureForRecordingAttempt()").count - 1,
            1,
            "one call: the mic-only check covers every tap build"
        )
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MicOnlySilentTrack-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func writeMicFile(at url: URL, seconds: Double, sampleRate: Double) throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ))
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)
    }

    private func makePaths() -> CoreStoragePaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MicOnlyRecordingTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return CoreStoragePaths(
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

@available(macOS 14.0, *)
private final class MicOnlyStubSystemAudioCapture: SystemAudioCaptureEngine, @unchecked Sendable {
    private let errorSubject = PassthroughSubject<String?, Never>()
    private let lock = NSLock()
    private var _prepareForSystemSleepCallCount = 0

    let bufferSuccessRate: Double
    var diagnosticBackendName: String { "mic_only_stub" }
    var audioFormat: AVAudioFormat?
    var deliversOwnedAudioBuffers: Bool { true }
    var errorMessagePublisher: AnyPublisher<String?, Never> { errorSubject.eraseToAnyPublisher() }

    init(successRate: Double) {
        bufferSuccessRate = successRate
    }

    var prepareForSystemSleepCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _prepareForSystemSleepCallCount
    }

    func prepare() throws {}
    func start(bufferCallback: @escaping (AVAudioPCMBuffer) -> Void) throws {}
    func stop() {}
    func stopSync() {}

    func prepareForSystemSleep() {
        lock.lock()
        _prepareForSystemSleepCallCount += 1
        lock.unlock()
    }
}
