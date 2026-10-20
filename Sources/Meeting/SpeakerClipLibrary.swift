import Foundation
import TranscriptedCore

/// The saved voice-sample clips the Speakers directory plays, plus the one
/// voice-similarity measure its duplicate check needs. Settings reaches the
/// Core clip files and vector math through here instead of naming them.
enum SpeakerClipLibrary {
    /// Cosine similarity of two voiceprints, or nil when they can't be compared
    /// (different lengths, or empty).
    nonisolated static func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Double? {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return nil }
        return SpeakerVectorMath.cosineSimilarity(lhs, rhs)
    }

    /// The saved clip for a speaker: the current clips folder first, then the
    /// legacy one.
    nonisolated static func clipURL(
        for speakerId: UUID,
        preferredClipsDirectory: URL,
        legacyClipsDirectory: URL
    ) -> URL? {
        SpeakerClipExtractor.persistentClipURL(for: speakerId, clipsDirectory: preferredClipsDirectory)
            ?? SpeakerClipExtractor.persistentClipURL(for: speakerId, clipsDirectory: legacyClipsDirectory)
    }

    /// The quote stored next to a saved clip, only when that sidecar
    /// describes this exact wav. Nil for older wavs, a version we don't
    /// read, or a pair whose size or hash no longer matches — callers
    /// must not guess a transcript line instead.
    ///
    /// Deleting a meeting does not remove this file. The clip is the
    /// person's voice sample, not meeting-owned media.
    nonisolated static func sampleText(nextTo clipURL: URL) -> String? {
        guard let sidecar = SpeakerClipSidecar.loadMatchingWav(nextTo: clipURL) else {
            return nil
        }
        let text = sidecar.sampleText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    nonisolated static func deleteClips(
        for speakerId: UUID,
        preferredClipsDirectory: URL,
        legacyClipsDirectory: URL
    ) {
        SpeakerClipExtractor.deletePersistedClip(for: speakerId, clipsDirectory: preferredClipsDirectory)
        if legacyClipsDirectory != preferredClipsDirectory {
            SpeakerClipExtractor.deletePersistedClip(for: speakerId, clipsDirectory: legacyClipsDirectory)
        }
    }

    /// After a merge, the kept person inherits the merged-away person's clip if
    /// they have none of their own. Returns false when that copy fails so the
    /// caller can leave the source clip in place. The has-clip check and copy
    /// share the same persist locks.
    @discardableResult
    nonisolated static func transferOnMerge(
        from sourceId: UUID,
        to targetId: UUID,
        preferredClipsDirectory: URL,
        legacyClipsDirectory: URL
    ) -> SpeakerClipMergeTransfer {
        SpeakerClipExtractor.transferOnMerge(
            from: sourceId,
            to: targetId,
            preferredClipsDirectory: preferredClipsDirectory,
            legacyClipsDirectory: legacyClipsDirectory
        )
    }

    /// Undo a merge copy when the people merge then fails. Deletes the
    /// kept person's clip only if it still hashes to the bytes that were
    /// copied. Transfer writes only the preferred folder.
    nonisolated static func rollbackCopiedClip(
        for speakerId: UUID,
        copiedWavSHA256: String,
        preferredClipsDirectory: URL
    ) {
        SpeakerClipExtractor.rollbackCopiedClip(
            for: speakerId,
            copiedWavSHA256: copiedWavSHA256,
            clipsDirectory: preferredClipsDirectory
        )
    }
}
