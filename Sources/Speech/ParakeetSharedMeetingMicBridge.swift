// ParakeetSharedMeetingMicBridge.swift
// Borrowed-mic dictation bridging for ParakeetEngine, split out of
// ParakeetEngine.swift (codebase audit 2026-08-05 follow-up wave — same
// extension-file pattern as ParakeetDeviceRecovery.swift and
// ParakeetModelLifecycle.swift).
//
// When a meeting already owns the microphone, dictation borrows the
// meeting's live mic stream instead of starting its own AVAudioEngine.
// This file owns that bridge: starting/finishing a borrowed-mic recording,
// receiving relayed PCM buffers and level updates, resuming regular mic
// capture when the meeting ends first, and resolving/finalizing stale
// claims whose minting meeting session died (see SharedMeetingMicClaim.swift
// for the handshake rationale).
//
// These are internal collaborator methods on ParakeetEngine — ParakeetEngine
// remains the public-API owner and MainActor home for this state
// (`sharedMeetingMicClaim`, `sharedMeetingMicRecorder`,
// `sharedMeetingMicTransition`); this file just groups the shared-mic slice
// of its implementation.

@preconcurrency import AVFoundation
import Foundation
import TranscriptedCore

extension ParakeetEngine {
    /// Begin dictation by borrowing the mic stream already owned by meeting
    /// capture. This deliberately does not touch AVAudioEngine or the system
    /// input route. `claim` is minted by
    /// `MeetingSessionController.startDictationFromActiveMeetingMic()` and
    /// carries the liveness probe the two device-recovery guards consult
    /// later via `resolveSharedMeetingMicClaimStatus()`.
    func startSharedMeetingMicRecording(claim: SharedMeetingMicClaim) -> Bool {
        guard !isShuttingDown, !isRecording, !audioStartInProgress else { return false }

        cancelAudioWatchdog()
        recordingInterrupted = false
        pendingSamplesLock.withLock {
            pendingSamples.removeAll(keepingCapacity: true)
        }
        clearRecoveredRecordingTimeline(keepingCapacity: true)
        sharedMeetingMicRecorder.begin()
        sharedMeetingMicTransition.beginSharedRecording()
        sharedMeetingMicClaim = claim
        isRecording = true
        audioLevel = 0

        EventReporter.shared.capture(
            level: .info,
            engine: "parakeet",
            event: "dictation_shared_meeting_mic_started",
            message: "Dictation started from the active meeting microphone stream"
        )
        return true
    }

    /// Called from MeetingCaptureBridge's off-tap relay queue.
    nonisolated func appendSharedMeetingMicBuffer(_ buffer: AVAudioPCMBuffer) {
        sharedMeetingMicRecorder.append(buffer)
    }

    func updateSharedMeetingMicAudioLevel(_ level: Float) {
        // Presence-only: a claim on file, dead or alive, still means there is
        // no local AVAudioEngine feeding this level meter, so this must stay
        // behavior-identical to the old bare Bool. See
        // resolveSharedMeetingMicClaimStatus()'s header for why this does not
        // go through the staleness check.
        guard sharedMeetingMicClaim != nil else { return }
        audioLevel = max(0, min(1, level))
    }

    /// If meeting capture ends first, preserve everything already borrowed and
    /// continue the same dictation on its regular mic engine.
    func resumeRegularRecordingAfterSharedMeetingMicEndedIfNeeded() async {
        guard sharedMeetingMicClaim != nil else { return }
        let transitionToken = sharedMeetingMicTransition.beginResume()
        finishSharedMeetingMicRecording(keepRecordingState: false)
        preservingRecordingAcrossRecovery = !recoveredRecordingTimeline.isEmpty

        let started = await startRecording(isRecoveryAttempt: true)
        guard sharedMeetingMicTransition.finishResume(token: transitionToken) else {
            if started {
                let pendingRestoreOwner = pendingSystemInputRestore.owner
                audioGraphGeneration += 1
                cancelAudioWatchdog()
                let staleResumeOwner = currentAudioEngineQueueOwnerToken()
                await removeRecordingTap()
                guard ownsAudioEngineQueue(staleResumeOwner) else { return }
                await stopAudioEngine()
                guard ownsAudioEngineQueue(staleResumeOwner) else { return }
                isRecording = false
                audioLevel = 0
                await restorePendingSystemInputAfterRecording(
                    ownedBy: pendingRestoreOwner,
                    operation: "stale_shared_meeting_mic_resume"
                )
            }
            return
        }

        guard started else {
            interruptRecordingPreservingRecoveredTimeline()
            EventReporter.shared.capture(
                level: .warning,
                engine: "parakeet",
                event: "dictation_shared_meeting_mic_resume_failed",
                message: "Dictation could not resume regular mic capture after the meeting ended"
            )
            return
        }

        EventReporter.shared.capture(
            level: .info,
            engine: "parakeet",
            event: "dictation_shared_meeting_mic_resumed_regular_capture",
            message: "Dictation resumed regular mic capture after the meeting ended"
        )
    }

