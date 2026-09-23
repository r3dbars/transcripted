import XCTest
@preconcurrency import AVFoundation
import Combine
import QuartzCore
@testable import TranscriptedCore

/// Covers the mic/system-audio recovery parity work: system-audio recovery
/// events must feed the SAME `Audio.deviceSwitchCount` / `Audio.recordingGaps`
/// counters the mic path already uses, so system-audio dropouts stop being
/// invisible to `RecordingHealthInfo.captureQuality`. Also covers the
/// post-wake proactive-recovery hook reaching the system-audio backend
/// through the existing `Audio` wake observer (no second `NSWorkspace`
/// observer). Hardware-dependent SCK stream behavior is out of scope here —
/// see the PR's hardware checklist.
@available(macOS 14.0, *)
final class SystemAudioRecoveryParityTests: XCTestCase {

    private func makePaths() -> CoreStoragePaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SystemAudioRecoveryParityTests-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - Direct counter parity

    func testRecordSystemAudioDeviceSwitchFeedsSameCounterAsMicPath() {
        let audio = Audio(paths: makePaths())
        audio.isRecording = true

        audio.recordSystemAudioDeviceSwitch()
        audio.recordSystemAudioDeviceSwitch()

        XCTAssertEqual(
            audio.deviceSwitchCount, 2,
            "system-audio device switches must feed the same counter RecordingHealthInfo reads for mic-path switches"
        )
    }

    func testRecordSystemAudioDeviceSwitchNoOpsWhenNotRecording() {
        let audio = Audio(paths: makePaths())

        audio.recordSystemAudioDeviceSwitch()

        XCTAssertEqual(audio.deviceSwitchCount, 0)
    }

    func testRecordSystemAudioGapAppendsToRecordingGaps() {
        let audio = Audio(paths: makePaths())
        audio.isRecording = true

        audio.recordSystemAudioGap(duration: 4.5)

        XCTAssertEqual(audio.recordingGaps.count, 1)
        XCTAssertEqual(audio.recordingGaps.first?.reason, "System audio reconnect")
        XCTAssertEqual(audio.recordingGaps.first?.duration ?? -1, 4.5, accuracy: 0.001)
    }

    func testRecordSystemAudioGapNoOpsWhenNotRecording() {
        let audio = Audio(paths: makePaths())

        audio.recordSystemAudioGap(duration: 4.5)

        XCTAssertTrue(audio.recordingGaps.isEmpty)
    }

    func testSystemAudioDeviceSwitchesAloneDegradeCaptureQualityLikeMicPath() {
        // Before this parity fix, SCK's mid-recording restarts never touched
        // `deviceSwitchCount`, so repeated system-audio dropouts were
        // invisible to `RecordingHealthInfo.captureQuality`. Confirm they now
        // degrade it exactly the way three mic-side device switches already
        // do (see `RecordingHealthInfo.from`'s `deviceSwitchCount >= 3` rule).
        let audio = Audio(paths: makePaths())
        audio.isRecording = true
        audio.recordSystemAudioDeviceSwitch()
        audio.recordSystemAudioDeviceSwitch()
        audio.recordSystemAudioDeviceSwitch()

        let info = RecordingHealthInfo.from(audio: audio, systemCapture: nil)

        XCTAssertEqual(info.captureQuality, .degraded)
        XCTAssertEqual(info.deviceSwitches, 3)
    }

    func testSystemAudioGapAloneDegradesCaptureQualityLikeMicPath() {
        let audio = Audio(paths: makePaths())
        audio.isRecording = true
        audio.recordSystemAudioGap(duration: 2.0)

        let info = RecordingHealthInfo.from(audio: audio, systemCapture: nil)

        // A single gap with no device switches: excellent -> good, matching
        // the mic-path rule (`!recordingGaps.isEmpty` downgrades one step).
        XCTAssertEqual(info.captureQuality, .good)
        XCTAssertEqual(info.audioGaps, 1)
        XCTAssertEqual(info.gapDescriptions.first, "System audio reconnect: 2.0s")
    }

    // MARK: - Wiring through an injected backend

