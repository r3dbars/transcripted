import Combine
import Foundation
import TranscriptedCore

/// Meeting owns speaker persistence; Settings supplies plain review rows.
final class SpeakerSettingsStore: Sendable {
    struct ReviewRow: Sendable {
        let transcriptURL: URL
        let transcriptId: UUID?
        let diarizerSpeakerId: String
        let channel: UtteranceChannel
    }
    struct MergeRecord: Identifiable, Sendable {
        let id: UUID
        let sourceId: UUID
        let targetId: UUID
        let sourceName: String?
        let targetName: String?
        let kind: String
        let mergedAt: Date
        let isUndone: Bool
    }
    private let speakerDatabase: SpeakerDatabase
    private let transcriptDirectory: URL
    private let preferredClipsDirectory: URL
    static var defaultTranscriptDirectory: URL { TranscriptSaver.defaultSaveDirectory }
    static var defaultLegacyClipsDirectory: URL { CoreStoragePaths.default.speakerClips }
    private let legacyClipsDirectory: URL
    init(
        speakerDatabase: SpeakerDatabase, transcriptDirectory: URL = TranscriptSaver.defaultSaveDirectory,
        preferredClipsDirectory: URL, legacyClipsDirectory: URL = CoreStoragePaths.default.speakerClips
    ) {
        self.speakerDatabase = speakerDatabase
        self.transcriptDirectory = transcriptDirectory
        self.preferredClipsDirectory = preferredClipsDirectory
        self.legacyClipsDirectory = legacyClipsDirectory
    }
    func configured(transcriptDirectory: URL, preferredClipsDirectory: URL, legacyClipsDirectory: URL) -> SpeakerSettingsStore {
        SpeakerSettingsStore(speakerDatabase: speakerDatabase, transcriptDirectory: transcriptDirectory,
            preferredClipsDirectory: preferredClipsDirectory, legacyClipsDirectory: legacyClipsDirectory)
    }

    func getSpeaker(id: UUID) -> SpeakerProfile? { speakerDatabase.getSpeaker(id: id) }
    func allSpeakers() -> [SpeakerProfile] { speakerDatabase.allSpeakers() }
    func deleteSpeaker(id: UUID) { speakerDatabase.deleteSpeaker(id: id) }
    func unmergeMostRecent(forTargetId id: UUID) -> Bool { speakerDatabase.unmergeMostRecent(forTargetId: id) }
    func undoableMerge(forTargetId id: UUID) -> MergeRecord? {
        speakerDatabase.undoableMerge(forTargetId: id).map {
            MergeRecord(
                id: $0.id, sourceId: $0.sourceId, targetId: $0.targetId,
                sourceName: $0.sourceName, targetName: $0.targetName, kind: $0.kind,
                mergedAt: $0.mergedAt, isUndone: $0.isUndone)
        }
    }
    func nameReviewedVoice(speakerId: UUID, trimmed: String, matchingReviewItems: [ReviewRow]) -> Bool {
        let allTranscriptUpdatesSucceeded: Bool
        do {
            allTranscriptUpdatesSucceeded = try TranscriptSaver.updateDeferredSpeakerNames(
                matchingReviewItems.map { reviewItem in
                    TranscriptSaver.DeferredSpeakerNameUpdate(
                        transcriptURL: reviewItem.transcriptURL,
                        dbId: speakerId,
                        diarizerSpeakerId: reviewItem.diarizerSpeakerId,
                        channel: reviewItem.channel
                    )
                },
                newName: trimmed,
                persistIdentity: { [speakerDatabase] in
                    try speakerDatabase.performMutationBatch {
                        try speakerDatabase.requireDisplayNameUpdate(
                            id: speakerId,
                            name: trimmed,
                            source: NameSource.userManual
                        )
                        speakerDatabase.resetDisputeCount(id: speakerId)
                        try speakerDatabase.recordUserConfirmations(
                            matchingReviewItems.compactMap { reviewItem in
                                reviewItem.transcriptId.map {
                                    SpeakerUserConfirmation(
                                        profileId: speakerId,
                                        transcriptId: $0,
                                        kind: .named
                                    )
                                }
                            }
                        )
                    }
                }
            )
        } catch {
            AppLogger.speakers.error(
                "Deferred speaker rename transaction failed",
                [
                    "profileId": speakerId.uuidString,
                    "error": error.localizedDescription,
                ])
            allTranscriptUpdatesSucceeded = false
        }
        return allTranscriptUpdatesSucceeded
    }

