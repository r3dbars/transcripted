import Foundation

enum JournalCommand<E: AnyObject,T: Equatable>: @unchecked Sendable {
    case recordSegments(RecordingArtifactJournalBinding<E,T>, [MicRecordingSegment])
    case recordSystemURL(RecordingArtifactJournalBinding<E,T>, URL)
    case clearSystemURL(RecordingArtifactJournalBinding<E,T>)
    case markStopping(RecordingArtifactJournalBinding<E,T>)
    case markFinalized(RecordingArtifactJournalBinding<E,T>, finalMicURL: URL?, endingSession: Bool)
    case snapshotOwnedDiscard(RecordingArtifactJournalBinding<E,T>)
    case finishOwnedDiscard(RecordingArtifactJournalBinding<E,T>, cleanupSucceeded: Bool)
    case releaseRecovery(RecordingArtifactJournalBinding<E,T>)
}
enum JournalReply: @unchecked Sendable { case applied, inventory(RecordingArtifactInventory?), released }
struct JournalApplications<E: AnyObject,T: Equatable> {
    let recordSegments: (RecordingArtifactJournalBinding<E,T>, [MicRecordingSegment]) -> Void
    let recordSystemURL: (RecordingArtifactJournalBinding<E,T>, URL) -> Void
    let clearSystemURL: (RecordingArtifactJournalBinding<E,T>) -> Void
    let markStopping: (RecordingArtifactJournalBinding<E,T>) -> Void
    let markFinalized: (RecordingArtifactJournalBinding<E,T>, URL?, Bool) -> Void
    let snapshotOwnedDiscard: (RecordingArtifactJournalBinding<E,T>) -> RecordingArtifactInventory?
    let finishOwnedDiscard: (RecordingArtifactJournalBinding<E,T>, Bool) -> Void
    let releaseRecovery: (RecordingArtifactJournalBinding<E,T>) -> Void
}

/// enqueue never invokes application code synchronously. Application can
/// overlap a caller still holding G, so it must never take G/O or wait back
/// into the mic/graph queues. All endpoint applications are queue-confined.
final class JournalCommandDispatcher<F,E: AnyObject,T: Equatable>: @unchecked Sendable {
    let queue: DispatchQueue
    private let applications: JournalApplications<E,T>
    init(queue: DispatchQueue, applications: JournalApplications<E,T>) {
        self.queue = queue; self.applications = applications
    }
    func enqueue(_ command: JournalCommand<E,T>) {
        queue.async { _ = self.apply(command) }
    }
    func enqueue(_ command: JournalCommand<E,T>, replyOn: DispatchQueue,
                 completion: @escaping @Sendable (JournalReply) -> Void) {
        queue.async {
            let reply = self.apply(command)
            replyOn.async { completion(reply) }
        }
    }
    private func apply(_ command: JournalCommand<E,T>) -> JournalReply {
        dispatchPrecondition(condition: .onQueue(queue))
        switch command {
        case .recordSegments(let b, let segments): applications.recordSegments(b, segments)
        case .recordSystemURL(let b, let url): applications.recordSystemURL(b, url)
        case .clearSystemURL(let b): applications.clearSystemURL(b)
        case .markStopping(let b): applications.markStopping(b)
        case .markFinalized(let b, let url, let ending): applications.markFinalized(b, url, ending)
        case .snapshotOwnedDiscard(let b): return .inventory(applications.snapshotOwnedDiscard(b))
        case .finishOwnedDiscard(let b, let succeeded):
            applications.finishOwnedDiscard(b, succeeded); return .released
        case .releaseRecovery(let b): applications.releaseRecovery(b); return .released
        }
        return .applied
    }
}
