// MeetingSessionController+FailedMeetings.swift
// Failed-meeting forwarders kept on the controller for UI callers, and the
// FailedMeetingStore factory.

import AppKit
import Combine
import Foundation
import TranscriptedCore

@available(macOS 14.0, *)
@MainActor
extension MeetingSessionController {
    /// The capture is already closed; archiving must not hold its start gate or
    /// overwrite state if another meeting action runs while the disk is busy.
    func archiveUnexpectedStoppedRecording(
        files: (micURL: URL?, systemURL: URL?),
        failureMessage: String,
        snapshot: RecordingStopSnapshot
    ) async -> Bool {
        var archiveStateRevision: UInt64 = 0
        return await MeetingStopSequence.archiveUnexpectedStop(
            releaseCapture: {
                transition(to: .error("Recording stopped early. Saving audio for retry."), reason: "unexpected_capture_stop")
                archiveStateRevision = stateRevision
                Self.runtimeDiagnosticsRecorder?.clearSession(kind: "meeting", outcome: "capture_stopped_under_controller")
            },
            archive: {
                await failedMeetingStore.preserveFailedMeetingForRetryAfterArchive(
                    micAudioURL: files.micURL,
                    systemAudioURL: files.systemURL,
                    errorMessage: failureMessage,
                    meetingTitle: snapshot.suggestedTitle,
                    recordingDate: snapshot.recordingStartedAt,
                    splitLocalSpeakers: LocalSpeakerPreferences.isEnabled(),
                    languageSelection: snapshot.languageSelection,
                    micOnlyByChoice: snapshot.skippedSystemAudioTap
                )
            },
            stillOwnsCompletion: { stateRevision == archiveStateRevision },
            finish: { preserved in
                transition(
                    to: preserved
                        ? .error("Recording stopped early. Open the Meetings page to retry the saved audio.")
                        : .error("Recording stopped early and no meeting audio was saved."),
                    reason: "unexpected_capture_stop"
                )
            }
        )
    }

    // Full implementation moved to FailedMeetingStore.swift (audit
    // 2026-07-08 wave 2, W2-B). This forwarder keeps the public signature
    // controller callers (Settings/Home UI) already depend on.
    @discardableResult
    func retryFailedMeeting(id: UUID) -> Bool {
        failedMeetingStore.retryFailedMeeting(id: id)
    }

    // Full implementations moved to FailedMeetingStore.swift (audit
    // 2026-07-08 wave 2, W2-B). These forwarders keep the public signatures
    // controller callers (Settings/Home UI) already depend on.
    @discardableResult
    func deleteFailedMeeting(id: UUID) -> Bool {
        failedMeetingStore.deleteFailedMeeting(id: id)
    }

    private func prepareStoppedAudioRecoveryForRetry(failedMeetingID: UUID) {
        activeStoppedAudioRecovery = stoppedAudioRecoveryRetryRegistry.recovery(
            for: failedMeetingID
        )
    }

    private func discardStoppedAudioRecoveryForRetry(failedMeetingID: UUID) {
        let recovery = stoppedAudioRecoveryRetryRegistry.remove(for: failedMeetingID)
        if activeQueuedTranscriptionJobID == failedMeetingID {
            activeStoppedAudioRecovery = nil
        }
        guard recovery != nil else { return }
        Task.detached(priority: .utility) {
            DictationStoppedAudioRecoveryStore.cleanup(recovery, explicitDiscard: true)
        }
    }

    func makeFailedMeetingStore() -> FailedMeetingStore {
        FailedMeetingStore(
            taskManager: taskManager,
            failedManager: failedManager,
            canRetry: { [weak self] in
                guard let self else { return false }
                // isRecording is steady-state-only (state == .recording) —
                // isCaptureSessionActive also covers .startingRecording/
                // .stoppingRecording, so a retry (which awaits
                // prepareModelsForRetry -> prepareModels()) can't launch
                // during those windows and race a live capture the way
                // FailedMeetingStore.prepareModelsForRetry's unconditional
                // prepareModels() call already had to be guarded against
                // internally (see prepareModels()'s .loadingModels guard).
                return !self.isCaptureSessionActive
                    && !self.hasBackgroundTranscriptionWork
                    && !self.isSpeakerReviewPending
            },
            prepareModelsForRetry: { [weak self] in
                guard let self else { return false }
                // Hold while saved people move to the new voiceprint model. If
                // a meeting started transcribing meanwhile, it goes first and
                // the row stays retryable.
                if await self.voiceprintMigrationGate.waitUntilOpen(),
                   self.isCaptureSessionActive || self.hasBackgroundTranscriptionWork || self.isSpeakerReviewPending {
                    return false
                }
                await self.prepareModels()
                guard case .ready = self.state else { return false }
                return true
            },
            markRetryStarted: { [weak self] in
                self?.activeTranscriptionTrigger = .unknown
            },
            prepareStoppedAudioRecoveryForRetry: { [weak self] failedMeetingID in
                self?.prepareStoppedAudioRecoveryForRetry(failedMeetingID: failedMeetingID)
            },
            discardStoppedAudioRecoveryForRetry: { [weak self] failedMeetingID in
                self?.discardStoppedAudioRecoveryForRetry(failedMeetingID: failedMeetingID)
            },
            publishRefresh: { [weak self] in
                self?.refreshFailedMeetings()
            },
            diagnosticsContext: { [weak self] extra in
                self?.baseDiagnosticsContext(extra: extra) ?? extra
            }
        )
    }

    // preserveFailedMeetingForRetry, refreshTimedOutFailedMeetingAudio, and
    // scheduleFailedAudioCompression moved to FailedMeetingStore.swift
    // (audit 2026-07-08 wave 2, W2-B). Call sites now go through
    // `failedMeetingStore.`.
}
