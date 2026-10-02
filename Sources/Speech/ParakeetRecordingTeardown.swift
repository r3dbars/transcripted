// ParakeetRecordingTeardown.swift
// Dictation recording teardown for ParakeetEngine: stop, system-wake
// interruption, cancel, failed-start reset, blocked-start abandonment, and
// idle hardware release. Split out of ParakeetEngine.swift.
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
        let wakeCleanupOwner = currentAudioEngineQueueOwnerToken()
        if isRecording {
            preserveCurrentRecordingBuffersForRecovery()
            await removeRecordingTap()
            guard ownsAudioEngineQueue(wakeCleanupOwner) else { return }
            isRecording = false
            audioLevel = 0
        }

        let releasedVoiceProcessing = await stopAudioEngine()
        guard ownsAudioEngineQueue(wakeCleanupOwner) else { return }
        isEnginePrewarmed = false
        if !releasedVoiceProcessing {
            discardStoppedVoiceProcessingGraph(ownedBy: wakeCleanupOwner)
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
            await self.performStopRecording()
        }
    }

    private func performStopRecording() async {
        // Presence-only, same as updateSharedMeetingMicAudioLevel/
        // resumeRegularRecordingAfterSharedMeetingMicEndedIfNeeded above: a
        // claim on file, dead or alive, still means there is no local
        // AVAudioEngine to tear down, so which teardown path runs must stay
        // behavior-identical to the old bare Bool.
        if sharedMeetingMicClaim != nil || sharedMeetingMicTransition.isResumeInProgress {
            sharedMeetingMicTransition.invalidate()
        }
        if sharedMeetingMicClaim != nil {
            finishSharedMeetingMicRecording(keepRecordingState: false)
            EventReporter.shared.capture(
                level: .info,
                engine: "parakeet",
                event: "dictation_shared_meeting_mic_stopped",
                message: "Dictation stopped borrowing the active meeting microphone stream"
            )
            return
        }

        let configRecoveryGeneration = recoveryState.isRecovering
            ? recoveryState.generation
            : nil
        audioGraphGeneration += 1
        cancelAudioWatchdog()
        if let configRecoveryGeneration {
            cancelConfigRecoveryIfCurrent(generation: configRecoveryGeneration)
        }

        let pendingRestoreOwner = pendingSystemInputRestore.owner
        guard isRecording else {
            // Genuinely preserved/recovered audio (e.g. real pre-sleep audio held
            // across a wake-recovery gap) must win over a merely-pending zombie
            // restart, so a stop during an in-flight zombie retry drains real
            // audio instead of discarding it.
            let idleStop = ParakeetRecordingContinuityPolicy.idleStopAction(
                preservingAcrossRecovery: preservingRecordingAcrossRecovery,
                hasRecoveredAudio: !recoveredRecordingTimeline.isEmpty,
                zombieRestartPending: zombieRecoveryRestartPending
            )
            if idleStop == .drainRecoveredAudio {
                cancelPendingRecordingRecovery()
                await restorePendingSystemInputAfterRecording(
                    ownedBy: pendingRestoreOwner,
                    operation: "stop_recording_preserved_recovery"
                )
                return
            }
            // A zombie reset marks recording idle while it waits to retry, with
            // nothing preserved worth keeping. Treat a user stop in that window
            // as cancellation of the pending restart.
            if idleStop == .cancelPendingZombieRestart {
                let stopGraphGeneration = audioGraphGeneration
                audioStartAdmission.cancel()
                clearRecoveredRecordingTimeline(keepingCapacity: true)
                await releaseIdleAudioHardware(
                    removeTap: true,
                    expectedGeneration: stopGraphGeneration
                )
                await restorePendingSystemInputAfterRecording(
                    ownedBy: pendingRestoreOwner,
                    operation: "stop_recording_zombie_restart"
                )
                return
            }
            if audioStartInProgress {
                // A normal start can be blocked inside CoreAudio just like a
                // zombie restart. Claim its exact timed-work lease and replace
                // both resources before allowing the next start to enqueue.
                audioStartAdmission.cancel()
            } else {
                clearRecoveredRecordingTimeline(keepingCapacity: true)
            }
            await restorePendingSystemInputAfterRecording(
                ownedBy: pendingRestoreOwner,
                operation: "stop_recording_idle"
            )
            return
        }
        if pinnedDictationRecording != nil {
            await stopPinnedDictationRecording()
            await restorePendingSystemInputAfterRecording(
                ownedBy: pendingRestoreOwner,
                operation: "stop_recording_pinned"
            )
            return
        }
        let stopOwner = currentAudioEngineQueueOwnerToken()
        await removeRecordingTap()
        var stillOwnsStopGraph = ownsAudioEngineQueue(stopOwner)
        var releasedVoiceProcessing = true
        if stillOwnsStopGraph {
            releasedVoiceProcessing = await stopAudioEngine()
            stillOwnsStopGraph = ownsAudioEngineQueue(stopOwner)
        }
        await restorePendingSystemInputAfterRecording(
            ownedBy: pendingRestoreOwner,
            operation: "stop_recording"
        )
        guard stillOwnsStopGraph, ownsAudioEngineQueue(stopOwner) else { return }
        isEnginePrewarmed = false
        drainPendingSamplesIntoTimeline()
        isRecording = false
        audioLevel = 0
        if !releasedVoiceProcessing {
            discardStoppedVoiceProcessingGraph(ownedBy: stopOwner)
        }
        let stoppedSampleCount = recoveredRecordingTimeline.totalSourceSampleCount
        let stoppedDuration = recoveredRecordingTimeline.totalDurationSeconds
        AppLogger.transcription.info("PARAKEET | recording stopped (\(stoppedSampleCount) samples, \(String(format: "%.1f", stoppedDuration))s)")
    }

    private func cancelPendingRecordingRecovery() {
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
        let pendingRestoreOwner = pendingSystemInputRestore.owner
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
        await restorePendingSystemInputAfterRecording(
            ownedBy: pendingRestoreOwner,
            operation: "reset_after_failed_recording_start"
        )
    }

    func abandonBlockedRecordingStart(reason: String) {
        beginFreshRecordingSession()
        let pendingRestoreOwner = pendingSystemInputRestore.owner
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
        schedulePendingSystemInputRestore(
            ownedBy: pendingRestoreOwner,
            operation: "abandon_blocked_recording_start"
        )
        if !didReplaceBlockedGraph {
            abandonBlockedAudioEngine(reason: reason)
        }
    }

    func cancel() {
        beginFreshRecordingSession()
        let pendingRestoreOwner = pendingSystemInputRestore.owner
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
        schedulePendingSystemInputRestore(ownedBy: pendingRestoreOwner, operation: "cancel")
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
        if let expectedGeneration, expectedGeneration != audioGraphGeneration {
            return nil
        }
        audioGraphGeneration += 1
        let idleCleanupOwner = currentAudioEngineQueueOwnerToken()
        if removeTap {
            await removeRecordingTap(force: true)
        }
        guard ownsAudioEngineQueue(idleCleanupOwner) else { return nil }
        let releasedVoiceProcessing = await stopAudioEngine()
        guard ownsAudioEngineQueue(idleCleanupOwner) else { return nil }
        isEnginePrewarmed = false
        if !releasedVoiceProcessing {
            return discardStoppedVoiceProcessingGraph(ownedBy: idleCleanupOwner)
        }
        return idleCleanupOwner
    }
}
