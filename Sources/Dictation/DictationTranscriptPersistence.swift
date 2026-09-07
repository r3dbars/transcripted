import Foundation

/// Measures the writer itself, independently of Auto Enter and MainActor publication.
struct DictationTranscriptPersistenceResult: Sendable {
    let saved: SavedDictationTranscript?
    let failureError: Error?
    let startedAt: CFAbsoluteTime
    let finishedAt: CFAbsoluteTime

    var failureMessage: String? {
        guard failureError != nil else { return nil }
        return "Transcripted couldn't save a local copy of this dictation. Check your save location and available disk space."
    }

    static func measure(
        now: () -> CFAbsoluteTime = CFAbsoluteTimeGetCurrent,
        save: () throws -> SavedDictationTranscript
    ) -> Self {
        let startedAt = now()
        do {
            let saved = try save()
            return Self(saved: saved, failureError: nil, startedAt: startedAt, finishedAt: now())
        } catch {
            return Self(saved: nil, failureError: error, startedAt: startedAt, finishedAt: now())
        }
    }
}

enum DictationSessionCompletionPolicy {
    static func canPublish(sessionID: UUID, currentSessionID: UUID, isDictating: Bool, cancelled: Bool) -> Bool {
        sessionID == currentSessionID && isDictating && !cancelled
    }
}