    func mergeReviewedVoice(sourceId: UUID, targetId: UUID, rows: [ReviewRow], confirmedTranscriptIds: [UUID]) -> Bool {
        let reviewedRows = rows.map {
            TranscriptSaver.DeferredSpeakerNameUpdate(
                transcriptURL: $0.transcriptURL, dbId: sourceId,
                diarizerSpeakerId: $0.diarizerSpeakerId, channel: $0.channel)
        }

        var didMerge = false
        do {
            let outcome = try SpeakerIdentityMutationService.apply(
                .mergeReviewedVoice(
                    sourceId: sourceId,
                    targetId: targetId,
                    reviewedRows: reviewedRows,
                    confirmedTranscriptIds: confirmedTranscriptIds
                ),
                speakerDB: speakerDatabase,
                directory: transcriptDirectory,
                clipSideEffects: SpeakerIdentityMutationService.ClipSideEffects(
                    onMergeCommitted: { [preferredClipsDirectory, legacyClipsDirectory] sourceId, targetId in
                        SpeakerClipLibrary.promoteClipIfNeeded(
                            from: sourceId,
                            to: targetId,
                            preferredClipsDirectory: preferredClipsDirectory,
                            legacyClipsDirectory: legacyClipsDirectory
                        )
                        SpeakerClipLibrary.deleteClips(
                            for: sourceId,
                            preferredClipsDirectory: preferredClipsDirectory,
                            legacyClipsDirectory: legacyClipsDirectory
                        )
                    }
                )
            )
            if !outcome.succeeded {
                AppLogger.speakers.error(
                    "Queued voice merge into saved person failed",
                    [
                        "sourceId": sourceId.uuidString,
                        "targetId": targetId.uuidString,
                    ])
            }
            didMerge = outcome.succeeded
        } catch {
            Self.reportMutationFailure(error, engine: "speakers", profileId: sourceId)
        }
        return didMerge
    }

    func rename(profileId: UUID, trimmed: String) -> Bool {
        var didRename = false
        // Routed through the canonical mutation service (audit 2026-08-04): this used
        // to write the DB first and best-effort-scan transcripts second with no
        // rollback, so a transcript write failure left the DB and saved transcripts
        // disagreeing about the speaker's name. The service snapshots and rewrites
        // transcripts first and only commits the DB change once every rewrite has
        // succeeded, rolling transcripts back if the DB transaction itself fails.
        do {
            let outcome = try SpeakerIdentityMutationService.apply(
                .rename(profileId: profileId, newName: trimmed),
                speakerDB: speakerDatabase,
                directory: transcriptDirectory
            )
            didRename = outcome.succeeded
            if !outcome.succeeded {
                AppLogger.speakers.error("Manual speaker rename failed", ["profileId": profileId.uuidString])
            }
        } catch {
            Self.reportMutationFailure(error, engine: "speakers", profileId: profileId)
        }
        return didRename
    }

    func merge(sourceId: UUID, targetId: UUID) -> Bool {
        // Routed through the canonical mutation service (audit 2026-08-04), replacing
        // SpeakerProfileMergeSideEffectCoordinator (DB + clips only, no transcript
        // rollback) plus a separate un-rolled-back TranscriptSaver.retroactivelyMergeSpeaker
        // scan. The service snapshots and rewrites transcripts first, commits the DB
        // merge inside a real transaction, rolls transcripts back if that transaction
        // throws, and only then runs clip promotion/deletion. Same-id merges are
        // rejected by the service itself now (MutationError.sameSourceAndTarget), so the
        // `source.id != target.id` guard above is defense in depth, not the only guard.
        var didMerge = false
        do {
            let outcome = try SpeakerIdentityMutationService.apply(
                .merge(sourceId: sourceId, targetId: targetId),
                speakerDB: speakerDatabase,
                directory: transcriptDirectory,
                clipSideEffects: SpeakerIdentityMutationService.ClipSideEffects(
                    onMergeCommitted: { [preferredClipsDirectory, legacyClipsDirectory] sourceId, targetId in
                        SpeakerClipLibrary.promoteClipIfNeeded(
                            from: sourceId,
                            to: targetId,
                            preferredClipsDirectory: preferredClipsDirectory,
                            legacyClipsDirectory: legacyClipsDirectory
                        )
                        SpeakerClipLibrary.deleteClips(
                            for: sourceId,
                            preferredClipsDirectory: preferredClipsDirectory,
                            legacyClipsDirectory: legacyClipsDirectory
                        )
                    }
                )
            )
            if !outcome.succeeded {
                AppLogger.speakers.error(
                    "Manual speaker merge failed",
                    [
                        "sourceId": sourceId.uuidString,
                        "targetId": targetId.uuidString,
                    ])
            }
            didMerge = outcome.succeeded
        } catch {
            Self.reportMutationFailure(error, engine: "speakers", profileId: sourceId)
        }
        return didMerge
    }
    /// Surfaces a `SpeakerIdentityMutationService.MutationError` beyond the local log —
    /// specifically `.transcriptRestoreFailed`, where the DB and a saved transcript may now
    /// permanently disagree and a caller that only checked `outcome.succeeded` would never
    /// see it (this path throws instead of returning a plain `Outcome`). Privacy-safe:
    /// only a profile id (opaque UUID, not a name) and a file count go out, never a path or
    /// display name.
    nonisolated private static func reportMutationFailure(
        _ error: Error,
        engine: String,
        profileId: UUID
    ) {
        AppLogger.speakers.error(
            "Manual speaker identity mutation failed",
            [
                "profileId": profileId.uuidString,
                "error": error.localizedDescription,
            ])
        guard case SpeakerIdentityMutationService.MutationError.transcriptRestoreFailed(let fileCount) = error else {
            return
        }
        DispatchQueue.main.async {
            EventReporter.shared.capture(
                level: .error,
                engine: engine,
                event: "speaker_identity_transcript_restore_failed",
                message: "Speaker identity rollback could not restore one or more transcripts",
                context: [
                    "profileId": profileId.uuidString,
                    "fileCount": "\(fileCount)",
                ]
            )
        }
    }
}