    func testInjectedBackendRecoveryEventsUpdateAudioCounters() {
        let capture = RecoveryEventStubSystemAudioCapture()
        let audio = Audio(paths: makePaths(), systemAudioCaptureForTesting: capture)
        audio.isRecording = true

        capture.emit(recoveryEvent: .deviceSwitch)
        capture.emit(recoveryEvent: .gap(duration: 2.5))

        waitForMainQueueToSettle()

        XCTAssertEqual(audio.deviceSwitchCount, 1)
        XCTAssertEqual(audio.recordingGaps.count, 1)
        XCTAssertEqual(audio.recordingGaps.first?.duration ?? -1, 2.5, accuracy: 0.001)
    }

    func testSystemWakeReconnectHoldsWritesButIsNotADeviceSwitch() {
        let capture = RecoveryEventStubSystemAudioCapture()
        let audio = Audio(paths: makePaths(), systemAudioCaptureForTesting: capture)
        audio.isRecording = true

        capture.emit(recoveryEvent: .systemWake)
        XCTAssertTrue(
            audio.isHoldingSystemWritesForRecoveryPad(),
            "the wake reconnect still pads the gap before new buffers are written"
        )
        capture.emit(recoveryEvent: .gap(duration: 1.5))
        waitForMainQueueToSettle()

        XCTAssertFalse(audio.isHoldingSystemWritesForRecoveryPad())
        // Hardware 2026-09-23: two lid-closes saved a clean meeting as
        // degraded because each wake counted twice toward device switches.
        XCTAssertEqual(audio.deviceSwitchCount, 0)
        XCTAssertEqual(audio.recordingGaps.count, 1, "the interruption itself is still recorded")
    }

    func testInjectedBackendRecoveryEventsIgnoredWhenNotRecording() {
        let capture = RecoveryEventStubSystemAudioCapture()
        let audio = Audio(paths: makePaths(), systemAudioCaptureForTesting: capture)
        // isRecording defaults to false.

        capture.emit(recoveryEvent: .deviceSwitch)
        capture.emit(recoveryEvent: .gap(duration: 2.5))

        waitForMainQueueToSettle()

        XCTAssertEqual(audio.deviceSwitchCount, 0)
        XCTAssertTrue(audio.recordingGaps.isEmpty)
    }

    // MARK: - Write hold must not outlive the recovery that armed it

    func testAbandonedRecoveryReleasesSystemWriteHold() {
        let capture = RecoveryEventStubSystemAudioCapture()
        let audio = Audio(paths: makePaths(), systemAudioCaptureForTesting: capture)
        audio.isRecording = true

        capture.emit(recoveryEvent: .deviceSwitch)
        XCTAssertTrue(
            audio.isHoldingSystemWritesForRecoveryPad(),
            "a recovery attempt arms the hold before the restarted stream can deliver"
        )

        capture.emit(recoveryEvent: .recoveryAbandoned)
        waitForMainQueueToSettle()

        XCTAssertFalse(
            audio.isHoldingSystemWritesForRecoveryPad(),
            "a recovery that never confirmed a buffer must release the hold, or every later system buffer is dropped for the rest of the meeting"
        )
        XCTAssertEqual(audio.deviceSwitchCount, 1)
        XCTAssertTrue(audio.recordingGaps.isEmpty, "an abandoned recovery is not a gap")
    }

    func testOverlappingRecoveriesKeepTheHoldUntilTheLastOneEnds() {
        // `.gap` is handled on main, so a successor recovery can arm before
        // the predecessor's release runs. Each arm must be balanced by its
        // own release; the first release must not drop the second hold.
        let capture = RecoveryEventStubSystemAudioCapture()
        let audio = Audio(paths: makePaths(), systemAudioCaptureForTesting: capture)
        audio.isRecording = true

        capture.emit(recoveryEvent: .deviceSwitch)
        capture.emit(recoveryEvent: .deviceSwitch)
        capture.emit(recoveryEvent: .gap(duration: 0.5))
        waitForMainQueueToSettle()
        XCTAssertTrue(
            audio.isHoldingSystemWritesForRecoveryPad(),
            "the predecessor's gap must not release the successor's hold"
        )

        capture.emit(recoveryEvent: .recoveryAbandoned)
        waitForMainQueueToSettle()
        XCTAssertFalse(audio.isHoldingSystemWritesForRecoveryPad())

        // An unbalanced release cannot go negative and wedge the next arm.
        capture.emit(recoveryEvent: .recoveryAbandoned)
        capture.emit(recoveryEvent: .deviceSwitch)
        XCTAssertTrue(audio.isHoldingSystemWritesForRecoveryPad())
    }

