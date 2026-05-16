import Foundation

enum AudioReliabilityOutcomeKind: String, Equatable {
    case success
    case degradedSuccess = "degraded_success"
    case recoverableFailure = "recoverable_failure"
    case permanentFailure = "permanent_failure"
    case noArtifactFailure = "no_artifact_failure"
}

enum CaptureFailureStage: String, Equatable {
    case preflight
    case audioStart = "audio_start"
    case activeCapture = "active_capture"
    case transcription
    case diarization
    case save
    case retry
}

enum Retryability: String, Equatable {
    case retryable
    case retryableAfterUserAction = "retryable_after_user_action"
    case permanent
    case impossibleNoArtifact = "impossible_no_artifact"
}

enum ArtifactRetention: String, Equatable {
    case noneExpected = "none_expected"
    case retainedAudio = "retained_audio"
    case retainedPartialTranscript = "retained_partial_transcript"
    case retainedFailedQueueEntry = "retained_failed_queue_entry"
}

enum AudioReliabilityUserVisibleState: String, Equatable {
    case transcriptSaved = "transcript_saved"
    case transcriptSavedWithoutSpeakers = "transcript_saved_without_speakers"
    case retryAvailable = "retry_available"
    case needsUserAction = "needs_user_action"
    case permanentFailure = "permanent_failure"
    case nothingRecorded = "nothing_recorded"
}

struct MeetingFailureExplanation: Equatable {
    let outcomeKind: AudioReliabilityOutcomeKind
    let stage: CaptureFailureStage
    let retryability: Retryability
    let artifactRetention: ArtifactRetention
    let userVisibleState: AudioReliabilityUserVisibleState
    let failureKind: MeetingFailureKind?
    let recordingStarted: Bool
    let audioCaptured: Bool
    let transcriptionFailed: Bool
    let diarizationFailed: Bool
    let saveFailed: Bool
    let recoverableArtifact: Bool
    let retryAvailable: Bool

    var answeredCount: Int { 7 }

    static func make(
        failureKind: MeetingFailureKind?,
        hasAudioFiles: Bool,
        isRetryable: Bool,
        stage: CaptureFailureStage? = nil,
        transcriptSaved: Bool = false,
        failedQueueEntryRetained: Bool = false
    ) -> MeetingFailureExplanation {
        let resolvedStage = stage ?? defaultStage(for: failureKind)
        let recordingStarted = didRecordingStart(failureKind: failureKind, hasAudioFiles: hasAudioFiles)
        let retryability = resolvedRetryability(
            failureKind: failureKind,
            hasAudioFiles: hasAudioFiles,
            isRetryable: isRetryable
        )
        let artifactRetention = resolvedArtifactRetention(
            hasAudioFiles: hasAudioFiles,
            transcriptSaved: transcriptSaved,
            failedQueueEntryRetained: failedQueueEntryRetained
        )
        let outcomeKind = resolvedOutcomeKind(
            failureKind: failureKind,
            stage: resolvedStage,
            hasAudioFiles: hasAudioFiles,
            isRetryable: isRetryable,
            transcriptSaved: transcriptSaved
        )
        let userVisibleState = resolvedUserVisibleState(
            outcomeKind: outcomeKind,
            failureKind: failureKind,
            retryability: retryability
        )

        let recoverableArtifact = hasAudioFiles || artifactRetention == .retainedPartialTranscript

        return MeetingFailureExplanation(
            outcomeKind: outcomeKind,
            stage: resolvedStage,
            retryability: retryability,
            artifactRetention: artifactRetention,
            userVisibleState: userVisibleState,
            failureKind: failureKind,
            recordingStarted: recordingStarted,
            audioCaptured: hasAudioFiles,
            transcriptionFailed: failureKind == .transcriptionInferenceFailed,
            diarizationFailed: failureKind == .diarizationFailed,
            saveFailed: isSaveStageFailure(failureKind),
            recoverableArtifact: recoverableArtifact,
            retryAvailable: recoverableArtifact && (retryability == .retryable || retryability == .retryableAfterUserAction)
        )
    }

    var reportFields: [String: String] {
        [
            "outcome_kind": outcomeKind.rawValue,
            "stage": stage.rawValue,
            "failure_kind": failureKind?.rawValue ?? "none",
            "retryability": retryability.rawValue,
            "artifact_retention": artifactRetention.rawValue,
            "user_visible_state": userVisibleState.rawValue,
            "recording_started": Self.yesNo(recordingStarted),
            "audio_captured": Self.yesNo(audioCaptured),
            "transcription_failed": Self.yesNo(transcriptionFailed),
            "diarization_failed": Self.yesNo(diarizationFailed),
            "save_failed": Self.yesNo(saveFailed),
            "recoverable_artifact": Self.yesNo(recoverableArtifact),
            "retry_available": Self.yesNo(retryAvailable)
        ]
    }

