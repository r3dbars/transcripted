import XCTest
@preconcurrency import AVFoundation
import Combine
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
        lock.unlock()
    }

    func emit(recoveryEvent: SystemAudioRecoveryEvent) {
        recoverySubject.send(recoveryEvent)
    }

    func emit(errorMessage: String?) {
        errorSubject.send(errorMessage)
    }
}
