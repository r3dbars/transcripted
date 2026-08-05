import AVFoundation
import Combine
import Foundation
import ScreenCaptureKit
import XCTest
@testable import TranscriptedCore

@available(macOS 26.0, *)
private struct ControlledSCKTestError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

@available(macOS 26.0, *)
private final class ControlledSCKStream: SCKStreamControlling, @unchecked Sendable {
    let startInvocationEntered = DispatchSemaphore(value: 0)
    let allowStartInvocationToReturn = DispatchSemaphore(value: 0)

    var blocksStartInvocation = false
    var autoCompletesStart = true
    var autoCompletesStop = true
    var completesPendingStartWhenStopped = false

    var captureIdentity: ObjectIdentifier { ObjectIdentifier(self) }

    private let lock = NSLock()
    private var startCompletion: (@Sendable (Error?) -> Void)?
    private var stopCompletion: (@Sendable (Error?) -> Void)?
    private var _startCallCount = 0
    private var _stopCallCount = 0

    var startCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _startCallCount
    }

    var stopCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _stopCallCount
    }

    func addStreamOutput(
        _ output: any SCStreamOutput,
        type: SCStreamOutputType,
        sampleHandlerQueue: DispatchQueue?
    ) throws {}

    func startCapture(completionHandler: (@Sendable (Error?) -> Void)?) {
        lock.lock()
        _startCallCount += 1
        startCompletion = completionHandler
        let shouldBlock = blocksStartInvocation
        let shouldComplete = autoCompletesStart
        lock.unlock()

        startInvocationEntered.signal()
        if shouldBlock {
            _ = allowStartInvocationToReturn.wait(timeout: .now() + 2)
        }
        if shouldComplete {
            completeStart()
        }
    }

    func stopCapture(completionHandler: (@Sendable (Error?) -> Void)?) {
        lock.lock()
        _stopCallCount += 1
        stopCompletion = completionHandler
        let shouldCancelStart = completesPendingStartWhenStopped
        let shouldComplete = autoCompletesStop
        lock.unlock()

        if shouldCancelStart {
            completeStart(error: ControlledSCKTestError(message: "start cancelled by stop"))
        }
        if shouldComplete {
            completeStop()
        }
    }

    func completeStart(error: Error? = nil) {
        lock.lock()
        let completion = startCompletion
        startCompletion = nil
        lock.unlock()
        completion?(error)
    }

    func completeStop(error: Error? = nil) {
        lock.lock()
        let completion = stopCompletion
        stopCompletion = nil
        lock.unlock()
        completion?(error)
    }
}

