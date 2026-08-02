import XCTest
@preconcurrency import AVFoundation
import Combine
@testable import TranscriptedCore

@available(macOS 14.0, *)
final class AudioInitializationTests: XCTestCase {

    func testMicRecoveryOnlySucceedsAfterANewBuffer() {
        XCTAssertFalse(
            MicRecoveryReadinessPolicy.deliveredNewBuffer(before: 10, after: 10),
            "a running engine without a new frame must not count as recovered"
        )
        XCTAssertTrue(
            MicRecoveryReadinessPolicy.deliveredNewBuffer(before: 10, after: 11),
            "the first post-restart frame confirms recovery"
        )
    }

    func testMicRecoveryRetryDropsOnlyDisconnectedDeviceSelections() {
        XCTAssertTrue(
            MicRecoveryRetryPolicy.shouldResetMeetingSelectionBeforeRetry(for: .deviceChange),
            "a disconnected pinned mic must not block the built-in fallback retry"
        )
        XCTAssertFalse(
            MicRecoveryRetryPolicy.shouldResetMeetingSelectionBeforeRetry(for: .processingChange),
            "a consented processing restart should keep the active meeting mic pinned"
        )
    }

    func testMicBufferCallbackArmsWatchdogOnlyOnce() {
        XCTAssertFalse(
            MicWatchdogArmingPolicy.shouldArm(afterNonemptyBufferCount: 0),
            "the buffer callback has nothing to arm before a mic frame arrives"
        )
        XCTAssertTrue(
            MicWatchdogArmingPolicy.shouldArm(afterNonemptyBufferCount: 1)
        )
        XCTAssertFalse(
            MicWatchdogArmingPolicy.shouldArm(afterNonemptyBufferCount: 2),
            "later frames must not create duplicate watchdog timers"
        )
    }

    func testSuccessfulStartArmsWatchdogBeforeTheFirstMicFrame() {
        XCTAssertTrue(
            MicWatchdogArmingPolicy.shouldArmAfterSuccessfulStart(watchdogIsArmed: false),
            "a started graph with zero frames still needs bounded recovery"
        )
        XCTAssertFalse(
            MicWatchdogArmingPolicy.shouldArmAfterSuccessfulStart(watchdogIsArmed: true),
            "the first mic frame may already have armed the watchdog"
        )
    }

    func testWatchdogStopsForACompletedRecordingSession() {
        XCTAssertFalse(
            MicWatchdogSessionPolicy.shouldRun(
                watchdogGeneration: 7,
                currentGeneration: 8,
                isRecording: true,
                isRecovering: false
            ),
            "a timer from the stopped session must not recover during teardown"
        )
        XCTAssertTrue(
            MicWatchdogSessionPolicy.shouldRun(
                watchdogGeneration: 8,
                currentGeneration: 8,
                isRecording: true,
                isRecovering: false
            )
        )
        XCTAssertFalse(
            MicWatchdogSessionPolicy.shouldRun(
                watchdogGeneration: 8,
                currentGeneration: 8,
                isRecording: false,
                isRecovering: false
            )
        )
    }

    func testStaleMeetingGraphAttemptDoesNotClaimAnInputEngine() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StaleMeetingGraphAttempt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let audio = Audio(paths: makeCoreStoragePaths(root: root))
        audio.recordingSessionGeneration = 2