    func testGapWhileNotRecordingStillReleasesSystemWriteHold() {
        let capture = RecoveryEventStubSystemAudioCapture()
        let audio = Audio(paths: makePaths(), systemAudioCaptureForTesting: capture)
        // isRecording defaults to false: no pad is written, but the hold
        // still has to come down.

        capture.emit(recoveryEvent: .deviceSwitch)
        capture.emit(recoveryEvent: .gap(duration: 1.0))
        waitForMainQueueToSettle()

        XCTAssertFalse(audio.isHoldingSystemWritesForRecoveryPad())
    }

    // MARK: - Post-wake proactive recovery hook

    func testPostWakeProactiveRecoveryReachesInjectedSystemAudioBackend() {
        let capture = RecoveryEventStubSystemAudioCapture()
        let center = NotificationCenter()
        let notifications = AudioSleepWakeNotifications(
            center: center,
            willSleepName: Notification.Name("SystemAudioRecoveryParityTests.WillSleep"),
            didWakeName: Notification.Name("SystemAudioRecoveryParityTests.DidWake")
        )
        let audio = Audio(
            paths: makePaths(),
            systemAudioCaptureForTesting: capture,
            sleepWakeNotifications: notifications
        )
        // Mirrors what `ensureCaptureInfrastructureConfigured()` does for a
        // real recording; called directly here since this test injects the
        // backend instead of going through infrastructure setup.
        audio.installWorkspaceSleepWakeObservers()
        audio.isRecording = true

        center.post(name: notifications.willSleepName, object: nil)
        center.post(name: notifications.didWakeName, object: nil)

        // The wake handler waits ~0.5s and then ~1.0s before the proactive
        // kick, matching the mic path's existing timing. Poll instead of a
        // single fixed wait so a regression fails fast rather than always
        // paying the full timeout.
        let calledBack = expectation(description: "system-audio backend got a proactive post-wake recovery opportunity")
        let deadline = Date().addingTimeInterval(3.0)
        DispatchQueue.global(qos: .utility).async {
            while Date() < deadline {
                if capture.recoverAfterSystemWakeCallCount > 0 {
                    calledBack.fulfill()
                    return
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        wait(for: [calledBack], timeout: 3.5)
    }

    // MARK: - Mic recovery across system sleep

    private func makeSleepingAudio(_ name: String) -> (Audio, NotificationCenter, AudioSleepWakeNotifications) {
        let center = NotificationCenter()
        let notifications = AudioSleepWakeNotifications(
            center: center,
            willSleepName: Notification.Name("SystemAudioRecoveryParityTests.\(name).WillSleep"),
            didWakeName: Notification.Name("SystemAudioRecoveryParityTests.\(name).DidWake")
        )
        let audio = Audio(
            paths: makePaths(),
            systemAudioCaptureForTesting: RecoveryEventStubSystemAudioCapture(),
            sleepWakeNotifications: notifications
        )
        audio.installWorkspaceSleepWakeObservers()
        audio.isRecording = true
        return (audio, center, notifications)
    }

    func testMicRecoveryIsDeferredWhileTheMacIsGoingToSleep() {
        // Hardware log 2026-09-23: the watchdog saw the mic go quiet during
        // sleep entry, rebuilt the graph, got no frame, and stopped the
        // whole meeting. That attempt must wait for wake instead.
        let (audio, center, notifications) = makeSleepingAudio("Deferred")
        center.post(name: notifications.willSleepName, object: nil)
        let delivered = expectation(description: "will-sleep observer ran on main")
        DispatchQueue.main.async { delivered.fulfill() }
        wait(for: [delivered], timeout: 1.0)
        XCTAssertTrue(audio.isSystemSleepPending(for: audio.recordingSessionGeneration))

        audio.recoverFromDeviceChange(sessionGeneration: audio.recordingSessionGeneration)

        XCTAssertNil(audio.lastRecoveryTime, "no recovery attempt may start while sleep is pending")
        XCTAssertEqual(audio.recoveryAttemptCount, 0, "a deferred attempt must not count toward giving up")
        XCTAssertEqual(audio.deviceSwitchCount, 0)
    }

    func testMicRecoveryStillRunsWithoutPendingSleep() {
        // Control for the test above: without a sleep mark the same call
        // reaches the attempt (and stops only at the missing test engine).
        let (audio, _, _) = makeSleepingAudio("Control")

        audio.recoverFromDeviceChange(sessionGeneration: audio.recordingSessionGeneration)

        XCTAssertNotNil(audio.lastRecoveryTime)
    }

    func testStaleSleepMarkFromAnotherSessionDoesNotHoldRecovery() {
        let (audio, _, _) = makeSleepingAudio("Stale")
        audio.markSystemSleepPending(for: audio.recordingSessionGeneration &+ 1)

        audio.recoverFromDeviceChange(sessionGeneration: audio.recordingSessionGeneration)

        XCTAssertNotNil(audio.lastRecoveryTime, "only the session that was asleep may be held")
    }

    func testWakeClearsTheSleepMarkAndRunsTheMicRecovery() {
        let (audio, center, notifications) = makeSleepingAudio("Wake")
        center.post(name: notifications.willSleepName, object: nil)
        center.post(name: notifications.didWakeName, object: nil)

        let recovered = expectation(description: "wake ran the deferred mic recovery")
        let deadline = Date().addingTimeInterval(3.0)
        DispatchQueue.global(qos: .utility).async {
            while Date() < deadline {
                if audio.lastRecoveryTime != nil {
                    recovered.fulfill()
                    return
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        wait(for: [recovered], timeout: 3.5)
        XCTAssertFalse(audio.isSystemSleepPending(for: audio.recordingSessionGeneration))
    }

    private func makeSleepingAudioWithCapture(
        _ name: String
    ) -> (Audio, RecoveryEventStubSystemAudioCapture, NotificationCenter, AudioSleepWakeNotifications) {
        let capture = RecoveryEventStubSystemAudioCapture()
        let center = NotificationCenter()
        let notifications = AudioSleepWakeNotifications(
            center: center,
            willSleepName: Notification.Name("SystemAudioRecoveryParityTests.\(name).WillSleep"),
            didWakeName: Notification.Name("SystemAudioRecoveryParityTests.\(name).DidWake")
        )
        let audio = Audio(
            paths: makePaths(),
            systemAudioCaptureForTesting: capture,
            sleepWakeNotifications: notifications
        )
        audio.installWorkspaceSleepWakeObservers()
        audio.isRecording = true
        return (audio, capture, center, notifications)
    }

    func testWakeLeavesAMicThatIsStillDeliveringAlone() {
        // Hardware 2026-09-23: after wake the meeting mic was rebuilt even
        // though the pinned Mac mic kept delivering. Each rebuild's fresh
        // engine bound to the default input first, the AirPods, which
        // flipped them into call mode and garbled playback.
        let (audio, capture, center, notifications) = makeSleepingAudioWithCapture("Flowing")
        let stopFeeding = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            while stopFeeding.wait(timeout: .now() + 0.02) == .timedOut {
                audio.micBufferCount += 1
            }
        }
        defer { stopFeeding.signal() }
        center.post(name: notifications.willSleepName, object: nil)
        center.post(name: notifications.didWakeName, object: nil)

        let systemRecovered = expectation(description: "system audio still gets its wake reconnect")
        capture.observeWakeRecovery { systemRecovered.fulfill() }
        wait(for: [systemRecovered], timeout: 3.5)

        XCTAssertNil(audio.lastRecoveryTime, "a mic that is still delivering must not be rebuilt after wake")
        XCTAssertEqual(audio.recoveryAttemptCount, 0)
        XCTAssertFalse(audio.isSystemSleepPending(for: audio.recordingSessionGeneration))
    }

    func testSecondSleepBeforeTheWakeRecoveryKeepsItsHold() {
        // Deep review S5/M2: lid opened and closed again within ~1.5 s. The
        // first wake's delayed recovery must not reattach system audio right
        // before the Mac sleeps, nor clear the second sleep's mic hold.
        let (audio, capture, center, notifications) = makeSleepingAudioWithCapture("Resleep")
        center.post(name: notifications.willSleepName, object: nil)
        center.post(name: notifications.didWakeName, object: nil)
        center.post(name: notifications.willSleepName, object: nil)

        let settled = expectation(description: "the first wake's delayed work had its chance to run")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.3) { settled.fulfill() }
        wait(for: [settled], timeout: 3.0)

        XCTAssertEqual(capture.recoverAfterSystemWakeCallCount, 0)
        XCTAssertNil(audio.lastRecoveryTime)
        XCTAssertTrue(audio.isSystemSleepPending(for: audio.recordingSessionGeneration),
                      "the second sleep still holds mic recovery until its own wake")
    }

    func testSleepHoldEndsAfterAwakeTimeWithoutAWake() {
        // Deep review M1: a will-sleep whose wake never arrives must not
        // switch mic recovery off for the rest of the meeting.
        let (audio, _, _) = makeSleepingAudio("HoldLimit")
        let generation = audio.recordingSessionGeneration
        audio.markSystemSleepPending(for: generation)
        XCTAssertTrue(audio.isSystemSleepPending(for: generation))
        XCTAssertFalse(audio.isSystemSleepPending(
            for: generation,
            now: CACurrentMediaTime() + Audio.systemSleepHoldAwakeLimit + 1
        ))
        XCTAssertFalse(audio.isSystemSleepPending(for: generation), "an expired hold is cleared")
    }

    func testPostWakeProactiveRecoverySkippedWhenNotRecording() {
        let capture = RecoveryEventStubSystemAudioCapture()
        let center = NotificationCenter()
        let notifications = AudioSleepWakeNotifications(
            center: center,
            willSleepName: Notification.Name("SystemAudioRecoveryParityTests.NotRecording.WillSleep"),
            didWakeName: Notification.Name("SystemAudioRecoveryParityTests.NotRecording.DidWake")
        )
        let audio = Audio(
            paths: makePaths(),
            systemAudioCaptureForTesting: capture,
            sleepWakeNotifications: notifications
        )
        audio.installWorkspaceSleepWakeObservers()
        // isRecording defaults to false.

        center.post(name: notifications.willSleepName, object: nil)
        center.post(name: notifications.didWakeName, object: nil)

        let settled = expectation(description: "wake handling settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { settled.fulfill() }
        wait(for: [settled], timeout: 2.5)

        XCTAssertEqual(capture.recoverAfterSystemWakeCallCount, 0,
                       "a wake outside an active recording must not touch the system-audio backend")
    }

    func testWakeRecoveryCannotFollowANewRecordingDuringInitialSettleDelay() {
        assertWakeRecoveryStaysWithOriginalRecording(replaceAfter: 0)
    }

    func testWakeRecoveryCannotFollowANewRecordingDuringBackendSettleDelay() {
        assertWakeRecoveryStaysWithOriginalRecording(replaceAfter: 0.75)
    }

    /// Exercise the production notification observer with two fake sessions,
    /// without opening a microphone or changing the real machine's sleep state.
    /// Both settle windows must remain owned by the meeting that actually woke.
    private func assertWakeRecoveryStaysWithOriginalRecording(replaceAfter delay: TimeInterval) {
        let originalCapture = RecoveryEventStubSystemAudioCapture()
        let replacementCapture = RecoveryEventStubSystemAudioCapture()
        let controlCapture = RecoveryEventStubSystemAudioCapture()
        let forbiddenRecovery = expectation(description: "replaced meeting must not receive wake recovery")
        forbiddenRecovery.isInverted = true
        originalCapture.observeWakeRecovery { forbiddenRecovery.fulfill() }
        replacementCapture.observeWakeRecovery { forbiddenRecovery.fulfill() }
        let controlRecovered = expectation(description: "same-session control receives wake recovery")
        controlCapture.observeWakeRecovery { controlRecovered.fulfill() }
        let center = NotificationCenter()
        let notifications = AudioSleepWakeNotifications(
            center: center,
            willSleepName: Notification.Name("SystemAudioRecoveryParityTests.Replaced.WillSleep"),
            didWakeName: Notification.Name("SystemAudioRecoveryParityTests.Replaced.DidWake")
        )
        let audio = Audio(
            paths: makePaths(),
            systemAudioCaptureForTesting: originalCapture,
            sleepWakeNotifications: notifications
        )
        audio.installWorkspaceSleepWakeObservers()
        audio.recordingSessionGeneration = 10
        audio.isRecording = true

        // A positive control traverses the same scheduling path concurrently.
        // If the delayed queues never run, this test must fail rather than
        // report success solely because the forbidden callbacks stayed quiet.
        let controlAudio = Audio(
            paths: makePaths(),
            systemAudioCaptureForTesting: controlCapture,
            sleepWakeNotifications: notifications
        )
        controlAudio.installWorkspaceSleepWakeObservers()
        controlAudio.recordingSessionGeneration = 20
        controlAudio.isRecording = true
        center.post(name: notifications.willSleepName, object: nil)
        center.post(name: notifications.didWakeName, object: nil)

        let replacementSleepTimestamp = Date(timeIntervalSince1970: 1_000)
        let replaceRecording = {
            if delay > 0 {
                XCTAssertNil(audio.sleepTimestamp,
                             "the first wake block must run before the backend-window replacement")
                XCTAssertEqual(audio.recordingGaps.count, 1,
                               "the first wake block must have recorded the original meeting's sleep gap")
                XCTAssertEqual(originalCapture.recoverAfterSystemWakeCallCount, 0,
                               "replacement must precede the backend recovery callback")
            }
            // Mirrors the generation and health reset at stop/new-start. No
            // actual graph is needed to expose the stale observer callback.
            audio.recordingSessionGeneration = 12
            audio.systemAudioCapture = replacementCapture
            audio.recordingGaps = []
            audio.sleepTimestamp = replacementSleepTimestamp
        }
        if delay == 0 {
            replaceRecording()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: replaceRecording)
        }

        wait(for: [controlRecovered, forbiddenRecovery], timeout: 3.5)

        XCTAssertEqual(controlCapture.recoverAfterSystemWakeCallCount, 1)
        XCTAssertEqual(controlAudio.recordingGaps.count, 1)
        XCTAssertEqual(originalCapture.recoverAfterSystemWakeCallCount, 0)
        XCTAssertEqual(replacementCapture.recoverAfterSystemWakeCallCount, 0,
                       "an old wake must never restart a newer meeting's healthy system stream")
        XCTAssertTrue(audio.recordingGaps.isEmpty,
                      "an old wake must not attach its gap to a newer meeting")
        XCTAssertEqual(audio.sleepTimestamp, replacementSleepTimestamp,
                       "an old wake must not consume a newer meeting's sleep marker")
    }

    // MARK: - deviceSwitchCount lost-update race (review fix)
    //
    // The mic path increments `deviceSwitchCount` from its background
    // recovery queue; the SCK-path subscription increments it from
    // `DispatchQueue.main` via `recordSystemAudioDeviceSwitch()`. The old
    // `deviceSwitchCount` getter/setter pair does a get and a set as two
    // SEPARATE lock acquisitions, so `deviceSwitchCount += 1` from two
    // genuinely concurrent callers can interleave and drop an increment.
    // `incrementDeviceSwitchCount()` must do the read-modify-write inside
    // ONE lock acquisition so every concurrent increment survives.

    func testIncrementDeviceSwitchCountSurvivesHighConcurrencyWithoutLostUpdates() {
        let audio = Audio(paths: makePaths())
        let iterationsPerQueue = 500
        let queues = (0..<8).map { DispatchQueue(label: "IncrementRace.\($0)") }
        let group = DispatchGroup()

        for queue in queues {
            group.enter()
            queue.async {
                for _ in 0..<iterationsPerQueue {
                    audio.incrementDeviceSwitchCount()
                }
                group.leave()
            }
        }

        let finished = expectation(description: "all concurrent increments completed")
        group.notify(queue: .main) { finished.fulfill() }
        wait(for: [finished], timeout: 10.0)

        XCTAssertEqual(
            audio.deviceSwitchCount,
            queues.count * iterationsPerQueue,
            "every increment across all concurrent callers must land — none may be lost to the get/set race"
        )
    }

    func testConcurrentMicAndSystemAudioDeviceSwitchesBothLand() {
        // Mirrors the real shape of the race: mic-path recovery increments
        // on a background queue while the SCK recoveryEventPublisher
        // subscription increments on main, concurrently, for the same
        // in-flight recording.
        let audio = Audio(paths: makePaths())
        audio.isRecording = true
        let iterations = 200
        let group = DispatchGroup()
        let backgroundQueue = DispatchQueue(label: "MicPathDeviceSwitchRace", attributes: .concurrent)

        group.enter()
        backgroundQueue.async {
            for _ in 0..<iterations {
                audio.incrementDeviceSwitchCount()
            }
            group.leave()
        }
        group.enter()
        DispatchQueue.main.async {
            for _ in 0..<iterations {
                audio.recordSystemAudioDeviceSwitch()
            }
            group.leave()
        }

        let finished = expectation(description: "mic-path and system-audio increments both completed")
        group.notify(queue: .main) { finished.fulfill() }
        wait(for: [finished], timeout: 10.0)

        XCTAssertEqual(audio.deviceSwitchCount, iterations * 2,
                       "mic-path and system-audio device switches must both be reflected with no lost updates")
    }

    // MARK: - Helpers

    /// Enqueues onto the main queue and waits for it to run, so any
    /// `.receive(on: DispatchQueue.main)` work already scheduled ahead of it
    /// (e.g. `Audio`'s recovery-event subscription) has completed first.
    private func waitForMainQueueToSettle() {
        let settled = expectation(description: "main queue settled")
        DispatchQueue.main.async { settled.fulfill() }
        wait(for: [settled], timeout: 1.0)
    }
}

@available(macOS 14.0, *)
private final class RecoveryEventStubSystemAudioCapture: SystemAudioCaptureEngine, @unchecked Sendable {
    private let errorSubject = PassthroughSubject<String?, Never>()
    private let recoverySubject = PassthroughSubject<SystemAudioRecoveryEvent, Never>()
    private let lock = NSLock()
    private var _recoverAfterSystemWakeCallCount = 0
    private var wakeRecoveryObserver: (@Sendable () -> Void)?

    var diagnosticBackendName: String { "recovery_event_stub" }
    var audioFormat: AVAudioFormat?
    var bufferSuccessRate: Double { 1.0 }
    var deliversOwnedAudioBuffers: Bool { true }
    var errorMessagePublisher: AnyPublisher<String?, Never> { errorSubject.eraseToAnyPublisher() }
    var recoveryEventPublisher: AnyPublisher<SystemAudioRecoveryEvent, Never> { recoverySubject.eraseToAnyPublisher() }

    var recoverAfterSystemWakeCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _recoverAfterSystemWakeCallCount
    }

    func prepare() throws {}
    func start(bufferCallback: @escaping (AVAudioPCMBuffer) -> Void) throws {}
    func stop() {}
    func stopSync() {}

    func recoverAfterSystemWake() {
        lock.lock()
        _recoverAfterSystemWakeCallCount += 1
        let observer = wakeRecoveryObserver
        lock.unlock()
        observer?()
    }

    func observeWakeRecovery(_ observer: @escaping @Sendable () -> Void) {
        lock.lock()
        wakeRecoveryObserver = observer
        lock.unlock()
    }

    func emit(recoveryEvent: SystemAudioRecoveryEvent) {
        recoverySubject.send(recoveryEvent)
    }

    func emit(errorMessage: String?) {
        errorSubject.send(errorMessage)
    }
}
