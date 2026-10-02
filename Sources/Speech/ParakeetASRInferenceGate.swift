import Foundation

/// Admission gate for the one shared TDT decoder (a CoreML object).
///
/// Dictation, meeting and imported-audio transcription all run through it, and
/// decoder calls must never overlap. When an inference finishes while callers
/// are queued, the slot is handed to the first waiter and that handoff is
/// reserved before the waiter resumes. A third caller arriving in between sees
/// the reservation and queues, so it can't start a decoder call alongside the
/// resumed waiter.
@MainActor
final class ParakeetASRInferenceGate {
    private var activity = ParakeetASRInferenceActivityState()
    private var reservedHandoffCount = 0
    private let waiters = ASRInferenceWaiterQueue()

    var activeCount: Int { activity.activeCount }
    var handoffCount: Int { reservedHandoffCount }
    var waiterCount: Int { waiters.count }

    /// True while any decoder call runs, a handoff is reserved, or a caller waits.
    var hasActiveWork: Bool {
        activity.isActive || reservedHandoffCount > 0 || !waiters.isEmpty
    }

    /// Admits the caller, waiting behind active decoder work if needed.
    /// `onDeferred` runs once, just before the caller queues. Throws
    /// `CancellationError` if the task is cancelled before admission.
    func begin(onDeferred: () -> Void = {}) async throws {
        try Task.checkCancellation()
        if activity.canStartImmediately(reservedHandoffCount: reservedHandoffCount) {
            activity.begin()
            return
        }
        onDeferred()
        try await waiters.wait()
        reservedHandoffCount = max(0, reservedHandoffCount - 1)
        activity.begin()
    }

    /// Releases the caller's slot. Returns true when the slot was handed to a
    /// queued caller, so the decoder is still spoken for.
    @discardableResult
    func finish() -> Bool {
        activity.finish()
        guard !waiters.isEmpty else { return false }
        reservedHandoffCount += 1
        waiters.resumeFirst()
        return true
    }
}
