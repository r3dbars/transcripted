import AVFoundation
import Combine
import CoreMedia
import QuartzCore
import ScreenCaptureKit

@available(macOS 26.0, *)
extension SCKAudioCapture {
    func clearStreamStateLocked(
        expectedIdentity: ObjectIdentifier,
        expectedGeneration: UInt64
    ) -> Bool {
        guard streamGeneration == expectedGeneration,
              stream?.captureIdentity == expectedIdentity else {
            return false
        }
        testHooks.afterCleanupValidationWhileLocked?()
        _isCapturing = false
        isWaitingForTimedOutStopCallback = false
        stream = nil
        streamOutput = nil
        bufferCallback = nil
        _audioFormat = nil
        streamGeneration = nil
        streamPhase = .idle
        return true
    }

    func finishCleanupSideEffects() {
        AppLogger.audioSystem.info("SCKAudioCapture: cleanup")
        logStats()
        stopWatchdog()
        resetStats()
        resetBufferWatchdogState()
    }

    func cleanupIfCurrent(
        generation: UInt64,
        stream expectedStream: any SCKStreamControlling
    ) {
        captureStateLock.lock()
        let didCleanup = clearStreamStateLocked(
            expectedIdentity: expectedStream.captureIdentity,
            expectedGeneration: generation
        )
        captureStateLock.unlock()

        guard didCleanup else {
            AppLogger.audioSystem.info("SCKAudioCapture: skipping stale cleanup")
            return
        }
        finishCleanupSideEffects()
    }

    private func cleanupStreamReference(
        _ expectedStream: any SCKStreamControlling,
        generation: UInt64
    ) {
        cleanupIfCurrent(generation: generation, stream: expectedStream)
    }

    func cleanupPreparedStreamReferenceIfCurrent(
        _ expectedStream: any SCKStreamControlling,
        generation: UInt64
    ) {
        captureStateLock.lock()
        let didCleanup: Bool
        if streamPhase == .prepared {
            didCleanup = clearStreamStateLocked(
                expectedIdentity: expectedStream.captureIdentity,
                expectedGeneration: generation
            )
        } else {
            didCleanup = false
        }
        captureStateLock.unlock()

        if didCleanup {
            finishCleanupSideEffects()
        }
    }

    func stopStreamAndCleanupAfterFailedStartIfOwned(
        _ expectedStream: any SCKStreamControlling,
        generation: UInt64
    ) {
        var shouldRequestStop = false
        var didCleanupPreparedStream = false
        captureStateLock.lock()
        if streamGeneration == generation,
           stream?.captureIdentity == expectedStream.captureIdentity {
            switch streamPhase {
            case .starting, .capturing:
                _generationEpoch.invalidate()
                _isCapturing = false
                streamPhase = .stopping
                shouldRequestStop = true
            case .prepared, .idle:
                didCleanupPreparedStream = clearStreamStateLocked(
                    expectedIdentity: expectedStream.captureIdentity,
                    expectedGeneration: generation
                )
            case .stopping, .stopTimedOut:
                break
            }
        }
        captureStateLock.unlock()

        if didCleanupPreparedStream {
            finishCleanupSideEffects()
        }
        guard shouldRequestStop else { return }
        if stopStreamSynchronously(expectedStream, cleanupAfterLateCallback: { [weak self, expectedStream] in
            self?.cleanupStreamReference(expectedStream, generation: generation)
        }) {
            cleanupStreamReference(expectedStream, generation: generation)
        } else {
            retainStreamReferenceAfterTimedOutStop(expectedStream, generation: generation)
        }
    }

    func retainStreamReferenceAfterTimedOutStop(
        _ expectedStream: any SCKStreamControlling,
        generation: UInt64
    ) {
        captureStateLock.lock()
        guard streamGeneration == generation,
              stream?.captureIdentity == expectedStream.captureIdentity else {
            captureStateLock.unlock()
            AppLogger.audioSystem.info("SCKAudioCapture: skipping timed-out stop retention for replaced stream")
            return
        }
        _isCapturing = false
        isWaitingForTimedOutStopCallback = true
        streamPhase = .stopTimedOut
        captureStateLock.unlock()
        stopWatchdog()
        AppLogger.audioSystem.warning("SCKAudioCapture: keeping stream reference after stop timeout")
    }

    func finishRecovery(_ token: SCKRecoveryEpochState.Token) {
        captureStateLock.lock()
        if recoveryEpochState.finish(token) {
            isRecovering = false
        }
        captureStateLock.unlock()
    }

    /// Restores the recovery-attempt budget after a confirmed successful
    /// recovery, mirroring `Audio.finalizeMicRecoveryArtifacts` resetting
    /// `recoveryAttemptCount = 0` on the mic path. Without this, `attempts`
    /// only resets on a brand-new (non-recovery) `start()` — a proactive
    /// post-wake kick that succeeds would otherwise permanently spend this
    /// capture's one-attempt budget for the rest of the recording even
    /// though nothing was actually broken.
    func resetRecoveryAttemptsAfterSuccess() {
        captureStateLock.lock()
        recoveryAttempts = 0
        captureStateLock.unlock()
    }

    @discardableResult
    func stopStreamSynchronously(
        _ stream: any SCKStreamControlling,
        cleanupAfterLateCallback: (() -> Void)? = nil
    ) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        let callbackState = SCKStopCallbackState()
        stream.stopCapture { error in
            if let error = error {
                AppLogger.audioSystem.warning("SCKAudioCapture: stop error", ["error": error.localizedDescription])
            }
            let shouldCleanupLate = callbackState.complete()
            semaphore.signal()
            if shouldCleanupLate {
                AppLogger.audioSystem.info("SCKAudioCapture: running late stop callback cleanup")
                cleanupAfterLateCallback?()
            }
        }
        do {
            try Self.waitForCallback(
                semaphore,
                operation: "stop capture",
                timeout: callbackTimeout,
                timeoutSeconds: callbackTimeoutSeconds
            )
            return true
        } catch {
            guard callbackState.markTimedOutUnlessComplete() else {
                return true
            }
            AppLogger.audioSystem.warning("SCKAudioCapture: stop timed out", ["error": error.localizedDescription])
            return false
        }
    }

    static func waitForCallback(
        _ semaphore: DispatchSemaphore,
        operation: String,
        timeout: DispatchTimeInterval,
        timeoutSeconds: Int,
        shouldAbort: (() -> Bool)? = nil
    ) throws {
        let deadline = DispatchTime.now() + timeout
        while true {
            if shouldAbort?() == true {
                throw SCKRecoveryCancelledError()
            }
            let slice: DispatchTime = shouldAbort == nil
                ? deadline
                : .now() + .milliseconds(250)
            if semaphore.wait(timeout: slice) == .success {
                return
            }
            if DispatchTime.now() >= deadline {
                let error = SCKCaptureTimeoutError(operation: operation)
                AppLogger.audioSystem.error("SCKAudioCapture: callback timed out", [
                    "operation": operation,
                    "timeoutSeconds": "\(timeoutSeconds)"
                ])
                throw error
            }
        }
    }
}