        XCTAssertThrowsError(
            try audio.makeReadyMeetingInputGraph(
                operation: "start_recording",
                resetMeetingSelectionBeforeRetry: true,
                sessionGeneration: 1
            )
        ) { error in
            XCTAssertTrue(error is AudioCaptureStaleSessionError)
        }
        XCTAssertNil(audio.engine)
        XCTAssertNil(audio.inputNode)
    }

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

    func testInjectedSystemAudioBackendIsPreservedByInfrastructureSetup() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioInitializationTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let audio = Audio(
            paths: makeCoreStoragePaths(root: root),
            systemAudioCaptureForTesting: StubSystemAudioCapture()
        )
        let injectedCapture = audio.systemAudioCapture

        audio.ensureCaptureInfrastructureConfigured()

        XCTAssertTrue(
            (audio.systemAudioCapture as AnyObject) === (injectedCapture as AnyObject),
            "test-injected system-audio backends must not be replaced with ScreenCaptureKit during setup"
        )
    }

    func testInjectedSystemAudioBackendErrorsDriveAudioStatusWithoutHardware() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioInitializationTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let capture = StubSystemAudioCapture()
        let audio = Audio(
            paths: makeCoreStoragePaths(root: root),
            systemAudioCaptureForTesting: capture
        )
        audio.isRecording = true

        let statusUpdated = expectation(description: "system audio status updated from fake backend")
        var cancellables = Set<AnyCancellable>()
        audio.$systemAudioStatus
            .dropFirst()
            .sink { status in
                if status == .failed {
                    statusUpdated.fulfill()
                }
            }
            .store(in: &cancellables)

        capture.emit(errorMessage: "System audio unavailable in synthetic backend")

        wait(for: [statusUpdated], timeout: 1.0)
        XCTAssertEqual(audio.systemAudioStatus, .failed)
    }

    func testStopSynchronouslyTearsDownInjectedSystemAudioBackend() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioInitializationTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let capture = StubSystemAudioCapture()
        let stopped = expectation(description: "fake backend stopSync called")
        capture.onStopSync = {
            stopped.fulfill()
        }

        let audio = Audio(
            paths: makeCoreStoragePaths(root: root),
            systemAudioCaptureForTesting: capture
        )
        audio.systemAudioFileQueue.sync {
            _ = audio.systemAudioCaptureAttemptOwnership.begin(
                generation: audio.recordingSessionGeneration,
                capture: SystemAudioCaptureStartAttempt(capture: capture)
            )
        }

        audio.stop()

        wait(for: [stopped], timeout: 1.0)
        capture.onStopSync = nil
        XCTAssertEqual(capture.stopSyncCallCount, 1)
        XCTAssertEqual(capture.stopCallCount, 0, "recording teardown should use synchronous backend stop to avoid delayed cleanup racing the next start")
    }

    func testCancelledMonitoringAttemptCannotStartAfterDelayedPrepare() {
        let capture = StubSystemAudioCapture()
        let prepareStarted = expectation(description: "monitoring prepare started")
        let attemptFinished = expectation(description: "monitoring attempt finished")
        let releasePrepare = DispatchSemaphore(value: 0)
        capture.onPrepare = {
            prepareStarted.fulfill()
            _ = releasePrepare.wait(timeout: .now() + 2)
        }

        let attempt = SystemAudioCaptureStartAttempt(capture: capture)
        DispatchQueue.global(qos: .userInitiated).async {
            try? attempt.prepare()
            let didStart = (try? attempt.startIfNotCancelled { _ in }) ?? false
            XCTAssertFalse(didStart)
            attemptFinished.fulfill()
        }

        wait(for: [prepareStarted], timeout: 1)
        attempt.cancel()
        releasePrepare.signal()
        wait(for: [attemptFinished], timeout: 1)

        XCTAssertEqual(capture.startCallCount, 0)
        XCTAssertEqual(capture.stopSyncCallCount, 1)
    }

    func testStoppingMonitoringDoesNotWaitForBlockedSystemAudioStart() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MonitoringHandoffTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let oldCapture = StubSystemAudioCapture()
        let newCapture = StubSystemAudioCapture()
        let oldAttempt = SystemAudioCaptureStartAttempt(capture: oldCapture)
        let newAttempt = SystemAudioCaptureStartAttempt(capture: newCapture)
        let oldStartEntered = expectation(description: "old monitoring start entered")
        let oldAttemptFinished = expectation(description: "old monitoring attempt stopped")
        let oldStopFinished = expectation(description: "old monitoring backend stopped")
        let releaseOldStart = DispatchSemaphore(value: 0)
        oldCapture.onStart = {
            oldStartEntered.fulfill()
            _ = releaseOldStart.wait(timeout: .now() + 2)
        }
        oldCapture.onStopSync = {
            oldStopFinished.fulfill()
        }

        let audio = Audio(
            paths: makeCoreStoragePaths(root: root),
            systemAudioCaptureForTesting: oldCapture
        )
        XCTAssertNil(audio.replaceSystemAudioMonitoringAttempt(with: oldAttempt))

        DispatchQueue.global(qos: .userInitiated).async {
            _ = try? oldAttempt.startIfNotCancelled { _ in }
            oldAttemptFinished.fulfill()
        }
        wait(for: [oldStartEntered], timeout: 1)

        let stopStartedAt = Date()
        audio.stopMonitoring()
        XCTAssertLessThan(
            Date().timeIntervalSince(stopStartedAt),
            0.25,
            "clicking Record must not wait for a blocked monitoring start/stop"
        )
        XCTAssertTrue(
            try newAttempt.startIfNotCancelled { _ in },
            "a fresh recording attempt must be able to start while old monitoring tears down"
        )

        releaseOldStart.signal()
        wait(for: [oldAttemptFinished, oldStopFinished], timeout: 1)
        oldCapture.onStopSync = nil
        XCTAssertEqual(oldCapture.stopSyncCallCount, 1)
        XCTAssertEqual(newCapture.startCallCount, 1)
        XCTAssertEqual(newCapture.stopSyncCallCount, 0)
    }

    func testDisplacedDelayedAttemptCannotStartOrStopReplacementAttempt() throws {
        let oldCapture = StubSystemAudioCapture()
        let newCapture = StubSystemAudioCapture()
        let oldAttempt = SystemAudioCaptureStartAttempt(capture: oldCapture)
        let newAttempt = SystemAudioCaptureStartAttempt(capture: newCapture)
        let prepareStarted = expectation(description: "old prepare started")
        let oldAttemptFinished = expectation(description: "old attempt finished")
        let releasePrepare = DispatchSemaphore(value: 0)
        oldCapture.onPrepare = {
            prepareStarted.fulfill()
            _ = releasePrepare.wait(timeout: .now() + 2)
        }

        var ownership =
            SystemAudioCaptureAttemptOwnership<SystemAudioCaptureStartAttempt, NSObject>()
        XCTAssertNil(ownership.begin(generation: 1, capture: oldAttempt))

        DispatchQueue.global(qos: .userInitiated).async {
            try? oldAttempt.prepare()
            _ = try? oldAttempt.startIfNotCancelled { _ in }
            oldAttemptFinished.fulfill()
        }
        wait(for: [prepareStarted], timeout: 1)

        let displaced = try XCTUnwrap(
            ownership.begin(generation: 2, capture: newAttempt)
        )
        displaced.capture.cancel()
        XCTAssertTrue(try newAttempt.startIfNotCancelled { _ in })

        releasePrepare.signal()
        wait(for: [oldAttemptFinished], timeout: 1)

        XCTAssertEqual(oldCapture.startCallCount, 0)
        XCTAssertEqual(oldCapture.stopSyncCallCount, 1)
        XCTAssertEqual(newCapture.startCallCount, 1)
        XCTAssertEqual(newCapture.stopSyncCallCount, 0)
        XCTAssertTrue(ownership.owns(generation: 2, capture: newAttempt))
    }

    func testRecordingCaptureFactoryCreatesDistinctRetryAttempts() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SystemCaptureFactoryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let firstCapture = StubSystemAudioCapture()
        let secondCapture = StubSystemAudioCapture()
        let captures = CaptureFactorySequence([firstCapture, secondCapture])
        let audio = Audio(
            paths: makeCoreStoragePaths(root: root),
            systemAudioCaptureForTesting: nil,
            systemAudioCaptureFactoryForTesting: { captures.next() }
        )

        let first = audio.makeSystemAudioCaptureForRecordingAttempt()
        let second = audio.makeSystemAudioCaptureForRecordingAttempt()

        XCTAssertTrue((first as AnyObject) === firstCapture)
        XCTAssertTrue((second as AnyObject) === secondCapture)
        XCTAssertFalse((first as AnyObject) === (second as AnyObject))
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

        let oldSystemCapture = StubSystemAudioCapture()
        let newSystemCapture = StubSystemAudioCapture()
        let audio = Audio(
            paths: paths,
            systemAudioCaptureForTesting: oldSystemCapture
        )
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
        let oldSystemAttempt = SystemAudioCaptureStartAttempt(capture: oldSystemCapture)
        let newSystemAttempt = SystemAudioCaptureStartAttempt(capture: newSystemCapture)

        audio.originalMicAudioFileURL = oldMicURL
        audio.micSegments = [MicRecordingSegment(url: oldMicURL)]
        audio.micAudioFileURL = oldMicURL
        audio.systemAudioFileURL = oldSystemURL
        _ = audio.micAudioFileQueue.sync {
            audio.micAudioFileOwnership.installSessionWriter(
                oldMicFile,
                generation: audio.recordingSessionGeneration
            )
        }
        audio.systemAudioFileQueue.sync {
            _ = audio.systemAudioCaptureAttemptOwnership.begin(
                generation: audio.recordingSessionGeneration,
                capture: oldSystemAttempt
            )
            XCTAssertTrue(
                audio.systemAudioCaptureAttemptOwnership.install(
                    oldSystemFile,
                    generation: audio.recordingSessionGeneration,
                    capture: oldSystemAttempt
                )
            )
        }

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
        audio.systemAudioCapture = newSystemCapture
        _ = audio.micAudioFileQueue.sync {
            audio.micAudioFileOwnership.installSessionWriter(
                newMicFile,
                generation: audio.recordingSessionGeneration
            )
        }
        audio.systemAudioFileQueue.sync {
            _ = audio.systemAudioCaptureAttemptOwnership.begin(
                generation: audio.recordingSessionGeneration,
                capture: newSystemAttempt
            )
            XCTAssertTrue(
                audio.systemAudioCaptureAttemptOwnership.install(
                    newSystemFile,
                    generation: audio.recordingSessionGeneration,
                    capture: newSystemAttempt
                )
            )
        }

        releaseLock.signal()
        wait(for: [stopFinished], timeout: 1.0)

        XCTAssertEqual(completedMicURL, oldMicURL)
        XCTAssertEqual(completedSystemURL, oldSystemURL)
        XCTAssertEqual(audio.recordingSessionGeneration, newGeneration)
        XCTAssertEqual(audio.originalMicAudioFileURL, newMicURL)
        XCTAssertEqual(audio.micAudioFileURL, newMicURL)
        XCTAssertEqual(audio.systemAudioFileURL, newSystemURL)

        let activeMicFile = audio.micAudioFileQueue.sync {
            audio.micAudioFileOwnership.writer
        }
        let activeSystemFile = audio.systemAudioFileQueue.sync {
            audio.systemAudioCaptureAttemptOwnership.writerOwned(
                by: newGeneration,
                capture: newSystemAttempt
            )
        }
        XCTAssertNotNil(activeMicFile)
        XCTAssertNotNil(activeSystemFile)
        XCTAssertTrue(activeMicFile === newMicFile)
        XCTAssertTrue(activeSystemFile === newSystemFile)
        XCTAssertEqual(oldSystemCapture.stopSyncCallCount, 1)
        XCTAssertEqual(newSystemCapture.stopSyncCallCount, 0)
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
        audio.watchdogTimer = Timer(timeInterval: 2, repeats: true) { _ in }
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
        XCTAssertNil(audio.watchdogTimer)
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

    func testMicWriteErrorCapStopsRecordingAndSurfacesError() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioInitializationTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let audio = Audio(paths: makeCoreStoragePaths(root: root))
        audio.isRecording = true

        var cancellables = Set<AnyCancellable>()
        let stopped = expectation(description: "recording stops after the write-error cap")
        audio.$isRecording
            .dropFirst()
            .filter { $0 == false }
            .sink { _ in stopped.fulfill() }
            .store(in: &cancellables)

        struct WriteFailure: Error {}
        for attempt in 1...audio.maxConsecutiveWriteErrors {
            let tripped = audio.recordMicWriteFailure(WriteFailure())
            XCTAssertEqual(
                tripped,
                attempt == audio.maxConsecutiveWriteErrors,
                "only the cap-th consecutive failure should trip the terminal stop (attempt \(attempt))"
            )
        }

        wait(for: [stopped], timeout: 2.0)
        XCTAssertFalse(
            audio.isRecording,
            "hitting the write-error cap must stop the recording, not leave it running silently"
        )
        XCTAssertNotNil(
            audio.error,
            "hitting the write-error cap must surface a user-facing error"
        )
    }

    func testMicWriteFailuresBelowCapKeepRecording() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioInitializationTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let audio = Audio(paths: makeCoreStoragePaths(root: root))
        audio.isRecording = true

        struct WriteFailure: Error {}
        for _ in 1..<audio.maxConsecutiveWriteErrors {
            XCTAssertFalse(
                audio.recordMicWriteFailure(WriteFailure()),
                "failures below the cap must not trip the terminal stop"
            )
        }

        // Drain the main queue so any erroneously-scheduled stop would land.
        let pumped = expectation(description: "main queue drained")
        DispatchQueue.main.async { pumped.fulfill() }
        wait(for: [pumped], timeout: 1.0)

        XCTAssertTrue(
            audio.isRecording,
            "below the cap the recording must keep running"
        )
        XCTAssertNil(audio.error)
    }

    func testSystemAudioStreamingDefaultsFalseAndResetsOnNewStart() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioInitializationTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let audio = Audio(paths: makeCoreStoragePaths(root: root))
        XCTAssertFalse(
            audio.systemAudioStreaming,
            "a fresh Audio must not claim the system-audio tap is streaming before any buffer arrives"
        )

        audio.systemAudioStreaming = true
        audio.prepareForNewRecordingStart()
        XCTAssertFalse(
            audio.systemAudioStreaming,
            "each new recording must re-gate readiness on a fresh first system-audio buffer"
        )
    }

    func testMarkSystemAudioStreamingOnlyArmsForTheCurrentSession() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioInitializationTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let audio = Audio(paths: makeCoreStoragePaths(root: root))
        audio.prepareForNewRecordingStart()
        let currentGeneration = audio.recordingSessionGeneration

        // A buffer tagged with a finished session must not re-arm readiness.
        let staleHandled = expectation(description: "stale streaming mark drained")
        audio.markSystemAudioStreamingIfCurrent(sessionGeneration: currentGeneration &- 1)
        DispatchQueue.main.async { staleHandled.fulfill() }
        wait(for: [staleHandled], timeout: 1.0)
        XCTAssertFalse(
            audio.systemAudioStreaming,
            "a first buffer from a previous session must not mark the new session as streaming"
        )

        // The current session's first buffer marks the tap as streaming.
        let currentHandled = expectation(description: "current streaming mark drained")
        audio.markSystemAudioStreamingIfCurrent(sessionGeneration: currentGeneration)
        DispatchQueue.main.async { currentHandled.fulfill() }
        wait(for: [currentHandled], timeout: 1.0)
        XCTAssertTrue(
            audio.systemAudioStreaming,
            "the current session's first system-audio buffer must mark the tap as streaming"
        )
    }

    func testMeetingRouteStabilityWarningIsDeduplicatedAndAttemptsStayBucketed() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioInitializationTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let audio = Audio(paths: makeCoreStoragePaths(root: root))
        var warningOutcomes: [CaptureRouteStabilizationOutcome] = []
        audio.onCaptureLifecycleCue = { cue in
            if case .meetingRouteStabilityWarning(let outcome) = cue {
                warningOutcomes.append(outcome)
            }
        }

        XCTAssertEqual(audio.meetingRouteStabilizationAttemptBucket, "0")
        for _ in 0..<10 {
            audio.recordMeetingRouteStabilizationAttempt(outcome: .switchedToBuiltIn)
        }
        XCTAssertEqual(audio.meetingRouteStabilizationAttemptBucket, "10_plus")

        audio.emitMeetingRouteStabilityWarningIfNeeded(outcome: .switchedToBuiltIn)
        audio.emitMeetingRouteStabilityWarningIfNeeded(outcome: .switchFailed)

        XCTAssertEqual(warningOutcomes, [.switchedToBuiltIn])
        XCTAssertTrue(audio.meetingRouteStabilityWarningEmitted)

        audio.resetMeetingRouteState()
        XCTAssertEqual(audio.meetingRouteStabilizationAttemptBucket, "0")
        XCTAssertEqual(audio.meetingRouteStabilizationOutcomeValue, "not_needed")
        XCTAssertFalse(audio.meetingRouteStabilityWarningEmitted)
    }
}

