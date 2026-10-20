// MeetingSessionController+StopSnapshot.swift
// The recording stop snapshot and system-audio signal verification, split out
// of MeetingSessionController.swift as a pure move.

import AppKit
import Combine
import Foundation
import TranscriptedCore

@available(macOS 14.0, *)
@MainActor
extension MeetingSessionController {
    func makeRecordingStopSnapshot() -> RecordingStopSnapshot {
        let evidence = MeetingCaptureHealthTelemetry.stopSnapshotEvidence(
            liveStatus: capture.systemAudioStatus,
            unknown: .unknown,
            liveWarning: systemAudioDegradationWarning,
            liveUnheardWarningStartedAt: unheardPlaybackWarningStartedAt,
            atCaptureStop: unexpectedCaptureStopEvidence,
            now: Date()
        )
        let systemAudioStatus = evidence.systemAudioStatus
        let durationSeconds = recordingDuration
        var baseHealthInfo = capture.healthInfo(overrideSystemAudioStatus: systemAudioStatus)
        let accessConfirmedByMacOS = systemAudioAccessConfirmedAtStop()
        if let signalEvidence = MeetingMicOnlyRecordingPolicy.systemAudioSignalEvidence(
            observed: capture.hasObservedSystemAudioSignal, micOnlyByChoice: activeRecordingIsMicOnlyByChoice,
            accessConfirmedByMacOS: accessConfirmedByMacOS
        ) {
            baseHealthInfo = baseHealthInfo.markingSystemAudioSignalVerified(signalEvidence)
        }
        // Only an interruption or failure warning latches degraded metadata.
        // A silence warning is legitimate (the remote side went quiet, or the
        // call ended before Stop was pressed) and used to stamp most saved
        // meetings degraded even when system audio finished healthy.
        let healthInfo: RecordingHealthInfo
        if MeetingSystemAudioDegradationPolicy.degradesSavedCaptureAtStop(
            evidence.degradationWarning,
            didLosePlayback: capture.systemAudioDidLosePlayback,
            unheardSeconds: evidence.unheardSeconds
        ) {
            healthInfo = baseHealthInfo.markingSystemAudioDegraded()
        } else {
            healthInfo = baseHealthInfo
        }
        return RecordingStopSnapshot(
            telemetryIdentity: activeRecordingIdentity,
            trigger: activeRecordingTrigger,
            systemAudioStatus: systemAudioStatus,
            durationSeconds: durationSeconds,
            healthInfo: healthInfo,
            pipelineSnapshot: capture.pipelineDiagnosticsSnapshot(
                overrideSystemAudioStatus: systemAudioStatus
            ),
            suggestedTitle: activeRecordingSuggestedTitle,
            recordingStartedAt: activeRecordingStartedAt,
            languageSelection: recordingLanguageSelection,
            sttModel: recordingSTTModel,
            isMicOnlyByChoice: activeRecordingIsMicOnlyByChoice,
            skippedSystemAudioTap: !capture.currentRecordingCapturesSystemAudio,
            systemAudioAccessConfirmedByMacOS: accessConfirmedByMacOS
        )
    }

    /// Snapshot capture health before the stop call, since the system-audio
    /// backend can clean up buffer counters before file-close completion resumes.
    func refreshSystemAudioSignalVerification(shouldWarn: Bool) {
        // Mic-only was the user's call at start; system-audio banners would
        // only repeat what they already chose.
        if activeRecordingIsMicOnlyByChoice {
            if systemAudioDegradationWarning != nil { systemAudioDegradationWarning = nil }
            return
        }
        let signalVerified = MeetingCaptureHealthEvidence.make(capture: capture).systemAudioSignalVerified
        let verified = MeetingSystemAudioDegradationPolicy.reconcilingSignalVerification(
            current: systemAudioDegradationWarning,
            signalVerified: signalVerified,
            shouldWarn: shouldWarn && !signalVerified && !systemAudioAccessConfirmedByMacOS(),
            isRecording: state == .recording
        )
        let updated = MeetingSystemAudioDegradationPolicy.reconcilingUnheardPlayback(
            current: verified,
            notHearingPlayback: capture.systemAudioNotHearingPlayback,
            playbackLossConfirmed: capture.systemAudioDidLosePlayback,
            isRecording: state == .recording
        )
        if updated != systemAudioDegradationWarning {
            let isUnheard = updated?.cause == .unheardPlayback && updated?.phase != .recovered
            let wasUnheard = systemAudioDegradationWarning?.cause == .unheardPlayback
                && systemAudioDegradationWarning?.phase != .recovered
            if isUnheard, !wasUnheard {
                // The report comes after about a minute of hearing nothing.
                unheardPlaybackWarningStartedAt = Date().addingTimeInterval(-MeetingCaptureBridge.systemAudioUnheardReportSeconds)
                recordUnheardPlaybackWarning()
            } else if !isUnheard {
                unheardPlaybackWarningStartedAt = nil
            }
            systemAudioDegradationWarning = updated
        }
    }
}
