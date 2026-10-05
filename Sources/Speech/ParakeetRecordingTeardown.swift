// ParakeetRecordingTeardown.swift
// Dictation recording teardown for ParakeetEngine: stop, system-wake
// interruption, cancel, failed-start reset, blocked-start abandonment, and
// idle hardware release. Split out of ParakeetEngine.swift. The stop's order
// lives in `ParakeetStopRecordingSequence` and the graph work in
// `ParakeetAudioGraph`; this file supplies the engine's side of both.
//
// These are internal collaborator methods on ParakeetEngine. ParakeetEngine
// (ParakeetEngine.swift) stays the public-API owner and @MainActor home for
// the state; this file only groups one slice of its implementation.

import Foundation
import TranscriptedCore

extension ParakeetEngine {
    private var zombieRecoveryRestartPending: Bool { zombieRecoveryState.isActive }

    func handleSystemWake() async {
        // Meeting capture owns the live audio graph while dictation borrows
        // its PCM. Wake belongs to the meeting recovery path; do not wake or
        // rebuild the dormant dictation AVAudioEngine — but only while the
        // meeting session that lent the mic is still actually alive. A claim
        // orphaned by a dead session (crash, error teardown ordering) is
        // resolved to `.stale` and treated as absent here, so wake still
        // reclaims and tears down dictation's own graph instead of staying
        // suppressed forever. Mirrors the guard in
        // ParakeetDeviceRecovery.handleAudioConfigChange().
        if ParakeetSystemWakePolicy.decision(sharedMeetingMicRecording: isSharedMeetingMicClaimCurrent) == .skipSharedMeetingMic {
            AppLogger.transcription.info("PARAKEET | system wake detected, dictation borrowing meeting mic, skipping teardown")
            EventReporter.shared.capture(level: .info, engine: "parakeet", event: "system_wake_shared_meeting_mic_skipped",
                message: "System woke from sleep while dictation was borrowing the meeting microphone; meeting capture owns wake recovery")
            return
        }

        // A pinned dictation ends at wake like an engine one, keeping what
        // was heard for the recovery prompt, but without touching the engine:
        // tearing that down here would bind the default input.
        if let pinnedDictationRecording {
            interruptPinnedDictationRecording(pinnedDictationRecording, reason: "system_wake")
            AppLogger.transcription.info("PARAKEET | system wake detected, pinned dictation interrupted")
            return
        }
        if !isRecording, usesPinnedDictationMicrophone() {
            deferPinnedDictationInputReadinessAfterWake()
            return
        }

        AppLogger.transcription.info("PARAKEET | system wake detected, resetting audio engine")
        EventReporter.shared.capture(level: .info, engine: "parakeet", event: "system_wake",
            message: "System woke from sleep, resetting audio engine",
            context: ["was_recording": "\(isRecording)", "was_prewarmed": "\(isEnginePrewarmed)"])

        audioGraphGeneration += 1
        // A wake can interleave with the shared-mic resume transition after
        // finishSharedMeetingMicRecording() clears the flag but before
        // finishResume(token:) commits. Invalidate the transition so the
        // resume path takes its stale-token branch instead of reporting a
        // successful resume on the graph this teardown is about to stop.
        sharedMeetingMicTransition.invalidate()
        let wasRecording = isRecording
        cancelAudioWatchdog()
        audioStartAdmission.cancel()
        guard let teardown = await audioGraph.stopForRecovery(
            isRecording: isRecording,
            preserveRecording: { preserveCurrentRecordingBuffersForRecovery() },
            markRecordingStopped: {
                isRecording = false
                audioLevel = 0
            }
        ) else { return }
        if !teardown.releasedVoiceProcessing {
            discardStoppedVoiceProcessingGraph(ownedBy: teardown.owner)
        }

        if wasRecording {
            interruptRecordingPreservingRecoveredTimeline()
            EventReporter.shared.capture(level: .warning, engine: "parakeet", event: "recording_interrupted",
                message: "Recording interrupted by system sleep/wake")
        }
    }

