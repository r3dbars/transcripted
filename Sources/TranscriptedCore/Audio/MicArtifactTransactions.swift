import Foundation

struct FileActions<W: AnyObject,C> {
    let allocateURL: (ArtifactRole) throws -> URL
    let createWriter: (URL,C) throws -> W
    let closeWriter: (W) -> Void
    let restrictPermissions: (URL) -> Void
    let removeFile: (URL) throws -> Void
}
struct JournalBegin<F,E: AnyObject,T: Equatable> {
    let begin: (E,URL,F) throws -> T
}
enum MicArtifactTransactionFailure: Error {
    case stale
    case rollback(original: Error, cleanup: Error)
}

/// The complete file transactions used by capture. Native graph preparation,
/// tap installation and first-frame waiting stay outside this queue wrapper.
final class MicArtifactTransactions<W: AnyObject,C,F,E: AnyObject,T: Equatable>: @unchecked Sendable {
    typealias Context = RecordingArtifactContext<F,E,T>
    typealias Ticket = RecordingArtifactStopTicket<F,E,T>
    private let queue: DispatchQueue
    private let writerOwnership: MicWriterOwnership<W>
    private let owner: RecordingArtifactOwnership<F,E,T>
    private let files: FileActions<W,C>
    private let journal: JournalBegin<F,E,T>

    init(queue: DispatchQueue, writerOwnership: MicWriterOwnership<W>,
         owner: RecordingArtifactOwnership<F,E,T>, files: FileActions<W,C>,
         journal: JournalBegin<F,E,T>) {
        self.queue = queue; self.writerOwnership = writerOwnership
        self.owner = owner; self.files = files; self.journal = journal
    }

    func createInitial(context: Context, prepared: C) throws -> InitialSetupResult<C> {
        try queue.sync {
            dispatchPrecondition(condition: .onQueue(queue))
            guard owner.admitInitialTransaction(context) else { return .stale }
            let url = try files.allocateURL(.initial)
            var created: W?
            var installed = false
            do {
                let writer = try files.createWriter(url, prepared)
                created = writer
                let result = writerOwnership.installSessionWriter(writer, generation: context.captureGeneration)
                installed = result.didInstall
                guard installed else { throw MicArtifactTransactionFailure.stale }
                if let displaced = result.displacedWriter { files.closeWriter(displaced) }
                files.restrictPermissions(url)
                let token = try journal.begin(context.endpoint, url, context.facts)
                owner.commitInitial(context, primaryURL: url, token: token)
                return .started(prepared)
            } catch {
                do {
                    try rollback(writer: created, installed: installed, url: url, generation: context.captureGeneration)
                    owner.failInitial(context, ownedPrimaryURL: url)
                } catch let cleanup {
                    throw MicArtifactTransactionFailure.rollback(original: error, cleanup: cleanup)
                }
                throw error
            }
        }
    }

    func createRecovery(context: Context, prepared: C,
                        afterRetirement: (MicArtifactRetirement) -> Void = { _ in },
                        gapBefore: @autoclosure () -> TimeInterval) throws -> RecoverySetupResult<W,C> {
        try queue.sync {
            dispatchPrecondition(condition: .onQueue(queue))
            guard owner.admitRecoveryTransaction(context) else { return .notOwned }
            switch writerOwnership.retireWriterForRecovery(by: context.captureGeneration) {
            case .retired(let old):
                files.closeWriter(old)
                afterRetirement(.retired)
            case .alreadyRetired: afterRetirement(.alreadyRetired)
            case .notOwned: return .notOwned
            }
            let url = try files.allocateURL(.recovery)
            let identity = owner.nextRecoveryAttempt(in: context)
            var created: W?
            var installed = false
            var rollbackAttempted = false
            do {
                let writer = try files.createWriter(url, prepared)
                created = writer
                files.restrictPermissions(url)
                installed = writerOwnership.installRecoveryWriter(writer, generation: context.captureGeneration)
                guard installed else { throw MicArtifactTransactionFailure.stale }
                guard owner.register(identity, context: context,
                                     segment: MicRecordingSegment(url: url, gapBeforeDuration: gapBefore())) else {
                    rollbackAttempted = true
                    try rollback(writer: writer, installed: true, url: url, generation: context.captureGeneration)
                    return .notOwned
                }
                return .registered(RecordingArtifactRecoveryAttempt(identity: identity, context: context,
                                                                     url: url, writer: writer), prepared)
            } catch {
                if !rollbackAttempted {
                    do { try rollback(writer: created, installed: installed, url: url, generation: context.captureGeneration) }
                    catch let cleanup { throw MicArtifactTransactionFailure.rollback(original: error, cleanup: cleanup) }
                }
                throw error
            }
        }
    }

    func finishRecovery(attempt: RecordingArtifactRecoveryAttempt<W>, keep: Bool) throws -> RecoveryFinishResult {
        try queue.sync {
            dispatchPrecondition(condition: .onQueue(queue))
            guard let context = attempt.context as? Context else { return .alreadySettled }
            guard !owner.isAttemptSettled(attempt.identity, in: context) else { return .alreadySettled }
            if keep {
                _ = owner.settleAttempt(attempt.identity, in: context)
                return .kept
            }
            guard owner.unregister(attempt.identity, context: context, url: attempt.url) else {
                _ = owner.settleAttempt(attempt.identity, in: context)
                return .stopOwnsRegisteredSegment
            }
            // Stop cannot pass this Q block after unregister wins its cutoff.
            // Only the exact installed writer can be closed by this attempt.
            if writerOwnership.removeIfOwned(attempt.writer, generation: context.captureGeneration) {
                files.closeWriter(attempt.writer)
            }
            try files.removeFile(attempt.url)
            _ = owner.settleAttempt(attempt.identity, in: context)
            return .removed
        }
    }

    func remakeInitial(context: Context, prepared: C) throws -> InitialSetupResult<C> {
        try queue.sync {
            dispatchPrecondition(condition: .onQueue(queue))
            guard owner.admitRecoveryTransaction(context), let url = owner.primaryURL(in: context),
                  let old = writerOwnership.takeWriterOwned(by: context.captureGeneration) else { return .stale }
            files.closeWriter(old)
            let writer = try files.createWriter(url, prepared)
            let result = writerOwnership.installSessionWriter(writer, generation: context.captureGeneration)
            guard result.didInstall else { files.closeWriter(writer); return .stale }
            if let displaced = result.displacedWriter { files.closeWriter(displaced) }
            files.restrictPermissions(url)
            return .started(prepared)
        }
    }

    func closeForStopOnQueue(ticket: Ticket) -> RecordingArtifactSnapshot<E,T> {
        dispatchPrecondition(condition: .onQueue(queue))
        if let writer = writerOwnership.takeWriterOwned(by: ticket.context.captureGeneration,
                                                         invalidatingFor: ticket.stopGeneration) {
            files.closeWriter(writer)
        }
        return owner.snapshotForMicClose(ticket)
    }

    private func rollback(writer: W?, installed: Bool, url: URL, generation: UInt64) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        if let writer {
            if installed {
                guard writerOwnership.removeIfOwned(writer, generation: generation) else { return }
            }
            files.closeWriter(writer)
        }
        try files.removeFile(url)
    }
}