@available(macOS 14.0, *)
private func makeCoreStoragePaths(root: URL) -> CoreStoragePaths {
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

@available(macOS 14.0, *)
private final class StubSystemAudioCapture: SystemAudioCaptureEngine, @unchecked Sendable {
    private let subject = PassthroughSubject<String?, Never>()
    private let lock = NSLock()
    private var _stopCallCount = 0
    private var _stopSyncCallCount = 0
    private var _startCallCount = 0

    var diagnosticBackendName: String { "stub_system_audio" }
    var audioFormat: AVAudioFormat?
    var bufferSuccessRate: Double { 0 }
    var deliversOwnedAudioBuffers: Bool { true }
    var errorMessagePublisher: AnyPublisher<String?, Never> {
        subject.eraseToAnyPublisher()
    }
    var onStopSync: (() -> Void)?
    var onPrepare: (() -> Void)?
    var onStart: (() -> Void)?

    var stopCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _stopCallCount
    }

    var stopSyncCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _stopSyncCallCount
    }

    var startCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _startCallCount
    }

    func prepare() throws {
        onPrepare?()
    }

    func start(bufferCallback: @escaping (AVAudioPCMBuffer) -> Void) throws {
        lock.lock()
        _startCallCount += 1
        lock.unlock()
        onStart?()
    }

    func stop() {
        lock.lock()
        _stopCallCount += 1
        lock.unlock()
    }

    func stopSync() {
        lock.lock()
        _stopSyncCallCount += 1
        lock.unlock()
        onStopSync?()
    }

    func emit(errorMessage: String?) {
        subject.send(errorMessage)
    }
}

@available(macOS 14.0, *)
private final class CaptureFactorySequence: @unchecked Sendable {
    private let lock = NSLock()
    private var captures: [any SystemAudioCaptureEngine & Sendable]

    init(_ captures: [any SystemAudioCaptureEngine & Sendable]) {
        self.captures = captures
    }

    func next() -> (any SystemAudioCaptureEngine & Sendable)? {
        lock.lock()
        defer { lock.unlock() }
        guard !captures.isEmpty else { return nil }
        return captures.removeFirst()
    }
}