    func stopRecording() async {
        // A duplicate stop joins the stop already running, so every caller
        // waits for the one tap removal and buffer drain.
        await audioStopLifecycle.run { [weak self] in
            guard let self else { return }
            await ParakeetStopRecordingSequence.run(graph: self.audioGraph, host: self)
        }
    }

    func cancelPendingRecordingRecovery() {
        audioGraphGeneration += 1
        cancelAudioWatchdog()
        audioStartAdmission.cancel()
        prewarmRetryTask?.cancel()
        prewarmRetryTask = nil
        configChangeDebounceTask?.cancel()
        configChangeDebounceTask = nil
        configRecoveryTask?.cancel()
        configRecoveryTask = nil
        cancelConfigRecoveryTimeout()
        configChangeWasRecording = false
        recoveryState.reset()
        publishRecoveryState()
        isRecording = false
        audioLevel = 0
    }

    // MARK: - Cleanup

    func resetAfterFailedRecordingStart() async {
        beginFreshRecordingSession()
        sharedMeetingMicTransition.invalidate()
        sharedMeetingMicRecorder.cancel()
        sharedMeetingMicLevelMeter.end()
        sharedMeetingMicClaim = nil
        discardPinnedDictationRecording()
        cancelAudioWatchdog()
        audioStartAdmission.cancel()
        prewarmRetryTask?.cancel()
        prewarmRetryTask = nil
        configChangeDebounceTask?.cancel()
        configChangeDebounceTask = nil
        configRecoveryTask?.cancel()
        configRecoveryTask = nil
        cancelConfigRecoveryTimeout()
        configChangeWasRecording = false
        recoveryState.reset()
        recoveryState.markFormatUnready()
        publishRecoveryState()
        pendingSamplesLock.withLock {
            pendingSamples.removeAll(keepingCapacity: true)
        }
        audioGraphGeneration += 1
        let failedStartCleanupOwner = currentAudioEngineQueueOwnerToken()
        guard ownsAudioEngineQueue(failedStartCleanupOwner) else { return }
        isRecording = false
        isTranscribing = false
        audioLevel = 0
        didReceiveAudioSamples = false
        didReceiveNonZeroAudioSamples = false
        recordingStartedOnLikelyBluetoothHandsFreeRoute = false
        clearRecoveredRecordingTimeline(keepingCapacity: true)
        _ = await releaseIdleAudioHardware(
            removeTap: true,
            expectedGeneration: failedStartCleanupOwner.graphOwner.generation
        )
    }

    func abandonBlockedRecordingStart(reason: String) {
        beginFreshRecordingSession()
        sharedMeetingMicTransition.invalidate()
        sharedMeetingMicRecorder.cancel()
        sharedMeetingMicLevelMeter.end()
        sharedMeetingMicClaim = nil
        discardPinnedDictationRecording()
        let didReplaceBlockedGraph = cancelAudioWatchdog()
        audioStartAdmission.cancel()
        prewarmRetryTask?.cancel()
        prewarmRetryTask = nil
        configChangeDebounceTask?.cancel()
        configChangeDebounceTask = nil
        configRecoveryTask?.cancel()
        configRecoveryTask = nil
        cancelConfigRecoveryTimeout()
        configChangeWasRecording = false
        recoveryState.reset()
        recoveryState.markFormatUnready()
        publishRecoveryState()
        pendingSamplesLock.withLock {
            pendingSamples.removeAll(keepingCapacity: true)
        }
        isRecording = false
        isTranscribing = false
        audioLevel = 0
        didReceiveAudioSamples = false
        didReceiveNonZeroAudioSamples = false
        recordingStartedOnLikelyBluetoothHandsFreeRoute = false
        clearRecoveredRecordingTimeline(keepingCapacity: true)
        audioGraph.abandonBlockedStart(
            reason: reason,
            replacedByCancellation: didReplaceBlockedGraph
        )
    }