    var telemetryPayload: [String: String] {
        [
            "outcome_kind": outcomeKind.rawValue,
            "stage": stage.rawValue,
            "failure_kind": failureKind?.rawValue ?? "none",
            "retryability": retryability.rawValue,
            "artifact_retention": artifactRetention.rawValue,
            "user_visible_state": userVisibleState.rawValue
        ]
    }

    private static func defaultStage(for failureKind: MeetingFailureKind?) -> CaptureFailureStage {
        guard let failureKind else { return .save }

        switch failureKind {
        case .systemAudioPermission,
             .microphonePermission,
             .microphoneMissing,
             .pipelineBusy:
            return .preflight
        case .audioDeviceUnavailable,
             .stopTimeout:
            return .audioStart
        case .modelDownloadFailed,
             .modelNotLoaded,
             .pipelineFailed,
             .transcriptionInferenceFailed,
             .emptyAudio,
             .invalidAudioFormat,
             .recordingTooShort:
            return .transcription
        case .diarizationFailed:
            return .diarization
        case .saveFailed,
             .speakerNameFinalizationFailed,
             .speakerFinalizationFailed:
            return .save
        case .unexpectedError:
            return .activeCapture
        }
    }

    private static func didRecordingStart(failureKind: MeetingFailureKind?, hasAudioFiles: Bool) -> Bool {
        if hasAudioFiles { return true }
        guard let failureKind else { return true }

        switch failureKind {
        case .systemAudioPermission,
             .microphonePermission,
             .microphoneMissing,
             .audioDeviceUnavailable,
             .modelDownloadFailed,
             .modelNotLoaded,
             .pipelineBusy:
            return false
        default:
            return true
        }
    }

    private static func resolvedRetryability(
        failureKind: MeetingFailureKind?,
        hasAudioFiles: Bool,
        isRetryable: Bool
    ) -> Retryability {
        guard let failureKind else { return .permanent }

        if !hasAudioFiles {
            switch failureKind {
            case .systemAudioPermission,
                 .microphonePermission,
                 .microphoneMissing,
                 .audioDeviceUnavailable:
                return .retryableAfterUserAction
            default:
                return .impossibleNoArtifact
            }
        }

        if isRetryable { return .retryable }

        switch failureKind {
        case .systemAudioPermission,
             .microphonePermission,
             .microphoneMissing,
             .audioDeviceUnavailable,
             .saveFailed,
             .speakerNameFinalizationFailed,
             .speakerFinalizationFailed:
            return .retryableAfterUserAction
        default:
            return .permanent
        }
    }

    private static func resolvedArtifactRetention(
        hasAudioFiles: Bool,
        transcriptSaved: Bool,
        failedQueueEntryRetained: Bool
    ) -> ArtifactRetention {
        if transcriptSaved { return .retainedPartialTranscript }
        if failedQueueEntryRetained { return .retainedFailedQueueEntry }
        if hasAudioFiles { return .retainedAudio }
        return .noneExpected
    }

    private static func resolvedOutcomeKind(
        failureKind: MeetingFailureKind?,
        stage: CaptureFailureStage,
        hasAudioFiles: Bool,
        isRetryable: Bool,
        transcriptSaved: Bool
    ) -> AudioReliabilityOutcomeKind {
        guard let failureKind else { return .success }

        if stage == .diarization && transcriptSaved {
            return .degradedSuccess
        }

        if !hasAudioFiles {
            return .noArtifactFailure
        }

        if isRetryable {
            return .recoverableFailure
        }

        switch failureKind {
        case .saveFailed,
             .speakerNameFinalizationFailed,
             .speakerFinalizationFailed:
            return .recoverableFailure
        default:
            return .permanentFailure
        }
    }

    private static func resolvedUserVisibleState(
        outcomeKind: AudioReliabilityOutcomeKind,
        failureKind: MeetingFailureKind?,
        retryability: Retryability
    ) -> AudioReliabilityUserVisibleState {
        switch outcomeKind {
        case .success:
            return .transcriptSaved
        case .degradedSuccess:
            return .transcriptSavedWithoutSpeakers
        case .noArtifactFailure:
            if retryability == .retryableAfterUserAction {
                return .needsUserAction
            }
            return .nothingRecorded
        case .recoverableFailure:
            if retryability == .retryableAfterUserAction || failureKind == .saveFailed {
                return .needsUserAction
            }
            return .retryAvailable
        case .permanentFailure:
            return .permanentFailure
        }
    }

    private static func yesNo(_ value: Bool) -> String {
        value ? "yes" : "no"
    }

    private static func isSaveStageFailure(_ failureKind: MeetingFailureKind?) -> Bool {
        failureKind == .saveFailed
            || failureKind == .speakerNameFinalizationFailed
            || failureKind == .speakerFinalizationFailed
    }
}
