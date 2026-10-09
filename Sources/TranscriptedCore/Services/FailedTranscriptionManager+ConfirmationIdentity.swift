import Foundation

extension FailedTranscriptionManager {
    /// Backfill crash-recovered import identity without retiring its journal
    /// until the failed queue can durably carry that identity into a retry.
    @discardableResult
    public func restoreConfirmationMeetingIdentity(id: UUID, meetingId: UUID) -> Bool {
        guard !hasPendingDeletion(id: id),
              let index = failedTranscriptions.firstIndex(where: { $0.id == id }) else { return false }
        let existing = failedTranscriptions[index]
        if let current = existing.confirmationMeetingId { return current == meetingId }
        failedTranscriptions[index].confirmationMeetingId = meetingId
        guard saveFailedTranscriptions() else {
            failedTranscriptions[index] = existing
            return false
        }
        return true
    }
}
