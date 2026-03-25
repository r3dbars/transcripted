import Foundation

// MARK: - Transcript Storage Protocol
// Conformer: TranscriptSaver (static methods — protocol for future instance-based storage)

protocol TranscriptStorage {
    /// Save a transcription result to disk
    /// - Returns: URL of saved transcript file, or nil on failure
    static func saveTranscript(
        _ result: TranscriptionResult,
        speakerMappings: [String: SpeakerMapping],
        speakerSources: [String: String],
        speakerDbIds: [String: UUID],
        directory: URL?,
        meetingTitle: String?,
        healthInfo: RecordingHealthInfo?
    ) -> URL?

    /// Update speaker names in an existing transcript file
    /// - Returns: true if the file was updated successfully
    @discardableResult
    static func updateSpeakerNames(transcriptURL: URL, updates: [SpeakerNameUpdate]) -> Bool

    /// Retroactively update a speaker name across existing transcripts
    static func retroactivelyUpdateSpeaker(dbId: UUID, newName: String)

    /// Retroactively update the meeting title in transcript YAML
    /// - Returns: true if the file was updated successfully
    @discardableResult
    static func retroactivelyUpdateTitle(transcriptURL: URL, title: String) -> Bool

    /// Default save directory
    static var defaultSaveDirectory: URL { get }
}
