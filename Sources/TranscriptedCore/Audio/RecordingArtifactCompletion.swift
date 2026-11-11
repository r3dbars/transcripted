import Foundation

struct TerminalFileActions<E: AnyObject,T: Equatable> {
    let merge: (RecordingArtifactSnapshot<E,T>) -> URL?
    let safeCleanup: (RecordingArtifactInventory) -> Bool
}
struct CompletionEdges: @unchecked Sendable {
    let beforeDelivery: (FinalizationOutput) -> Void
    let timeline: (FinalizationOutput) -> Void
    let generation: (FinalizationOutput) -> Void
    let legacy: (URL?, URL?) -> Void
}

/// Executes the same terminal ordering in capture and in pure fake-operation
/// tests. Each Stop supplies its own immutable timeline/callback captures.
final class RecordingArtifactCompletion<F,E: AnyObject,T: Equatable>: @unchecked Sendable {
    typealias Ticket = RecordingArtifactStopTicket<F,E,T>
    typealias Snapshot = RecordingArtifactSnapshot<E,T>
    typealias Action = RecordingArtifactTerminalAction<E,T>
    private let owner: RecordingArtifactOwnership<F,E,T>
    private let journal: JournalCommandDispatcher<F,E,T>
    private let files: TerminalFileActions<E,T>
    private let workQueue: DispatchQueue
    private let callbackQueue: DispatchQueue

    init(owner: RecordingArtifactOwnership<F,E,T>, journal: JournalCommandDispatcher<F,E,T>,
         files: TerminalFileActions<E,T>, workQueue: DispatchQueue, callbackQueue: DispatchQueue) {
        self.owner = owner; self.journal = journal; self.files = files
        self.workQueue = workQueue; self.callbackQueue = callbackQueue
    }

    func afterOwnedArtifactsDrained(_ ticket: Ticket, callbacks: CompletionEdges) {
        workQueue.async {
            switch self.owner.claimQuiescentFinalization(ticket) {
            case .normal(let snapshot), .normalThenDiscard(let snapshot):
                let finalMicURL = self.files.merge(snapshot)
                self.execute(self.owner.normalFinalizationFinished(ticket, actualFinalMicURL: finalMicURL),
                             ticket: ticket, callbacks: callbacks)
            case .recovery(let snapshot):
                self.execute(.recoveryRelease(snapshot), ticket: ticket, callbacks: callbacks)
            case .notOwned: break
            }
        }
    }

    @discardableResult
    func requestDiscard(context: RecordingArtifactContext<F,E,T>) -> DiscardAdmission {
        let admission = owner.requestDiscard(context: context)
        switch admission {
        case .selected, .alreadySelected:
            if let ticket = owner.ticket(for: context) {
                let action = owner.claimReadyCurrentDiscard(context)
                // Compatibility cleanup has no Stop callback edges: the normal
                // completion was already committed, queued or delivered.
                workQueue.async { self.execute(action, ticket: ticket, callbacks: nil) }
            }
        case .rejectedRecoveryOwner, .notOwned: break
        }
        return admission
    }

    private func execute(_ action: Action, ticket: Ticket, callbacks: CompletionEdges?) {
        switch action {
        case .normalRelease(let snapshot, let output):
            if let binding = snapshot.binding {
                journal.enqueue(.markFinalized(binding, finalMicURL: output.micURL, endingSession: true))
            }
            let compatibility = owner.normalReleaseEnqueued(ticket)
            workQueue.async { self.execute(compatibility, ticket: ticket, callbacks: nil) }
            deliver(.stopOnce(output), callbacks: callbacks)
        case .recoveryRelease(let snapshot):
            if let binding = snapshot.binding {
                journal.enqueue(.releaseRecovery(binding), replyOn: workQueue) { _ in
                    self.execute(self.owner.recoveryReleaseFinished(ticket), ticket: ticket, callbacks: callbacks)
                }
            } else {
                execute(owner.recoveryReleaseFinished(ticket), ticket: ticket, callbacks: callbacks)
            }
        case .discard(let snapshot, let inventory, let mode):
            prepareDiscard(snapshot: snapshot, inventory: inventory, mode: mode,
                           ticket: ticket, callbacks: callbacks)
        case .complete(let completion): deliver(completion, callbacks: callbacks)
        case .waitForExistingNormalFinalizer, .noAction: break
        }
    }

    private func prepareDiscard(snapshot: Snapshot, inventory: RecordingArtifactInventory,
                                mode: DiscardMode, ticket: Ticket, callbacks: CompletionEdges?) {
        guard let binding = snapshot.binding else {
            finishDiscard(snapshot: snapshot, inventory: inventory, ticket: ticket, callbacks: callbacks)
            return
        }
        let snapshotInventory: @Sendable () -> Void = {
            self.journal.enqueue(.snapshotOwnedDiscard(binding), replyOn: self.workQueue) { reply in
                guard case .inventory(let endpointInventory) = reply, let endpointInventory else {
                    self.finishCleanup(snapshot: snapshot, succeeded: false, ticket: ticket, callbacks: callbacks)
                    return
                }
                // The owner supplies the deletion root and authoritative Stop
                // system result. Never widen either from a candidate/cache.
                let complete = RecordingArtifactInventory(primaryURL: inventory.primaryURL ?? endpointInventory.primaryURL,
                    segments: inventory.segments, finalMicURL: inventory.finalMicURL,
                    finalSystemURL: inventory.finalSystemURL, allowedRoot: inventory.allowedRoot,
                    journalURL: endpointInventory.journalURL, journalData: endpointInventory.journalData)
                self.finishDiscard(snapshot: snapshot, inventory: complete, ticket: ticket, callbacks: callbacks)
            }
        }
        switch mode {
        case .pendingClaimHeld:
            journal.enqueue(.markFinalized(binding, finalMicURL: inventory.finalMicURL, endingSession: false),
                            replyOn: workQueue) { _ in snapshotInventory() }
        case .afterNormalReleaseCompatibility:
            // This queues after the already-committed ordinary release. It
            // does not reacquire a live claim or deliver a second completion.
            snapshotInventory()
        }
    }
    private func finishDiscard(snapshot: Snapshot, inventory: RecordingArtifactInventory,
                               ticket: Ticket, callbacks: CompletionEdges?) {
        let succeeded = files.safeCleanup(inventory)
        finishCleanup(snapshot: snapshot, succeeded: succeeded, ticket: ticket, callbacks: callbacks)
    }
    private func finishCleanup(snapshot: Snapshot, succeeded: Bool,
                               ticket: Ticket, callbacks: CompletionEdges?) {
        let finish: @Sendable () -> Void = {
            self.execute(self.owner.terminalCleanupFinished(ticket,
                result: succeeded ? .removed : .retainedAfterCleanupFailure), ticket: ticket, callbacks: callbacks)
        }
        if let binding = snapshot.binding {
            journal.enqueue(.finishOwnedDiscard(binding, cleanupSucceeded: succeeded), replyOn: workQueue) { _ in finish() }
        } else { finish() }
    }
    private func deliver(_ delivery: CompletionDelivery, callbacks: CompletionEdges?) {
        guard case .stopOnce(let output) = delivery, let callbacks else { return }
        callbackQueue.async {
            callbacks.beforeDelivery(output)
            callbacks.timeline(output)
            callbacks.generation(output)
            callbacks.legacy(output.micURL, output.systemURL)
        }
    }
}
