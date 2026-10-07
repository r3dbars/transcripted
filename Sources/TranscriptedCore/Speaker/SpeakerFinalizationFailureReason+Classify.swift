import Foundation
import SQLite3

// Mapping people-database errors to reason codes. Kept apart from the enum in
// SpeakerFinalizationFailure.swift so that file has no database dependency and the
// app's fast telemetry tests can compile it.
extension SpeakerFinalizationFailureReason {
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
