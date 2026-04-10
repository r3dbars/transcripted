import Foundation

// MARK: - Transcript Storage Protocol
// Conformer: TranscriptSaver (static-only — protocol mirrors the real static API so
// embedders can substitute their own disk layout without wrapping in an instance type).

@available(macOS 14.0, *)
public protocol TranscriptStorage {
    /// Save a transcription result to disk.
    /// - Returns: URL of saved transcript file, or nil on failure.
    @discardableResult
    static func saveTranscript(
        _ result: TranscriptionResult,
        speakerMappings: [String: SpeakerMapping],
        speakerSources: [String: String],
        speakerDbIds: [String: UUID],
        directory: URL?,
        meetingTitle: String?,
        healthInfo: RecordingHealthInfo?,
        notifier: TranscriptNotifier?,
        speakerStoreForIndex: (any SpeakerStore)?
    ) -> URL?

    /// Update speaker names in an existing transcript file.
    /// - Returns: true if the file was updated successfully.
    @discardableResult
    static func updateSpeakerNames(
        transcriptURL: URL,
        updates: [SpeakerNameUpdate],
        speakerStoreForIndex: (any SpeakerStore)?
    ) -> Bool

    /// Retroactively update a speaker name across existing transcripts on disk.
    static func retroactivelyUpdateSpeaker(
        dbId: UUID,
        newName: String,
        directory: URL,
        speakerStoreForIndex: (any SpeakerStore)?
    )

    /// Default save directory (reads UserDefaults override if the standalone app sets one,
    /// otherwise `CoreStoragePaths.default.transcripts`).
    static var defaultSaveDirectory: URL { get }
}
