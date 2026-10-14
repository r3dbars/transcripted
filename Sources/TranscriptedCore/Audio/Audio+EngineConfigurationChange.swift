// Audio+EngineConfigurationChange.swift
// AVAudioEngineConfigurationChange handling for the published meeting mic
// graph: snapshot on the notification thread, decide off main after a settle.

import Foundation
@preconcurrency import AVFoundation
import CoreAudio
import QuartzCore

// MARK: - Engine Configuration Change

extension Audio {

    func installMicEngineConfigurationChangeObserver() {
        guard micEngineConfigurationObserver == nil else { return }
        // object: nil because every recovery publishes a fresh engine. The
        // check below only acts on the live meeting graph, so dictation's own
        // engine and detached graphs that are still being built are ignored.
        micEngineConfigurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let changedEngine = notification.object as? AVAudioEngine else { return }
            self?.handleMicEngineConfigurationChange(changedEngine)
        }
    }

    /// Posted off the graph-lock thread; snapshot lock-free state and check after a settle.
    func handleMicEngineConfigurationChange(_ changedEngine: AVAudioEngine) {
        scheduleMicEngineConfigurationCheck(
            changedEngineID: ObjectIdentifier(changedEngine),
            sessionGeneration: recordingSessionGeneration,
            bufferCountAtChange: micBufferCount,
            delay: MicEngineConfigurationChangePolicy.settleSeconds,
            remainingRecoveryWaits: MicEngineConfigurationChangePolicy.maxRecoveryWaits
        )
    }

    private func scheduleMicEngineConfigurationCheck(
        changedEngineID: ObjectIdentifier,
        sessionGeneration: UInt64,
        bufferCountAtChange: Int,
        delay: TimeInterval,
        remainingRecoveryWaits: Int
    ) {
        // `isRecording` belongs to main; read it there, then decide off main.
        // ObjectIdentifier, not `[weak changedEngine]` (APPLE-MACOS-4J / 3C).
        DispatchQueue.main.asyncAfter(
            deadline: .now() + delay
        ) { [weak self] in
            guard let self else { return }
            let isRecording = self.isRecording
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                self.checkMicEngineConfigurationChange(
                    changedEngineID: changedEngineID,
                    sessionGeneration: sessionGeneration,
                    isRecording: isRecording,
                    bufferCountAtChange: bufferCountAtChange,
                    remainingRecoveryWaits: remainingRecoveryWaits
                )
            }
        }
    }

    /// Internal `@testable` seam only. An unpublished or replaced engine
    /// returns nil, except while a recovery is still building its graph:
    /// that engine may be published next, so keep the 6×0.5s
    /// `waitForRecovery` retry for it. The watchdog covers a still-stopped mic.
    @discardableResult
    func checkMicEngineConfigurationChange(
        changedEngineID: ObjectIdentifier,
        sessionGeneration: UInt64,
        isRecording: Bool,
        bufferCountAtChange: Int,
        remainingRecoveryWaits: Int,
        applyRecovery: Bool = true
    ) -> MicEngineConfigurationChangePolicy.Decision? {
        let (matchesPublished, changedEngineIsRunning) = withAudioGraphLock {
            guard let published = engine, ObjectIdentifier(published) == changedEngineID
            else { return (false, false) }
            return (true, published.isRunning)
        }
        guard matchesPublished else {
            // A route change on the graph a recovery is still building fires
            // before that engine is published; re-check once it lands.
            guard isMicRecovering,
                  sessionGeneration == recordingSessionGeneration,
                  remainingRecoveryWaits > 0
            else { return nil }
            scheduleMicEngineConfigurationCheck(
                changedEngineID: changedEngineID,
                sessionGeneration: sessionGeneration,
                bufferCountAtChange: bufferCountAtChange,
                delay: MicEngineConfigurationChangePolicy.recoveryWaitSeconds,
                remainingRecoveryWaits: remainingRecoveryWaits - 1
            )
            return .waitForRecovery
        }
        let decision = MicEngineConfigurationChangePolicy.decision(
            sessionIsCurrent: sessionGeneration == recordingSessionGeneration,
            isRecording: isRecording,
            isSystemSleeping: isSystemSleepPending(for: sessionGeneration),
            isRecovering: isMicRecovering,
            changedEngineIsRunning: changedEngineIsRunning,
            deliveredNewBuffer: MicRecoveryReadinessPolicy.deliveredNewBuffer(
                before: bufferCountAtChange,
                after: micBufferCount
            ),
            secondsSinceLastRecoveryEnded: lastRecoveryEndTime.map {
                Date().timeIntervalSince($0)
            },
            recoveryAttemptsUsed: recoveryAttemptCount,
            maxRecoveryAttempts: maxRecoveryAttempts
        )

        switch decision {
        case .ignore:
            break
        case .stillFlowing:
            AppLogger.audioMic.info("Microphone kept delivering audio through an audio route change")
        case .waitForRecovery:
            guard remainingRecoveryWaits > 0 else { break }
            scheduleMicEngineConfigurationCheck(
                changedEngineID: changedEngineID,
                sessionGeneration: sessionGeneration,
                bufferCountAtChange: bufferCountAtChange,
                delay: MicEngineConfigurationChangePolicy.recoveryWaitSeconds,
                remainingRecoveryWaits: remainingRecoveryWaits - 1
            )
        case .leaveToWatchdog:
            AppLogger.audioMic.info("Audio route changed right after a mic recovery; leaving it to the watchdog")
        case .engineStillRunning:
            AppLogger.audioMic.info("Audio route changed but the mic engine is still running; leaving it to the watchdog")
        case .recover:
            AppLogger.audioMic.warning("Audio route change stopped the microphone; recovering now")
            if applyRecovery { recoverFromDeviceChange(sessionGeneration: sessionGeneration) }
        }
        return decision
    }
}
