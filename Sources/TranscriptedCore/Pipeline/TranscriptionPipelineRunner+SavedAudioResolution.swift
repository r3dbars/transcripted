import Foundation

// MARK: - Saved transcript audio resolution (moved from TranscriptionPipelineRunner.swift)

extension TranscriptionTaskManager {

    struct SavedTranscriptAudioResolution: Sendable {
        let includesMicrophone: Bool
        let includesSystemAudio: Bool
        let healthInfo: RecordingHealthInfo?
    }

    /// Resolve partial-success audio channels before formatting and retention.
    /// Unusable channels are excluded from source metadata and mark the artifact
    /// degraded. A failed mic keeps flowing through archival for future retry;
    /// a corrupt/short system file is excluded from retained playback.
    nonisolated static func savedTranscriptAudioResolution(
        microphoneURLWasProvided: Bool,
        microphoneOutcome: TranscriptionResult.MicrophoneAudioOutcome,
        systemOutcome: TranscriptionResult.SystemAudioOutcome = .usable,
        healthInfo: RecordingHealthInfo?
    ) -> SavedTranscriptAudioResolution {
        let includesMicrophone = microphoneURLWasProvided && microphoneOutcome != .unusable
        let includesSystemAudio = systemOutcome == .usable
        var resolvedHealth = healthInfo
        if microphoneURLWasProvided && microphoneOutcome == .unusable {
            resolvedHealth = (resolvedHealth ?? .perfect).markingMicrophoneAudioUnusable()
        }
        if systemOutcome == .unusable {
            resolvedHealth = (resolvedHealth ?? .perfect).markingSystemAudioMissing()
        }
        return SavedTranscriptAudioResolution(
            includesMicrophone: includesMicrophone,
            includesSystemAudio: includesSystemAudio,
            healthInfo: resolvedHealth
        )
    }
}