@available(macOS 26.0, *)
final class SCKAudioCaptureInterleavingTests: XCTestCase {
    func testOverlappingStartCannotDiscardFirstInFlightStream() {
        let stream = ControlledSCKStream()
        stream.blocksStartInvocation = true
        stream.autoCompletesStart = false

        let capture = SCKAudioCapture(
            callbackTimeout: .milliseconds(250),
            callbackTimeoutSeconds: 1
        )
        capture.installPreparedStreamForTesting(stream)

        let firstStartFinished = expectation(description: "first start completes")
        DispatchQueue.global(qos: .userInitiated).async {
            _ = try? capture.start(bufferCallback: { _ in })
            firstStartFinished.fulfill()
        }
        XCTAssertEqual(stream.startInvocationEntered.wait(timeout: .now() + 1), .success)

        let secondStartFinished = expectation(description: "overlapping start is rejected")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try capture.start(bufferCallback: { _ in })
                XCTFail("overlapping start should be rejected")
            } catch {}
            secondStartFinished.fulfill()
        }

        Thread.sleep(forTimeInterval: 0.02)
        stream.allowStartInvocationToReturn.signal()
        wait(for: [secondStartFinished], timeout: 1)

        var state = capture.stateSnapshotForTesting()
        XCTAssertEqual(state.streamIdentity, stream.captureIdentity)
        XCTAssertEqual(state.phase, "starting")
        XCTAssertEqual(stream.stopCallCount, 0)

        stream.completeStart()
        wait(for: [firstStartFinished], timeout: 1)
        state = capture.stateSnapshotForTesting()
        XCTAssertEqual(state.streamIdentity, stream.captureIdentity)
        XCTAssertEqual(state.phase, "capturing")
        XCTAssertTrue(state.isCapturing)
        capture.stopSync()
    }

    func testOfficialStopOwnsStreamWhenStartRequestIsInFlight() {
        let stream = ControlledSCKStream()
        stream.blocksStartInvocation = true
        stream.autoCompletesStart = false
        stream.autoCompletesStop = true
        stream.completesPendingStartWhenStopped = true

        let capture = SCKAudioCapture(
            callbackTimeout: .milliseconds(250),
            callbackTimeoutSeconds: 1
        )
        capture.installPreparedStreamForTesting(stream)

        let startFinished = expectation(description: "start exits after official stop")
        DispatchQueue.global(qos: .userInitiated).async {
            _ = try? capture.start(bufferCallback: { _ in })
            startFinished.fulfill()
        }
        XCTAssertEqual(stream.startInvocationEntered.wait(timeout: .now() + 1), .success)

        let stopEntered = DispatchSemaphore(value: 0)
        let stopFinished = expectation(description: "official stop owns requested stream")
        DispatchQueue.global(qos: .userInitiated).async {
            stopEntered.signal()
            capture.stopSync()
            stopFinished.fulfill()
        }
        XCTAssertEqual(stopEntered.wait(timeout: .now() + 1), .success)

        // startCapture is invoked while the ownership lock is held. The stop
        // cannot return early or silently discard the stream in this window.
        Thread.sleep(forTimeInterval: 0.02)
        XCTAssertEqual(stream.stopCallCount, 0)
        stream.allowStartInvocationToReturn.signal()

        wait(for: [startFinished, stopFinished], timeout: 2)
        let state = capture.stateSnapshotForTesting()
        XCTAssertEqual(stream.startCallCount, 1)
        XCTAssertEqual(stream.stopCallCount, 1)
        XCTAssertNil(state.streamIdentity)
        XCTAssertEqual(state.phase, "idle")
        XCTAssertFalse(state.isCapturing)
        XCTAssertFalse(state.isWaitingForTimedOutStopCallback)
    }

    func testTimedOutOfficialStopRetainsOwnershipUntilLateCallback() throws {
        let stream = ControlledSCKStream()
        stream.autoCompletesStart = true
        stream.autoCompletesStop = false

        let capture = SCKAudioCapture(
            callbackTimeout: .milliseconds(25),
            callbackTimeoutSeconds: 1
        )
        capture.installPreparedStreamForTesting(stream)
        try capture.start(bufferCallback: { _ in })

        capture.stopSync()
        var state = capture.stateSnapshotForTesting()
        XCTAssertEqual(state.streamIdentity, stream.captureIdentity)
        XCTAssertEqual(state.phase, "stop_timed_out")
        XCTAssertFalse(state.isCapturing)
        XCTAssertTrue(state.isWaitingForTimedOutStopCallback)
        XCTAssertThrowsError(try capture.start(bufferCallback: { _ in }))
        XCTAssertEqual(stream.startCallCount, 1, "a timed-out stop must block replacement starts")

        stream.completeStop()
        state = capture.stateSnapshotForTesting()
        XCTAssertNil(state.streamIdentity)
        XCTAssertEqual(state.phase, "idle")
        XCTAssertFalse(state.isWaitingForTimedOutStopCallback)
    }

    func testDelayedOldStreamErrorCannotFailHealthyReplacement() throws {
        let oldStream = ControlledSCKStream()
        let replacement = ControlledSCKStream()
        let capture = SCKAudioCapture(
            callbackTimeout: .milliseconds(250),
            callbackTimeoutSeconds: 1
        )

        capture.installPreparedStreamForTesting(oldStream)
        try capture.start(bufferCallback: { _ in })
        capture.stopSync()

        capture.installPreparedStreamForTesting(replacement)
        try capture.start(bufferCallback: { _ in })
        capture.handleStoppedStream(
            identity: oldStream.captureIdentity,
            error: ControlledSCKTestError(message: "late old-stream error")
        )

        let state = capture.stateSnapshotForTesting()
        XCTAssertEqual(state.streamIdentity, replacement.captureIdentity)
        XCTAssertEqual(state.phase, "capturing")
        XCTAssertTrue(state.isCapturing)
        XCTAssertEqual(state.recoveryAttempts, 0)
        XCTAssertEqual(replacement.stopCallCount, 0)
        capture.stopSync()
    }

    func testRecoveryStaysReconnectingUntilReplacementStartSucceeds() {
        let stream = ControlledSCKStream()
        stream.autoCompletesStart = false
        let capture = SCKAudioCapture(
            callbackTimeout: .milliseconds(250),
            callbackTimeoutSeconds: 1
        )
        capture.errorMessage = "System audio reconnecting after capture interruption."
        capture.installPreparedStreamForTesting(stream)

        let startFinished = expectation(description: "replacement start completes")
        DispatchQueue.global(qos: .userInitiated).async {
            _ = try? capture.start(bufferCallback: { _ in })
            startFinished.fulfill()
        }
        XCTAssertEqual(stream.startInvocationEntered.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(
            capture.errorMessage,
            "System audio reconnecting after capture interruption.",
            "healthy must not publish while startCapture is still pending"
        )

        stream.completeStart()
        wait(for: [startFinished], timeout: 1)
        let mainQueueSettled = expectation(description: "main queue applied healthy status")
        DispatchQueue.main.async { mainQueueSettled.fulfill() }
        wait(for: [mainQueueSettled], timeout: 1)
        XCTAssertNil(capture.errorMessage)
        capture.stopSync()
    }

    func testCleanupAndReplacementCommitCannotEraseNewStream() {
        let cleanupValidated = DispatchSemaphore(value: 0)
        let allowCleanupCommit = DispatchSemaphore(value: 0)
        let hooks = SCKAudioCaptureTestHooks(
            afterCleanupValidationWhileLocked: {
                cleanupValidated.signal()
                _ = allowCleanupCommit.wait(timeout: .now() + 2)
            }
        )
        let capture = SCKAudioCapture(
            callbackTimeout: .milliseconds(250),
            callbackTimeoutSeconds: 1,
            testHooks: hooks
        )
        let oldStream = ControlledSCKStream()
        let replacement = ControlledSCKStream()
        let oldGeneration = capture.installPreparedStreamForTesting(oldStream)

        let cleanupFinished = expectation(description: "old cleanup commits")
        DispatchQueue.global(qos: .userInitiated).async {
            capture.cleanupStreamForTesting(oldStream, generation: oldGeneration)
            cleanupFinished.fulfill()
        }
        XCTAssertEqual(cleanupValidated.wait(timeout: .now() + 1), .success)

        let replacementAttempted = DispatchSemaphore(value: 0)
        let replacementFinished = expectation(description: "replacement installs after cleanup lock")
        DispatchQueue.global(qos: .userInitiated).async {
            replacementAttempted.signal()
            capture.replacePreparedStreamForTesting(replacement)
            replacementFinished.fulfill()
        }
        XCTAssertEqual(replacementAttempted.wait(timeout: .now() + 1), .success)
        allowCleanupCommit.signal()

        wait(for: [cleanupFinished, replacementFinished], timeout: 2)
        let state = capture.stateSnapshotForTesting()
        XCTAssertEqual(state.streamIdentity, replacement.captureIdentity)
        XCTAssertEqual(state.phase, "prepared")
        XCTAssertFalse(state.isCapturing)
    }

    // MARK: - Recovery event reporting (mic-path health-seam parity)
    //
    // These tests exercise only the SYNCHRONOUS front half of bounded
    // recovery: obtaining the recovery token and publishing `.deviceSwitch`
    // happens before `handleMidRecordingFailure` dispatches its background
    // recovery closure, which calls the REAL `prepare()` (a live
    // `SCShareableContent` fetch). No existing test in this file lets that
    // background closure run to completion for the same reason — it would
    // depend on live ScreenCaptureKit/TCC state. Each test below cancels
    // recovery (via `stopSync()`) from inside the `.deviceSwitch` handler,
    // synchronously and on the same thread that triggered the failure, so
    // the pending background closure observes a cancelled token and returns
    // before ever touching a real `SCStream`.

    func testMidRecordingFailurePublishesDeviceSwitchBeforeBackgroundRecoveryWork() {
        let stream = ControlledSCKStream()
        let capture = SCKAudioCapture(
            callbackTimeout: .milliseconds(250),
            callbackTimeoutSeconds: 1
        )
        capture.installPreparedStreamForTesting(stream)
        try? capture.start(bufferCallback: { _ in })

        var receivedEvents: [SystemAudioRecoveryEvent] = []
        let eventsLock = NSLock()
        let deviceSwitchSeen = expectation(description: "device switch event published")
        let cancellable = capture.recoveryEventPublisher.sink { event in
            eventsLock.lock()
            receivedEvents.append(event)
            eventsLock.unlock()
            if event == .deviceSwitch {
                // Cancel recovery synchronously, on the same thread that is
                // still inside `handleStoppedStream` below, before its
                // `DispatchQueue.global(...).async` recovery closure can run.
                capture.stopSync()
                deviceSwitchSeen.fulfill()
            }
        }

        capture.handleStoppedStream(
            identity: stream.captureIdentity,
            error: ControlledSCKTestError(message: "stream stopped")
        )

        wait(for: [deviceSwitchSeen], timeout: 1)
        cancellable.cancel()

        eventsLock.lock()
        let events = receivedEvents
        eventsLock.unlock()
        XCTAssertTrue(events.contains(.deviceSwitch),
                      "a mid-recording stream failure must report a device-switch event the same way mic recovery does")
    }

    func testRecoverAfterSystemWakeNoOpsWhenNothingIsCapturing() {
        let capture = SCKAudioCapture(
            callbackTimeout: .milliseconds(250),
            callbackTimeoutSeconds: 1
        )

        var receivedAnyEvent = false
        let cancellable = capture.recoveryEventPublisher.sink { _ in receivedAnyEvent = true }

        capture.recoverAfterSystemWake()
        cancellable.cancel()

        XCTAssertFalse(receivedAnyEvent, "a proactive wake recovery must no-op when nothing is actively capturing")
    }

    func testRecoverAfterSystemWakeGivesActiveCaptureTheSameBoundedRecoveryAsAFailure() {
        let stream = ControlledSCKStream()
        let capture = SCKAudioCapture(
            callbackTimeout: .milliseconds(250),
            callbackTimeoutSeconds: 1
        )
        capture.installPreparedStreamForTesting(stream)
        try? capture.start(bufferCallback: { _ in })

        let deviceSwitchSeen = expectation(description: "wake-triggered recovery reports a device switch")
        let cancellable = capture.recoveryEventPublisher.sink { event in
            if event == .deviceSwitch {
                capture.stopSync()
                deviceSwitchSeen.fulfill()
            }
        }

        capture.recoverAfterSystemWake()

        wait(for: [deviceSwitchSeen], timeout: 1)
        cancellable.cancel()
    }
}
