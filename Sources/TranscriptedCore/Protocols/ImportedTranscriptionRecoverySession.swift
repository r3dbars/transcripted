import Foundation

/// Durable ownership boundary for one imported-audio transcription.
///
/// The app layer owns the journal and cross-process lease. TranscriptedCore
/// reports only the three transitions that make recovery safe to retire or
/// advance; it never decides where or how the journal is stored.
public protocol ImportedTranscriptionRecoverySession: AnyObject, Sendable {
    var jobID: UUID { get }

    /// The transcript and its committed side effects are durable. Scratch audio
    /// may still be needed for speaker review or cleanup, so this does not retire
    /// the recovery record.
    func transcriptCommitConfirmed()

    /// The app-owned scratch entry is gone (or was already absent).
    func scratchCleanupConfirmed()

    /// A durable failed-queue row now owns the audio.
    func failedQueueHandoffConfirmed()
}
