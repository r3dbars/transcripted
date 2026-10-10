import Foundation
import TranscriptedCore

/// App-facing result of trying to save a voiceprint for a Home-named speaker.
/// UISettings cannot name Core enrollment types, so this stays in Meeting.
enum MeetingSpeakerVoiceprintSave: Equatable, Sendable {
    case saved(UUID)
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
        let labels = Set([displayName, currentLabel].map {
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
                speakerDB: speakerDB
            ) {
            case .enrolled(let id), .taught(let id):
                return .saved(id)
            case .transcriptOnly:
                return .transcriptOnly
            }
        }.value
    }
}
