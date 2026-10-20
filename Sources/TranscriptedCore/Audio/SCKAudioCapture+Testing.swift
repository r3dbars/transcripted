import AVFoundation
import Combine
import CoreMedia
import QuartzCore
import ScreenCaptureKit

@available(macOS 26.0, *)
extension SCKAudioCapture {
    // Internal deterministic seams for the package's hostile interleaving
    // tests. Production construction still uses real `SCStream` instances.
    @discardableResult
    func installPreparedStreamForTesting(_ preparedStream: any SCKStreamControlling) -> UInt64 {
        let generation = incrementGeneration()
        precondition(
            installPreparedStreamIfCurrent(
                preparedStream,
                audioFormat: nil,
                recoveryToken: nil,
                generation: generation
            )
        )
        return generation
    }

    @discardableResult
    func replacePreparedStreamForTesting(_ preparedStream: any SCKStreamControlling) -> UInt64 {
        captureStateLock.lock()
        let generation = _generationEpoch.begin().rawValue
        stream = preparedStream
        streamOutput = nil
        bufferCallback = nil
        _audioFormat = nil
        streamGeneration = generation
        streamPhase = .prepared
        _isCapturing = false
        isWaitingForTimedOutStopCallback = false
        captureStateLock.unlock()
        return generation
    }

    func cleanupStreamForTesting(
        _ expectedStream: any SCKStreamControlling,
        generation: UInt64
    ) {
        cleanupIfCurrent(generation: generation, stream: expectedStream)
    }

    func stateSnapshotForTesting() -> SCKAudioCaptureStateSnapshot {
        captureStateLock.lock()
        defer { captureStateLock.unlock() }
        return SCKAudioCaptureStateSnapshot(
            streamIdentity: stream?.captureIdentity,
            generation: streamGeneration,
            phase: streamPhase.rawValue,
            isCapturing: _isCapturing,
            isWaitingForTimedOutStopCallback: isWaitingForTimedOutStopCallback,
            recoveryAttempts: recoveryAttempts
        )
    }

    /// Exercises the real production reset path directly (not a
    /// reimplementation), since `handleMidRecordingFailure`'s full success
    /// path cannot be driven from tests without a live ScreenCaptureKit
    /// `prepare()`.
    func resetRecoveryAttemptsAfterSuccessForTesting() {
        resetRecoveryAttemptsAfterSuccess()
    }

    func resetBufferWatchdogStateForTesting() {
        resetBufferWatchdogState()
    }

    func markBufferReceivedForTesting() {
        markBufferReceived()
    }

    func lastKnownBufferTimeForTesting() -> CFTimeInterval {
        lastKnownBufferTime()
    }

    func setLastBufferTimeForTesting(_ time: CFTimeInterval) {
        watchdogLock.lock()
        _lastBufferTime = time
        watchdogLock.unlock()
    }

    func checkWatchdogForTesting(generation: UInt64) {
        checkWatchdog(generation: generation)
    }

    func waitForRestartedBufferForTesting(timeout: TimeInterval) -> Bool {
        waitForRestartedBuffer(timeout: timeout)
    }

    func hasReceivedFirstBufferForTesting() -> Bool {
        watchdogLock.lock()
        defer { watchdogLock.unlock() }
        return _hasReceivedFirstBuffer
    }
}
