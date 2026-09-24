import Foundation
import SQLite3

/// Why a speaker review could not be saved. Raw values are coarse, stable
/// codes that are safe to send off-device (no names, ids, paths, or error
/// text), so telemetry can tell the remaining failure causes apart.
public enum SpeakerFinalizationFailureReason: String, Sendable, CaseIterable {
    /// A correction had no voice sample to build the corrected person from.
    case planMissingEmbedding = "plan_missing_embedding"
    /// The saved transcript could not be found by path or stable id.
    case transcriptUnresolved = "transcript_unresolved"
    /// The saved transcript could not be read before the rewrite.
    case transcriptUnreadable = "transcript_unreadable"
    /// Rewriting the speaker names in the transcript failed.
    case nameRewriteFailed = "name_rewrite_failed"
    /// Marking the transcript for later review failed.
    case deferredMarkerFailed = "deferred_marker_failed"
    /// Folding local speakers back into "You" failed.
    case collapseFailed = "collapse_failed"
    /// Removing discarded speakers' database links failed.
    case discardFailed = "discard_failed"
    /// A merge could not find one of its two saved people.
    case mergeProfileMissing = "merge_profile_missing"
    /// A merge found saved voices that cannot be blended.
    case mergeEmbeddingInvalid = "merge_embedding_invalid"
    /// A confirmation pointed at a saved person that no longer exists.
    case confirmationProfileMissing = "confirmation_profile_missing"
    /// The people database was not open.
    case databaseUnavailable = "database_unavailable"
    /// Any other people database write failure.
    case databaseWriteFailed = "database_write_failed"

    /// Classifies an error thrown by the people database batch.
    static func classify(databaseError error: Error) -> SpeakerFinalizationFailureReason {
        if let mergeError = error as? SpeakerDatabase.ProfileMergeError {
            switch mergeError {
            case .profileNotFound:
                return .mergeProfileMissing
            case .invalidEmbeddingState:
                return .mergeEmbeddingInvalid
            }
        }
        if let sqliteError = error as? SpeakerDatabase.SQLiteOperationError {
            switch sqliteError.code {
            case SQLITE_NOTFOUND:
                // NOTFOUND means a write touched no row: a confirmation for a person who
                // is gone, or a merge step whose person vanished mid-merge.
                let operation = sqliteError.operation.lowercased()
                if operation.contains("merge") { return .mergeProfileMissing }
                if operation.contains("confirmation") { return .confirmationProfileMissing }
                return .databaseWriteFailed
            case SQLITE_MISUSE:
                return .databaseUnavailable
            default:
                return .databaseWriteFailed
            }
        }
        return .databaseWriteFailed
    }

    /// Any merge step that touched no row (including the confirmation moves inside a
    /// merge) means one of the two people vanished mid-merge. Report it as the merge
    /// error it is, not as a missing confirmation.
    static func mergeError(from error: Error, sourceId: UUID, targetId: UUID) -> Error {
        guard let sqliteError = error as? SpeakerDatabase.SQLiteOperationError,
              sqliteError.code == SQLITE_NOTFOUND else {
            return error
        }
        AppLogger.speakers.error("Speaker merge step touched no row", [
            "error": sqliteError.localizedDescription
        ])
        return SpeakerDatabase.ProfileMergeError.profileNotFound(sourceId: sourceId, targetId: targetId)
    }
}

/// Privacy-safe context for the most recent speaker review save failure.
/// Published by `TranscriptionTaskManager` before the matching failed
/// `displayStatus`, so a status observer can attach it to the failure event.
public struct SpeakerFinalizationFailure: Sendable, Equatable {
    public enum ReviewMode: String, Sendable {
        /// The user pressed Save with at least one verdict.
        case save
        /// The review closed with no verdicts (Review later, window closed).
        case reviewLater = "review_later"
    }

    public let reason: SpeakerFinalizationFailureReason
    public let reviewMode: ReviewMode
    /// True when this review came from retrying a failed meeting.
    public let isRetry: Bool

    public init(reason: SpeakerFinalizationFailureReason, reviewMode: ReviewMode, isRetry: Bool) {
        self.reason = reason
        self.reviewMode = reviewMode
        self.isRetry = isRetry
    }
}
