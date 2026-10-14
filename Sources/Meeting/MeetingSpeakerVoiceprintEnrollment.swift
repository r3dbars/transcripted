import Foundation
import TranscriptedCore

/// App-facing result of trying to save a voiceprint for a Home-named speaker.
/// UISettings cannot name Core enrollment types, so this stays in Meeting.
enum MeetingSpeakerVoiceprintSave: Equatable, Sendable {
    /// Taught an existing saved person.
    case saved(UUID)
    /// Created a new person. If the transcript rewrite then fails, the caller
    /// discards it so no orphan is left for a retry to teach again.
    case enrolledNew(UUID)
    case transcriptOnly
}

extension MeetingSessionController {
    /// Re-embed one Home-named voice from this meeting's retained audio and
    /// write it to the active speaker database. Waits for the voiceprint
    /// migration gate first. No injected embedder (WeSpeaker-native launch)
    /// or no retained audio (`--no-retain-audio`, deleted files) fails closed
    /// as `transcriptOnly`.
    func enrollNamedSpeakerFromTranscript(
        markdown: String,
        audioURLs: [URL],
        displayName: String,
        currentLabel: String,
        channelRawValue: String?,
        targetProfileID: UUID?,
        transcriptID: UUID?
    ) async -> MeetingSpeakerVoiceprintSave {
        await voiceprintMigrationGate.waitUntilOpen()
        let embedder = diarization.injectedSegmentEmbedder
        let speakerDB = speakerDatabase
        let channel: UtteranceChannel?
        switch channelRawValue {
        case "mic":
            channel = .mic
        case "system":
            channel = .system
        default:
            channel = nil
        }
        // Only the voice being named. Rows already labeled with the new name
        // can belong to someone else (an auto-recognized saved "Maya", or an
        // earlier transcript-only "Maya"), and pooling them blends two voices.
        let labels = Set([currentLabel].map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })

        return await Task.detached(priority: .userInitiated) {
            let tracks = SpeakerTranscriptVoiceprintEnrollment.tracks(fromAudioURLs: audioURLs)
            let embedding = embedder.flatMap { embedder in
                SpeakerTranscriptVoiceprintEnrollment.embedding(
                    markdown: markdown,
                    labels: labels,
                    channel: channel,
                    tracks: tracks,
                    embedder: embedder
                )
            }
            switch SpeakerTranscriptVoiceprintEnrollment.enroll(
                name: displayName,
                embedding: embedding,
                targetProfileID: targetProfileID,
                transcriptID: transcriptID,
                speakerDB: speakerDB,
                thresholds: speakerDB.thresholds
            ) {
            case .enrolled(let id):
                return .enrolledNew(id)
            case .taught(let id):
                return .saved(id)
            case .transcriptOnly:
                return .transcriptOnly
            }
        }.value
    }

    /// Undo `enrolledNew` people whose transcript rewrite never landed.
    func discardEnrolledSpeakers(_ ids: [UUID]) async {
        guard !ids.isEmpty else { return }
        let speakerDB = speakerDatabase
        await Task.detached(priority: .userInitiated) {
            for id in ids { speakerDB.deleteSpeaker(id: id) }
        }.value
    }
}
