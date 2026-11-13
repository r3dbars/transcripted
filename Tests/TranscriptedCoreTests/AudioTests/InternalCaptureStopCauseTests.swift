import AVFoundation
import CoreAudio
import QuartzCore
import XCTest
@testable import TranscriptedCore

/// `stop_cause` reaches PostHog and Sentry only if every value is a short
/// category the sanitizers keep (see Sources/Observability/AGENTS.md).
final class InternalCaptureStopCauseTests: XCTestCase {

    func testEveryStopCauseIsATelemetrySafeCategory() throws {
        let category = try NSRegularExpression(pattern: "^[a-z0-9][a-z0-9_]*$")
        let dropped = ["audio", "error", "file", "name", "path", "text", "title", "token", "url", "speaker"]
        for cause in InternalCaptureStopCause.allCases {
            let value = cause.rawValue
            XCTAssertLessThanOrEqual(value.count, 80, value)
            XCTAssertNotNil(
                category.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
                "\(value) must be a lowercase category"
            )
            for fragment in dropped {
                XCTAssertFalse(value.contains(fragment), "\(value) contains \(fragment)")
            }
        }
    }

    func testNoCauseUsesTheValueReservedForStopsWithNoCoreCause() {
        let values = InternalCaptureStopCause.allCases.map(\.rawValue)
        XCTAssertFalse(values.contains("unrecorded"), "reserved for stops with no Core cause")
    }
}

/// Every way Core ends a recording on its own has to leave its own
/// `stop_cause` behind, because Sentry and PostHog split APPLE-MACOS-2D by it.
/// Each test makes a real `Audio` that is recording, drives one stop path with
/// plain inputs (failed writes, a flooded buffer, a number of free bytes, a mic
/// that stalls), waits for the stop to finish, and reads the cause back.
///
/// `trigger` switches over every case with no `default`, so adding a cause
/// without a stop path to drive it here does not compile.
///
/// Synthetic only: no engine or input node is built, so none of this says
/// anything about a Bluetooth headset as the default input. The pinned-mic
/// test goes through the capture's fake HAL hooks, never a real device.
final class InternalCaptureStopPathTests: XCTestCase {
    private struct WriteFailure: Error {}

    private final class FakeClock: @unchecked Sendable {
        var now: TimeInterval = 100
    }

