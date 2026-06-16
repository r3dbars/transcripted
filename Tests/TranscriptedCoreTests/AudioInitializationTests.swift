import XCTest
@preconcurrency import AVFoundation
@testable import TranscriptedCore

@available(macOS 14.0, *)
final class AudioInitializationTests: XCTestCase {

    func testAudioInitDoesNotEagerlyCreateMicEngine() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioInitializationTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = CoreStoragePaths(
            transcripts: root.appendingPathComponent("captures/meetings", isDirectory: true),
            speakerDB: root.appendingPathComponent("state/speakers.sqlite"),
            statsDB: root.appendingPathComponent("state/stats.sqlite"),
            failedQueue: root.appendingPathComponent("state/failed_transcriptions.json"),
            speakerClips: root.appendingPathComponent("tmp/recordings/speaker_clips", isDirectory: true),
            audioCaptures: root.appendingPathComponent("tmp/recordings", isDirectory: true),
            logs: root.appendingPathComponent("logs", isDirectory: true)
        )

        let audio = Audio(paths: paths)

        XCTAssertNil(audio.engine)
        XCTAssertNil(audio.inputNode)
        XCTAssertNil(audio.systemAudioCapture)
    }

    func testAudioDefaultsVoiceProcessingOff() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioInitializationTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = CoreStoragePaths(
            transcripts: root.appendingPathComponent("captures/meetings", isDirectory: true),
            speakerDB: root.appendingPathComponent("state/speakers.sqlite"),
            statsDB: root.appendingPathComponent("state/stats.sqlite"),
            failedQueue: root.appendingPathComponent("state/failed_transcriptions.json"),
            speakerClips: root.appendingPathComponent("tmp/recordings/speaker_clips", isDirectory: true),
            audioCaptures: root.appendingPathComponent("tmp/recordings", isDirectory: true),
            logs: root.appendingPathComponent("logs", isDirectory: true)
        )

        let audio = Audio(paths: paths)

        // Default off: existing users on v1.1.24 (where VPIO was
        // unconditionally on) should land on the no-Zoom-ducking path
        // after upgrade unless they explicitly opt in via Settings.
        XCTAssertFalse(audio.enableVoiceProcessing,
                       "enableVoiceProcessing must default to false to avoid the system-wide ducking regression")
    }

    func testAudioRecordingFormatPolicyRejectsInvalidSampleRatesBeforeCreatingFormats() throws {
        for sampleRate in [0, -1, Double.nan, Double.infinity, -Double.infinity, 7_999, 384_001] {
            XCTAssertFalse(
                AudioRecordingFormatPolicy.isUsableSampleRate(sampleRate),
                "sample rate \(sampleRate) should not be accepted for CoreAudio format creation"
            )
            XCTAssertThrowsError(
                try AudioRecordingFormatPolicy.makeMonoOutputFormat(sampleRate: sampleRate),
                "invalid sample rates must throw before AVAudioFormat is asked to build a format"
            )
        }

        let monoFormat = try AudioRecordingFormatPolicy.makeMonoOutputFormat(sampleRate: 48_000)
        XCTAssertEqual(monoFormat.sampleRate, 48_000, accuracy: 0.1)
        XCTAssertEqual(monoFormat.channelCount, 1)
    }

    func testAudioRecordingFormatPolicySnapshotsOnlyUsableFormats() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ))

        let snapshot = try XCTUnwrap(AudioRecordingFormatPolicy.snapshot(format))

        XCTAssertEqual(snapshot.sampleRate, 48_000, accuracy: 0.1)
        XCTAssertEqual(snapshot.channelCount, 2)
    }

    func testInputTapTeardownStopsRunningEngineBeforeRemovingTap() {
        XCTAssertEqual(
            AudioInputTapTeardownPolicy.steps(engineIsRunning: true),
            [.stopEngine, .waitForStoppedInputCallbacks, .removeInputTap],
            "Running AVAudioEngine graphs must stop and drain input callbacks before removing the tap so CoreAudio never receives input with tap == nil"
        )
        XCTAssertEqual(
            AudioInputTapTeardownPolicy.steps(engineIsRunning: false),
            [.removeInputTap],
            "Stopped engines can remove the tap directly without the drain delay"
        )
    }

    /// Regression guard for the fatal audio-thread crash
    /// `com.apple.coreaudio.avfaudio: required condition is false: isSink || tap != nullptr`
    /// (Sentry r3dbars/apple-macos issue 7479438309). Both the meeting/mic path
    /// (`Audio.tearDownInputTapSafely`) and the dictation path
    /// (`ParakeetEngine.safelyRemoveInputTap`) now route every input-tap teardown
    /// through this policy, so for any running engine the tap must never be
    /// removed before the engine is stopped — otherwise CoreAudio can deliver
    /// input to a tap-less, sink-less node and crash the process.
    func testRunningEngineTeardownNeverRemovesTapBeforeStopping() {
        let steps = AudioInputTapTeardownPolicy.steps(engineIsRunning: true)
        let stopIndex = steps.firstIndex(of: .stopEngine)
        let removeIndex = steps.firstIndex(of: .removeInputTap)

        let stop = try? XCTUnwrap(stopIndex, "Running-engine teardown must stop the engine")
        let remove = try? XCTUnwrap(removeIndex, "Teardown must remove the input tap")

        if let stop, let remove {
            XCTAssertLessThan(
                stop,
                remove,
                "Stopping the engine must come before removing the tap to avoid the isSink || tap != nullptr assertion"
            )
        } else {
            XCTFail("Running-engine teardown must contain both .stopEngine and .removeInputTap")
        }
    }

    func testStopOnIdleAudioDoesNotCrashAndBumpsGeneration() {
        // The stop refactor moves engine teardown to a background queue.
        // On a fresh Audio with no engine, stop() should still:
        //   - synchronously bump the recordingSessionGeneration so any
        //     concurrent recovery work observes the new boundary
        //   - return immediately to the caller
        //   - not crash on the missing engine reference
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioInitializationTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = CoreStoragePaths(
            transcripts: root.appendingPathComponent("captures/meetings", isDirectory: true),
            speakerDB: root.appendingPathComponent("state/speakers.sqlite"),
            statsDB: root.appendingPathComponent("state/stats.sqlite"),
            failedQueue: root.appendingPathComponent("state/failed_transcriptions.json"),
            speakerClips: root.appendingPathComponent("tmp/recordings/speaker_clips", isDirectory: true),
            audioCaptures: root.appendingPathComponent("tmp/recordings", isDirectory: true),
            logs: root.appendingPathComponent("logs", isDirectory: true)
        )

        let audio = Audio(paths: paths)
        let initialGeneration = audio.recordingSessionGeneration

        audio.stop()

        XCTAssertEqual(
            audio.recordingSessionGeneration,
            initialGeneration &+ 1,
            "stop() must synchronously bump the recording session generation so concurrent recovery work invalidates correctly"
        )
    }

    func testStopWaitsForAudioGraphLockBeforeFinishingTeardown() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioInitializationTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = CoreStoragePaths(
            transcripts: root.appendingPathComponent("captures/meetings", isDirectory: true),
            speakerDB: root.appendingPathComponent("state/speakers.sqlite"),
            statsDB: root.appendingPathComponent("state/stats.sqlite"),
            failedQueue: root.appendingPathComponent("state/failed_transcriptions.json"),
            speakerClips: root.appendingPathComponent("tmp/recordings/speaker_clips", isDirectory: true),
            audioCaptures: root.appendingPathComponent("tmp/recordings", isDirectory: true),
            logs: root.appendingPathComponent("logs", isDirectory: true)
        )

        let audio = Audio(paths: paths)
        let initialGeneration = audio.recordingSessionGeneration
        let lockHeld = expectation(description: "audio graph lock held")
        let earlyStopFinish = expectation(description: "stop completion stays blocked while lock is held")
        earlyStopFinish.isInverted = true
        let stopFinished = expectation(description: "stop completion fired")
        let releaseLock = DispatchSemaphore(value: 0)
        let completionStateLock = NSLock()
        var allowCompletion = false

        audio.onRecordingComplete = { _, _ in
            completionStateLock.lock()
            let shouldTreatAsFinalCompletion = allowCompletion
            completionStateLock.unlock()

            if shouldTreatAsFinalCompletion {
                stopFinished.fulfill()
            } else {
                earlyStopFinish.fulfill()
            }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            audio.withAudioGraphLock {
                lockHeld.fulfill()
                _ = releaseLock.wait(timeout: .now() + 2)
            }
        }

        wait(for: [lockHeld], timeout: 1.0)

        audio.stop()

        XCTAssertEqual(
            audio.recordingSessionGeneration,
            initialGeneration &+ 1,
            "stop() must still invalidate the current session immediately while teardown waits for the shared audio graph lock"
        )

        wait(for: [earlyStopFinish], timeout: 0.1)

        completionStateLock.lock()
        allowCompletion = true
        completionStateLock.unlock()
        releaseLock.signal()

        wait(for: [stopFinished], timeout: 1.0)
    }

    func testStaleStopDoesNotOverwriteNewSessionArtifactsOrFileHandles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioInitializationTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = CoreStoragePaths(
            transcripts: root.appendingPathComponent("captures/meetings", isDirectory: true),
            speakerDB: root.appendingPathComponent("state/speakers.sqlite"),
            statsDB: root.appendingPathComponent("state/stats.sqlite"),
            failedQueue: root.appendingPathComponent("state/failed_transcriptions.json"),
            speakerClips: root.appendingPathComponent("tmp/recordings/speaker_clips", isDirectory: true),
            audioCaptures: root.appendingPathComponent("tmp/recordings", isDirectory: true),
            logs: root.appendingPathComponent("logs", isDirectory: true)
        )
        try FileManager.default.createDirectory(at: paths.audioCaptures, withIntermediateDirectories: true)

        let audio = Audio(paths: paths)
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ))

        let oldMicURL = paths.audioCaptures.appendingPathComponent("old-mic.wav")
        let oldSystemURL = paths.audioCaptures.appendingPathComponent("old-system.wav")
        let newMicURL = paths.audioCaptures.appendingPathComponent("new-mic.wav")
        let newSystemURL = paths.audioCaptures.appendingPathComponent("new-system.wav")
        let oldMicFile = try AVAudioFile(forWriting: oldMicURL, settings: format.settings)
        let oldSystemFile = try AVAudioFile(forWriting: oldSystemURL, settings: format.settings)
        let newMicFile = try AVAudioFile(forWriting: newMicURL, settings: format.settings)
        let newSystemFile = try AVAudioFile(forWriting: newSystemURL, settings: format.settings)

        audio.originalMicAudioFileURL = oldMicURL
        audio.micSegments = [MicRecordingSegment(url: oldMicURL)]
        audio.micAudioFileURL = oldMicURL
        audio.systemAudioFileURL = oldSystemURL
        audio.micAudioFileQueue.sync { audio.micAudioFile = oldMicFile }
        audio.systemAudioFileQueue.sync { audio.systemAudioFile = oldSystemFile }

        let lockHeld = expectation(description: "audio graph lock held")
        let releaseLock = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            audio.withAudioGraphLock {
                lockHeld.fulfill()
                _ = releaseLock.wait(timeout: .now() + 2)
            }
        }
        wait(for: [lockHeld], timeout: 1.0)

        let stopFinished = expectation(description: "stale stop completion fired")
        var completedMicURL: URL?
        var completedSystemURL: URL?
        audio.onRecordingComplete = { micURL, systemURL in
            completedMicURL = micURL
            completedSystemURL = systemURL
            stopFinished.fulfill()
        }

        audio.stop()
        audio.prepareForNewRecordingStart()
        let newGeneration = audio.recordingSessionGeneration
        audio.originalMicAudioFileURL = newMicURL
        audio.micSegments = [MicRecordingSegment(url: newMicURL)]
        audio.micAudioFileURL = newMicURL
        audio.systemAudioFileURL = newSystemURL
        audio.micAudioFileQueue.sync { audio.micAudioFile = newMicFile }
        audio.systemAudioFileQueue.sync { audio.systemAudioFile = newSystemFile }

        releaseLock.signal()
        wait(for: [stopFinished], timeout: 1.0)

        XCTAssertEqual(completedMicURL, oldMicURL)
        XCTAssertEqual(completedSystemURL, oldSystemURL)
        XCTAssertEqual(audio.recordingSessionGeneration, newGeneration)
        XCTAssertEqual(audio.originalMicAudioFileURL, newMicURL)
        XCTAssertEqual(audio.micAudioFileURL, newMicURL)
        XCTAssertEqual(audio.systemAudioFileURL, newSystemURL)

        let activeMicFile = audio.micAudioFileQueue.sync { audio.micAudioFile }
        let activeSystemFile = audio.systemAudioFileQueue.sync { audio.systemAudioFile }
        XCTAssertNotNil(activeMicFile)
        XCTAssertNotNil(activeSystemFile)
        XCTAssertTrue(activeMicFile === newMicFile)
        XCTAssertTrue(activeSystemFile === newSystemFile)
    }

    func testPrepareForNewRecordingStartClearsStaleCaptureArtifacts() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioInitializationTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = CoreStoragePaths(
            transcripts: root.appendingPathComponent("captures/meetings", isDirectory: true),
            speakerDB: root.appendingPathComponent("state/speakers.sqlite"),
            statsDB: root.appendingPathComponent("state/stats.sqlite"),
            failedQueue: root.appendingPathComponent("state/failed_transcriptions.json"),
            speakerClips: root.appendingPathComponent("tmp/recordings/speaker_clips", isDirectory: true),
            audioCaptures: root.appendingPathComponent("tmp/recordings", isDirectory: true),
            logs: root.appendingPathComponent("logs", isDirectory: true)
        )

        let audio = Audio(paths: paths)
        audio.originalMicAudioFileURL = root.appendingPathComponent("stale-mic.wav")
        audio.micAudioFileURL = root.appendingPathComponent("stale-mic.wav")
        audio.systemAudioFileURL = root.appendingPathComponent("stale-system.wav")
        audio.systemAudioFailed = true
        audio.appendMicSegment(MicRecordingSegment(url: root.appendingPathComponent("stale-segment.wav")))

        audio.prepareForNewRecordingStart()

        XCTAssertNil(audio.originalMicAudioFileURL)
        XCTAssertNil(audio.micAudioFileURL)
        XCTAssertNil(audio.systemAudioFileURL)
        XCTAssertFalse(audio.systemAudioFailed)
        XCTAssertTrue(audio.micSegments.isEmpty)
    }

    func testSuccessfulStartRestoresHealthySystemAudioStatusAfterEarlyNilUpdate() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioInitializationTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = CoreStoragePaths(
            transcripts: root.appendingPathComponent("captures/meetings", isDirectory: true),
            speakerDB: root.appendingPathComponent("state/speakers.sqlite"),
            statsDB: root.appendingPathComponent("state/stats.sqlite"),
            failedQueue: root.appendingPathComponent("state/failed_transcriptions.json"),
            speakerClips: root.appendingPathComponent("tmp/recordings/speaker_clips", isDirectory: true),
            audioCaptures: root.appendingPathComponent("tmp/recordings", isDirectory: true),
            logs: root.appendingPathComponent("logs", isDirectory: true)
        )

        let audio = Audio(paths: paths)
        audio.prepareForNewRecordingStart()
        audio.systemAudioFileURL = root.appendingPathComponent("system.wav")

        audio.updateSystemAudioStatus(fromError: nil)
        XCTAssertEqual(audio.systemAudioStatus, .unknown)

        audio.restoreSystemAudioHealthyStatusAfterSuccessfulStart()

        XCTAssertEqual(
            audio.systemAudioStatus,
            .healthy,
            "a clean system-audio file should not stay unknown after the meeting start succeeds"
        )
    }

    func testSystemAudioFileAssignmentRestoresStatusWhenSuccessfulStartFinishedFirst() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioInitializationTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = CoreStoragePaths(
            transcripts: root.appendingPathComponent("captures/meetings", isDirectory: true),
            speakerDB: root.appendingPathComponent("state/speakers.sqlite"),
            statsDB: root.appendingPathComponent("state/stats.sqlite"),
            failedQueue: root.appendingPathComponent("state/failed_transcriptions.json"),
            speakerClips: root.appendingPathComponent("tmp/recordings/speaker_clips", isDirectory: true),
            audioCaptures: root.appendingPathComponent("tmp/recordings", isDirectory: true),
            logs: root.appendingPathComponent("logs", isDirectory: true)
        )

        let audio = Audio(paths: paths)
        audio.prepareForNewRecordingStart()
        let startGeneration = audio.recordingSessionGeneration

        audio.updateSystemAudioStatus(fromError: nil)
        XCTAssertEqual(audio.systemAudioStatus, .unknown)

        audio.isRecording = true
        audio.restoreSystemAudioHealthyStatusAfterSuccessfulStart()
        XCTAssertEqual(audio.systemAudioStatus, .unknown)

        let systemURL = root.appendingPathComponent("system.wav")
        audio.assignSystemAudioFileURLIfCurrent(systemURL, sessionGeneration: startGeneration)

        XCTAssertEqual(audio.systemAudioFileURL, systemURL)
        XCTAssertEqual(
            audio.systemAudioStatus,
            .healthy,
            "when the async file URL arrives after the start finish callback, it should complete the status repair"
        )
    }
}
