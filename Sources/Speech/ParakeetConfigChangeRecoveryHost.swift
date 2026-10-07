// ParakeetConfigChangeRecoveryHost.swift
// ParakeetEngine's conformance to ParakeetConfigChangeRecoveryHost, split out
// of ParakeetDeviceRecovery.swift to keep that file under the size limit.

@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import TranscriptedCore

extension ParakeetEngine: ParakeetConfigChangeRecoveryHost {
    func beginConfigChangeRecovery() -> UInt64 {
        // Track whether any config change in the current burst interrupted a
        // recording. Once set, later changes in the same burst inherit it.
        if isRecording {
            configChangeWasRecording = true
        }
        // Bump the recovery generation and signal UI that the engine is
        // recovering. DictationSessionController waits on these flags.
        cancelConfigRecoveryTimeout()
        let recoveryGeneration = recoveryState.beginConfigChange()
        publishRecoveryState()
        scheduleConfigRecoveryTimeout(
            generation: recoveryGeneration,
            wasRecording: configChangeWasRecording
        )
        // Fresh device state warrants a fresh retry budget for prewarm.
        prewarmRetryCount = 0
        return recoveryGeneration
    }

    func cancelPrewarmRetry() {
        prewarmRetryTask?.cancel()
        prewarmRetryTask = nil
    }

    func markRecordingStoppedForRecovery() {
        isRecording = false
        audioLevel = 0
    }

    func reportGraphReusedAfterConfigChange() {
        AppLogger.transcription.info("PARAKEET | stable configuration change → reusing current audio graph")
    }
}