    func cancel() {
        beginFreshRecordingSession()
        sharedMeetingMicTransition.invalidate()
        sharedMeetingMicRecorder.cancel()
        sharedMeetingMicLevelMeter.end()
        sharedMeetingMicClaim = nil
        discardPinnedDictationRecording()
        cancelAudioWatchdog()
        audioStartAdmission.cancel()
        prewarmRetryTask?.cancel()
        prewarmRetryTask = nil
        configChangeDebounceTask?.cancel()
        configChangeDebounceTask = nil
        configRecoveryTask?.cancel()
        configRecoveryTask = nil
        cancelConfigRecoveryTimeout()
        configChangeWasRecording = false
        recoveryState.reset()
        publishRecoveryState()
        pendingSamplesLock.withLock {
            pendingSamples.removeAll(keepingCapacity: true)
        }
        if isRecording {
            isRecording = false
            audioLevel = 0
        }
        audioGraphGeneration += 1
        let cleanupGeneration = audioGraphGeneration
        Task { @MainActor [weak self] in
            await self?.releaseIdleAudioHardware(removeTap: true, expectedGeneration: cleanupGeneration)
        }
        clearRecoveredRecordingTimeline(keepingCapacity: false)
        isTranscribing = false
    }

    @discardableResult
    func releaseIdleAudioHardware(
        removeTap: Bool,
        expectedGeneration: Int? = nil
    ) async -> ParakeetAudioEngineQueueOwnerToken? {
        await audioGraph.releaseIdleHardware(
            removeTap: removeTap,
            expectedGeneration: expectedGeneration
        )
    }
}

extension ParakeetEngine: ParakeetStopRecordingHost {
    var hasSharedMeetingMicClaim: Bool { sharedMeetingMicClaim != nil }
    var isSharedMeetingMicResumeInProgress: Bool { sharedMeetingMicTransition.isResumeInProgress }
    var hasPinnedDictationRecording: Bool { pinnedDictationRecording != nil }
    /// The recorder the current take uses, for stop timing (`pinned_ioproc`
    /// or `engine`). Read it before the stop clears the pinned recording.
    var dictationMicBackendName: String {
        hasPinnedDictationRecording ? PinnedMicrophoneCapture.diagnosticBackendName : "engine"
    }

    var activeConfigRecoveryGeneration: UInt64? {
        recoveryState.isRecovering ? recoveryState.generation : nil
    }

    func invalidateSharedMeetingMicTransition() {
        sharedMeetingMicTransition.invalidate()
    }

    func finishSharedMeetingMicStop() {
        finishSharedMeetingMicRecording(keepRecordingState: false)
        EventReporter.shared.capture(
            level: .info,
            engine: "parakeet",
            event: "dictation_shared_meeting_mic_stopped",
            message: "Dictation stopped borrowing the active meeting microphone stream"
        )
    }

    func idleStopAction() -> ParakeetIdleStopAction {
        ParakeetRecordingContinuityPolicy.idleStopAction(
            preservingAcrossRecovery: preservingRecordingAcrossRecovery,
            hasRecoveredAudio: !recoveredRecordingTimeline.isEmpty,
            zombieRestartPending: zombieRecoveryRestartPending
        )
    }

    func finishStoppedRecording() {
        drainPendingSamplesIntoTimeline()
        isRecording = false
        audioLevel = 0
    }

    func reportRecordingStopped() {
        let stoppedSampleCount = recoveredRecordingTimeline.totalSourceSampleCount
        let stoppedDuration = recoveredRecordingTimeline.totalDurationSeconds
        AppLogger.transcription.info("PARAKEET | recording stopped (\(stoppedSampleCount) samples, \(String(format: "%.1f", stoppedDuration))s)")
    }
}