    func finishSharedMeetingMicRecording(keepRecordingState: Bool) {
        sharedMeetingMicClaim = nil
        var timeline = sharedMeetingMicRecorder.finish()
        for segment in timeline.drain() {
            recoveredRecordingTimeline.append(segment.samples, sampleRate: segment.sampleRate)
        }
        preservingRecordingAcrossRecovery = !recoveredRecordingTimeline.isEmpty
        isRecording = keepRecordingState
        audioLevel = 0
    }

    /// Resolves `sharedMeetingMicClaim` into a status, finalizing a claim
    /// whose minting meeting session no longer reports itself alive (so
    /// subsequent reads see `.absent` directly) and reporting a
    /// privacy-safe event the moment that staleness is discovered — the
    /// previously-invisible failure class this handshake exists to close: a
    /// same-process Bool with no expiry that stayed forever-true if the
    /// meeting session died without running its own clear path.
    ///
    /// Call this only from the two guards that must distinguish a live
    /// meeting-owned mic from an orphaned claim: `handleSystemWake()` (via
    /// `isSharedMeetingMicClaimCurrent`) and
    /// `ParakeetDeviceRecovery.handleAudioConfigChange()`. Every other
    /// shared-mic call site is local Speech-side bookkeeping — "is dictation
    /// currently in borrowed-mic mode at all?" — and should keep testing
    /// `sharedMeetingMicClaim != nil` directly; those sites must stay
    /// behavior-identical to the old bare Bool because a claim on file, dead
    /// or alive, still means there is no local AVAudioEngine to tear down.
    /// `SharedMeetingMicTransitionState` (the resume-transition generation
    /// guard) is unrelated to this staleness question — it only fences
    /// stale *async continuations* within a single live resume, not claim
    /// ownership across meeting sessions.
    func resolveSharedMeetingMicClaimStatus() -> SharedMeetingMicClaimStatus {
        guard let claim = sharedMeetingMicClaim else { return .absent }
        guard claim.isSessionAlive() else {
            finalizeStaleSharedMeetingMicClaim()
            EventReporter.shared.capture(
                level: .warning,
                engine: "parakeet",
                event: "shared_meeting_mic_claim_stale",
                message: "Shared meeting-mic claim's session was no longer alive; releasing and treating dictation as unshared",
                context: ["claim_session": claim.sessionIdentity.uuidString]
            )
            return .stale
        }
        return .current
    }

    /// Finalizes a claim just discovered to be stale (its minting meeting
    /// session is no longer alive). Routes through the same finalize path a
    /// normal share-end takes — `finishSharedMeetingMicRecording` — so
    /// `sharedMeetingMicRecorder`'s buffered borrowed audio drains into
    /// `recoveredRecordingTimeline` instead of being silently discarded when
    /// the claim is cleared. `keepRecordingState: false` mirrors
    /// `resumeRegularRecordingAfterSharedMeetingMicEndedIfNeeded`'s own
    /// choice for "the meeting side is done with this borrow" — but unlike
    /// that path, a stale claim means dictation cannot ask the (dead)
    /// meeting session for anything, so this cannot attempt
    /// `startRecording(isRecoveryAttempt:)` itself; it only preserves what
    /// was captured and marks the recording interrupted
    /// (`interruptRecordingPreservingRecoveredTimeline`), exactly like any
    /// other capture that gets cut off mid-recording. The caller (wake or
    /// config-change recovery) runs immediately after with `isRecording`
    /// already `false`, so it takes its normal not-currently-recording path
    /// instead of trying to preserve/tear down a shared-mic recorder that no
    /// longer has anything queued.
    private func finalizeStaleSharedMeetingMicClaim() {
        sharedMeetingMicTransition.invalidate()
        finishSharedMeetingMicRecording(keepRecordingState: false)
        interruptRecordingPreservingRecoveredTimeline()
    }

    /// True only when a live claim is on file; see
    /// `resolveSharedMeetingMicClaimStatus()` for the staleness rule.
    var isSharedMeetingMicClaimCurrent: Bool {
        SharedMeetingMicClaimPolicy.isSharingActive(resolveSharedMeetingMicClaimStatus())
    }
}