    private func makeRecordingAudio() throws -> Audio {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("InternalCaptureStopPathTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let audio = Audio(paths: CoreStoragePaths(
            transcripts: root.appendingPathComponent("captures/meetings", isDirectory: true),
            speakerDB: root.appendingPathComponent("state/speakers.sqlite"),
            statsDB: root.appendingPathComponent("state/stats.sqlite"),
            failedQueue: root.appendingPathComponent("state/failed_transcriptions.json"),
            speakerClips: root.appendingPathComponent("tmp/recordings/speaker_clips", isDirectory: true),
            audioCaptures: root.appendingPathComponent("tmp/recordings", isDirectory: true),
            logs: root.appendingPathComponent("logs", isDirectory: true)
        ))
        audio.prepareForNewRecordingStart()
        audio.isRecording = true
        return audio
    }

    /// Drives the stop path that records `cause`, using only what that path
    /// reads from outside. The switch is exhaustive on purpose.
    private func trigger(_ cause: InternalCaptureStopCause, on audio: Audio) throws {
        let generation = audio.recordingSessionGeneration
        switch cause {
        case .micRecoveryGaveUp:
            // A mic-only recording whose mic has gone quiet and whose recovery
            // attempts are spent: the next watchdog tick gives up and stops.
            audio.systemAudioFailed = true
            audio.recoveryAttemptCount = audio.maxRecoveryAttempts
            audio.startWatchdog()
            audio.lastBufferTime = CACurrentMediaTime() - 60
        case .pinnedMicFailed:
            try triggerPinnedMicrophoneFailure(on: audio, generation: generation)
        case .diskLow:
            audio.reactToFreeDiskSpace(10_000_000)
        case .micWriteFailed:
            for _ in 1..<audio.maxConsecutiveWriteErrors {
                XCTAssertFalse(audio.recordMicWriteFailure(WriteFailure()))
            }
            XCTAssertTrue(audio.recordMicWriteFailure(WriteFailure()))
        case .micWriteBackpressure:
            audio.handleMicBuffer(
                Self.monoBuffer(frames: audio.micAudioWriteBackpressure.byteLimit / 4 + 1024),
                writeContext: MicPCMWriteContext(
                    generation: generation,
                    monoFormat: Self.monoFormat,
                    inputChannelCount: 1
                )
            )
        case .systemWriteBackpressure:
            audio.surfaceSystemWriteBackpressureAndStop(generation: generation)
        }
    }

    /// A pinned mic that stalls past its restart budget reports `.failed`
    /// through the same event handler a real meeting installs.
    private func triggerPinnedMicrophoneFailure(on audio: Audio, generation: UInt64) throws {
        let format = Self.monoFormat
        let clock = FakeClock()
        let deviceID: AudioDeviceID = 41
        let capture = PinnedMicrophoneCapture(
            deviceID: deviceID,
            hardwareHooks: .init(
                prepare: { _ in format },
                start: { _ in },
                stop: {},
                currentFormat: { _ in format },
                isAlive: { _ in true }
            ),
            clock: { clock.now }
        )
        let recordingFormat = try capture.prepare()
        let snapshot = try XCTUnwrap(AudioRecordingFormatPolicy.snapshot(recordingFormat))
        audio.withAudioGraphLock { audio.pinnedMicrophoneCapture = capture }
        try audio.startPinnedMeetingMicrophone(
            PreparedPinnedMeetingMicrophone(
                capture: capture,
                deviceID: deviceID,
                recordingFormat: recordingFormat,
                recordingSnapshot: snapshot
            ),
            writeContext: MicPCMWriteContext(
                generation: generation,
                monoFormat: format,
                inputChannelCount: 1
            ),
            sessionGeneration: generation
        )
        for _ in 0...PinnedMicrophoneCapture.maxConsecutiveRestarts {
            clock.now += PinnedMicrophoneCapture.stallTimeoutSeconds + 0.5
            capture.drainForTesting()
        }
    }

    private static let monoFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
    )!

    private static func monoBuffer(frames: Int) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        buffer.floatChannelData![0].update(repeating: 0, count: frames)
        return buffer
    }

    private func assertStop(
        reportsCause cause: InternalCaptureStopCause,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let audio = try makeRecordingAudio()
        XCTAssertNil(audio.internalStopCause, "a fresh recording starts with no cause", file: file, line: line)
        let completed = expectation(description: "\(cause.rawValue) stop finished")
        audio.onRecordingComplete = { _, _ in completed.fulfill() }

        try trigger(cause, on: audio)
        wait(for: [completed], timeout: 15)

        XCTAssertFalse(audio.isRecording, "\(cause.rawValue) must end the recording", file: file, line: line)
        XCTAssertEqual(audio.internalStopCause, cause, file: file, line: line)
    }

    /// Lets main-queue work already scheduled by the code under test run.
    private func settleMainQueue() {
        let settled = expectation(description: "main queue settled")
        DispatchQueue.main.async { settled.fulfill() }
        wait(for: [settled], timeout: 5)
    }

    // MARK: - One test per stop path

    func testMicRecoveryGivingUpReportsItsOwnCause() throws {
        try assertStop(reportsCause: .micRecoveryGaveUp)
    }

    func testPinnedMicFailureReportsItsOwnCause() throws {
        try assertStop(reportsCause: .pinnedMicFailed)
    }

    func testCriticallyLowDiskReportsItsOwnCause() throws {
        try assertStop(reportsCause: .diskLow)
    }

    func testMicWriteFailuresReportTheirOwnCause() throws {
        try assertStop(reportsCause: .micWriteFailed)
    }

    func testMicWriteBacklogReportsItsOwnCause() throws {
        try assertStop(reportsCause: .micWriteBackpressure)
    }

    func testSystemWriteBacklogReportsItsOwnCause() throws {
        try assertStop(reportsCause: .systemWriteBackpressure)
    }

    // MARK: - Where no cause may be left behind

    func testLowButNotCriticalDiskSpaceKeepsRecordingAndLeavesNoCause() throws {
        let audio = try makeRecordingAudio()

        audio.reactToFreeDiskSpace(80_000_000)
        settleMainQueue()

        XCTAssertTrue(audio.isRecording)
        XCTAssertNil(audio.internalStopCause)
    }

    func testWriteFailureCapAfterTheRecordingEndedLeavesNoCause() throws {
        let audio = try makeRecordingAudio()
        audio.isRecording = false

        for _ in 1..<audio.maxConsecutiveWriteErrors {
            XCTAssertFalse(audio.recordMicWriteFailure(WriteFailure()))
        }
        XCTAssertTrue(audio.recordMicWriteFailure(WriteFailure()), "the cap itself is still reported")
        settleMainQueue()

        XCTAssertNil(
            audio.internalStopCause,
            "a stop that never happened must not tag the recording"
        )
    }

    func testAnOrdinaryStopLeavesNoCause() throws {
        let audio = try makeRecordingAudio()
        let completed = expectation(description: "stop finished")
        audio.onRecordingComplete = { _, _ in completed.fulfill() }

        audio.stop()
        wait(for: [completed], timeout: 15)

        XCTAssertFalse(audio.isRecording)
        XCTAssertNil(audio.internalStopCause, "an app-side stop has no Core cause")
    }

    func testTheNextRecordingStartsWithNoCause() throws {
        let audio = try makeRecordingAudio()
        let completed = expectation(description: "stop finished")
        audio.onRecordingComplete = { _, _ in completed.fulfill() }
        audio.reactToFreeDiskSpace(10_000_000)
        wait(for: [completed], timeout: 15)
        XCTAssertEqual(audio.internalStopCause, .diskLow)

        audio.prepareForNewRecordingStart()

        XCTAssertNil(
            audio.internalStopCause,
            "last meeting's cause must not be reported for the next meeting's stop"
        )
    }
}
