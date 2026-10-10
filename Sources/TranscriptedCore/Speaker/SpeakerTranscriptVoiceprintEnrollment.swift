import Foundation

/// Re-embed a named voice from a saved meeting's retained audio and, when that
/// works, write a voiceprint into the active speaker store.
///
/// Home naming of CLI-imported or older meetings has no live `sessionEmbedding`.
/// Island review can also land here when a row's profile was pruned and the
/// clip never produced a vector. Re-using the voiceprint-migration audio path
/// keeps embeddings in the active model's space (ReDimNet2 or WeSpeaker) and
/// leaves biometrics out of the transcript file.
public enum SpeakerTranscriptVoiceprintEnrollment {
    public enum Outcome: Equatable, Sendable {
        case enrolled(UUID)
        case taught(UUID)
        case transcriptOnly
    }

    /// Map retained-audio files the way migration does: `system_audio` or an
    /// import's `recording` on the call side, `microphone` in the room.
    /// `playback` is a mix and is never used as a voiceprint source.
    public static func tracks(fromAudioURLs urls: [URL]) -> [UtteranceChannel: URL] {
        func first(_ stem: String) -> URL? {
            urls
                .filter { $0.deletingPathExtension().lastPathComponent == stem }
                .sorted { $0.pathExtension.localizedCaseInsensitiveCompare($1.pathExtension) == .orderedAscending }
                .first
        }
        var tracks: [UtteranceChannel: URL] = [:]
        tracks[.system] = first("system_audio") ?? first("recording")
        tracks[.mic] = first("microphone")
        return tracks
    }

    /// Mean voiceprint for `labels` on `channel` (or both tracks when `channel`
    /// is nil). Nil when there is no usable audio, the embedder refuses the
    /// stretch, or the pieces don't pool into a finite non-zero vector.
    public static func embedding(
        markdown: String,
        labels: Set<String>,
        channel: UtteranceChannel?,
        tracks: [UtteranceChannel: URL],
        embedder: any SpeakerSegmentEmbedder,
        limits: SpeakerVoiceprintMigrationPolicy.RangeLimits = SpeakerVoiceprintMigrationPolicy.RangeLimits()
    ) -> [Float]? {
        let usableLabels = Set(labels.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        guard !usableLabels.isEmpty else { return nil }
        let rows = SpeakerVoiceprintTranscriptScan.transcriptRows(
            in: markdown,
            knownLabels: Array(usableLabels)
        )
        let channels: [UtteranceChannel] = channel.map { [$0] } ?? [.system, .mic]
        var pieces: [SpeakerVoiceprintMigrationPolicy.Piece] = []
        for track in channels {
            let ranges = SpeakerVoiceprintMigrationPolicy.ranges(
                forLabels: usableLabels,
                on: track,
                rows: rows,
                limits: limits
            )
            guard !ranges.isEmpty, let url = tracks[track], let file = SpeakerVoiceprintAudioReader.open(url) else {
                continue
            }
            for range in ranges {
                guard let samples = SpeakerVoiceprintAudioReader.samples(from: file, range: range),
                      let vector = embed(samples, with: embedder) else {
                    continue
                }
                pieces.append(.init(
                    embedding: vector,
                    seconds: Double(samples.count) / Double(SpeakerVoiceprintAudioReader.sampleRate)
                ))
            }
        }
        return SpeakerVoiceprintMigrationPolicy.pooledMean(pieces)
    }

    /// Write `embedding` as a new person or as more evidence for someone who
    /// already exists (the picked id, else the same typed name). No vector
    /// means the name stays in the transcript only.
    public static func enroll(
        name: String,
        embedding: [Float]?,
        targetProfileID: UUID?,
        transcriptID: UUID?,
        speakerDB: any SpeakerStore
    ) -> Outcome {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let embedding, isUsable(embedding) else {
            return .transcriptOnly
        }

        if let targetProfileID, speakerDB.getSpeaker(id: targetProfileID) != nil {
            return teach(targetProfileID, embedding: embedding, transcriptID: transcriptID, speakerDB: speakerDB)
        }

        let nameKey = normalize(trimmed)
        let existing = speakerDB.allSpeakers()
            .filter { normalize($0.displayName ?? "") == nameKey }
            .sorted { $0.callCount > $1.callCount }
            .first
        if let existing {
            return teach(existing.id, embedding: embedding, transcriptID: transcriptID, speakerDB: speakerDB)
        }

        do {
            var createdID: UUID?
            try speakerDB.performMutationBatch {
                let created = speakerDB.addOrUpdateSpeaker(embedding: embedding, existingId: nil)
                speakerDB.setDisplayName(id: created.id, name: trimmed, source: NameSource.userManual)
                speakerDB.resetDisputeCount(id: created.id)
                recordNamedConfirmation(profileID: created.id, transcriptID: transcriptID, speakerDB: speakerDB)
                createdID = created.id
            }
            guard let createdID else { return .transcriptOnly }
            return .enrolled(createdID)
        } catch {
            AppLogger.speakers.warning("Transcript voiceprint enrollment could not create a person; saving the name in the transcript only", [
                "reason": "create_failed"
            ])
            return .transcriptOnly
        }
    }

    private static func teach(
        _ profileID: UUID,
        embedding: [Float],
        transcriptID: UUID?,
        speakerDB: any SpeakerStore
    ) -> Outcome {
        do {
            try speakerDB.performMutationBatch {
                _ = speakerDB.addOrUpdateSpeaker(embedding: embedding, existingId: profileID)
                speakerDB.resetDisputeCount(id: profileID)
                recordNamedConfirmation(profileID: profileID, transcriptID: transcriptID, speakerDB: speakerDB)
            }
            return .taught(profileID)
        } catch {
            AppLogger.speakers.warning("Transcript voiceprint enrollment could not teach a saved person; saving the name in the transcript only", [
                "reason": "teach_failed"
            ])
            return .transcriptOnly
        }
    }

    private static func recordNamedConfirmation(
        profileID: UUID,
        transcriptID: UUID?,
        speakerDB: any SpeakerStore
    ) {
        guard let transcriptID else { return }
        do {
            try speakerDB.recordUserConfirmations([
                SpeakerUserConfirmation(profileId: profileID, transcriptId: transcriptID, kind: .named)
            ])
        } catch {
            AppLogger.speakers.warning("Transcript voiceprint enrollment saved the voice but not the confirmation row", [
                "reason": "confirmation_failed"
            ])
        }
    }

    private static func embed(_ samples: [Float], with embedder: any SpeakerSegmentEmbedder) -> [Float]? {
        guard let vector = embedder.embed(samples: samples, sampleRate: SpeakerVoiceprintAudioReader.sampleRate) else {
            return nil
        }
        return isUsable(vector, expectedDimension: embedder.dimension)
            ? SpeakerVectorMath.l2Normalize(vector)
            : nil
    }

    private static func isUsable(_ vector: [Float], expectedDimension: Int? = nil) -> Bool {
        if let expectedDimension, vector.count != expectedDimension { return false }
        return !vector.isEmpty && vector.allSatisfy(\.isFinite) && vector.contains(where: { $0 != 0 })
    }

    private static func normalize(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
