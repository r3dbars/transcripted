import Foundation

/// Exact recording artifact admission. G is the existing generation lock;
/// stateLock is O. Only typed nonreentrant journal enqueue runs under G.
final class RecordingArtifactOwnership<F,E: AnyObject,T: Equatable>: @unchecked Sendable {
    typealias Context = RecordingArtifactContext<F,E,T>
    typealias Ticket = RecordingArtifactStopTicket<F,E,T>
    typealias Snapshot = RecordingArtifactSnapshot<E,T>
    typealias Action = RecordingArtifactTerminalAction<E,T>
    let clock: RecordingGenerationClock
    let allowedRoot: URL
    private let journalCommands: JournalCommandDispatcher<F,E,T>
    private let stateLock = NSLock()
    private var current: Context?
    private var stops: [UInt64: Ticket] = [:]

    init(clock: RecordingGenerationClock, journalCommands: JournalCommandDispatcher<F,E,T>, allowedRoot: URL) {
        self.clock = clock; self.journalCommands = journalCommands; self.allowedRoot = allowedRoot
    }

    func beginContext(facts: F, endpoint: E) -> Context {
        clock.generationLock.lock()
        let generation = clock.advanceEpochWhileLocked()
        let context = Context(captureGeneration: generation, ownerIdentity: ObjectIdentifier(self),
                              facts: facts, endpoint: endpoint, allowedRoot: allowedRoot)
        stateLock.lock()
        let displaced = current
        let retired = stops.values.filter { $0.terminalFinished }
        for ticket in retired { stops.removeValue(forKey: ticket.stopGeneration) }
        current = context
        stateLock.unlock()
        clock.publishMirrorWhileLocked(generation)
        let hook = clock.advanceHookSnapshotWhileLocked()
        clock.generationLock.unlock()
        withExtendedLifetime((displaced, retired)) {}
        hook?(generation)
        return context
    }

    // Compatibility for existing internal fixture setup, not start admission.
    func adoptCurrentGeneration(facts: F, endpoint: E) -> Context {
        clock.generationLock.lock(); defer { clock.generationLock.unlock() }
        stateLock.lock(); defer { stateLock.unlock() }
        if let current { return current }
        let context = Context(captureGeneration: clock.currentWhileLocked(), ownerIdentity: ObjectIdentifier(self),
                              facts: facts, endpoint: endpoint, allowedRoot: allowedRoot)
        current = context
        return context
    }

    func replaceGenerationForTesting(_ value: UInt64?) -> UInt64 {
        clock.generationLock.lock()
        stateLock.lock()
        current?.sealed = true
        stateLock.unlock()
        let generation: UInt64
        if let value { clock.replaceEpochWhileLocked(value); generation = value }
        else { generation = clock.advanceEpochWhileLocked() }
        clock.publishMirrorWhileLocked(generation)
        let hook = clock.advanceHookSnapshotWhileLocked()
        clock.generationLock.unlock()
        hook?(generation)
        return generation
    }

    func currentContext() -> Context? {
        stateLock.lock(); defer { stateLock.unlock() }; return current
    }
    func primaryURL(in context: Context) -> URL? {
        stateLock.lock(); defer { stateLock.unlock() }; return context.primaryURL
    }
    func segments(in context: Context) -> [MicRecordingSegment] {
        stateLock.lock(); defer { stateLock.unlock() }; return context.segments
    }
    func binding(in context: Context) -> RecordingArtifactJournalBinding<E,T>? {
        stateLock.lock(); defer { stateLock.unlock() }; return bindingLocked(context)
    }
    func candidateSystemURL(in context: Context) -> URL? {
        stateLock.lock(); defer { stateLock.unlock() }
        switch context.stopSystem { case .unresolved: return context.systemCandidate; case .handedOff(let url): return url }
    }

    // Existing internal Audio setup accessors delegate here. Production file
    // setup uses the complete Q transactions instead of these value setters.
    func setPrimary(_ url: URL?, in context: Context) {
        stateLock.lock(); context.primaryURL = url; stateLock.unlock()
    }
    func setSegments(_ segments: [MicRecordingSegment], in context: Context) {
        stateLock.lock(); context.segments = segments; stateLock.unlock()
    }
    func setToken(_ token: T?, in context: Context) {
        stateLock.lock(); let retained = context.token; context.token = token; stateLock.unlock()
        withExtendedLifetime(retained) {}
    }
    func appendSegmentWhileGenerationLocked(_ segment: MicRecordingSegment, in context: Context) {
        stateLock.lock()
        guard isCurrentLocked(context) else { stateLock.unlock(); return }
        context.segments.append(segment)
        let segments = context.segments; let binding = bindingLocked(context)
        stateLock.unlock()
        if let binding { journalCommands.enqueue(.recordSegments(binding, segments)) }
    }
    func unregisterSegmentWhileGenerationLocked(_ url: URL, in context: Context) -> Bool {
        stateLock.lock()
        guard isCurrentLocked(context) else { stateLock.unlock(); return false }
        context.segments.removeAll { $0.url == url }
        let segments = context.segments; let binding = bindingLocked(context)
        stateLock.unlock()
        if let binding { journalCommands.enqueue(.recordSegments(binding, segments)) }
        return true
    }
    func retainCompatibilityStop(_ context: Context, generation: UInt64, token: T?) -> Ticket {
        clock.generationLock.lock()
        stateLock.lock()
        let retained = context.token
        let displaced = stops[generation]
        let ticket = Ticket(context: context, stopGeneration: generation)
        context.token = token; context.sealed = true; context.stopTicket = ticket; stops[generation] = ticket
        stateLock.unlock(); clock.generationLock.unlock()
        withExtendedLifetime((retained, displaced)) {}
        return ticket
    }

    func admitInitialTransaction(_ context: Context) -> Bool {
        clock.generationLock.lock(); defer { clock.generationLock.unlock() }
        stateLock.lock(); defer { stateLock.unlock() }
        guard isCurrentLocked(context), !context.initialAdmitted else { return false }
        context.initialAdmitted = true
        return true
    }
    func commitInitial(_ context: Context, primaryURL: URL, token: T) {
        clock.generationLock.lock()
        stateLock.lock()
        guard belongs(context), context.initialAdmitted, !context.initialCompleted else {
            stateLock.unlock(); clock.generationLock.unlock(); return
        }
        context.initialCompleted = true
        let retainedToken = context.token
        context.primaryURL = primaryURL
        if !context.segments.contains(where: { $0.url == primaryURL }) {
            context.segments.insert(MicRecordingSegment(url: primaryURL), at: 0)
        }
        context.token = token
        let binding = bindingLocked(context)!
        let segments = context.segments
        let system = context.stopSystem
        let candidate = context.systemCandidate
        stateLock.unlock()
        journalCommands.enqueue(.recordSegments(binding, segments))
        switch system {
        case .unresolved:
            if let candidate { journalCommands.enqueue(.recordSystemURL(binding, candidate)) }
        case .handedOff(let url):
            if let url { journalCommands.enqueue(.recordSystemURL(binding, url)) }
            else { journalCommands.enqueue(.clearSystemURL(binding)) }
        }
        clock.generationLock.unlock()
        withExtendedLifetime(retainedToken) {}
    }
    func failInitial(_ context: Context, ownedPrimaryURL: URL?) {
        clock.generationLock.lock(); defer { clock.generationLock.unlock() }
        stateLock.lock(); defer { stateLock.unlock() }
        guard belongs(context) else { return }
        context.initialCompleted = true
        guard context.primaryURL == ownedPrimaryURL else { return }
        context.primaryURL = nil
        context.segments.removeAll { $0.url == ownedPrimaryURL }
    }
    func admitRecoveryTransaction(_ context: Context) -> Bool {
        clock.generationLock.lock(); defer { clock.generationLock.unlock() }
        stateLock.lock(); defer { stateLock.unlock() }
        return isCurrentLocked(context)
    }
    func nextRecoveryAttempt(in context: Context) -> RecoveryAttemptIdentity {
        stateLock.lock(); defer { stateLock.unlock() }
        context.nextAttempt &+= 1
        return RecoveryAttemptIdentity(generation: context.captureGeneration, sequence: context.nextAttempt)
    }
    func register(_ attempt: RecoveryAttemptIdentity, context: Context, segment: MicRecordingSegment) -> Bool {
        clock.generationLock.lock(); defer { clock.generationLock.unlock() }
        stateLock.lock()
        guard isCurrentLocked(context), attempt.generation == context.captureGeneration,
              !context.registeredAttempts.contains(attempt.sequence), !context.settledAttempts.contains(attempt.sequence) else { stateLock.unlock(); return false }
        context.registeredAttempts.insert(attempt.sequence)
        context.segments.append(segment)
        let binding = bindingLocked(context); let segments = context.segments
        stateLock.unlock()
        if let binding { journalCommands.enqueue(.recordSegments(binding, segments)) }
        return true
    }
    func unregister(_ attempt: RecoveryAttemptIdentity, context: Context, url: URL) -> Bool {
        clock.generationLock.lock(); defer { clock.generationLock.unlock() }
        stateLock.lock()
        guard isCurrentLocked(context), attempt.generation == context.captureGeneration,
              context.registeredAttempts.contains(attempt.sequence), !context.settledAttempts.contains(attempt.sequence) else { stateLock.unlock(); return false }
        context.registeredAttempts.remove(attempt.sequence)
        context.segments.removeAll { $0.url == url }
        let binding = bindingLocked(context); let segments = context.segments
        stateLock.unlock()
        if let binding { journalCommands.enqueue(.recordSegments(binding, segments)) }
        return true
    }
    func isAttemptSettled(_ attempt: RecoveryAttemptIdentity, in context: Context) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return !belongs(context) || attempt.generation != context.captureGeneration || context.settledAttempts.contains(attempt.sequence)
    }
    func settleAttempt(_ attempt: RecoveryAttemptIdentity, in context: Context) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        guard belongs(context), attempt.generation == context.captureGeneration,
              !context.settledAttempts.contains(attempt.sequence) else { return false }
        context.settledAttempts.insert(attempt.sequence)
        return true
    }
    func updateGap(_ context: Context, url: URL, gapBefore: TimeInterval) -> Bool {
        clock.generationLock.lock(); defer { clock.generationLock.unlock() }
        return updateGapWhileGenerationLocked(context, url: url, gapBefore: gapBefore)
    }
    func updateGapWhileGenerationLocked(_ context: Context, url: URL, gapBefore: TimeInterval) -> Bool {
        stateLock.lock()
        guard isCurrentLocked(context) else { stateLock.unlock(); return false }
        context.segments = context.segments.map { $0.url == url ? MicRecordingSegment(url: url, gapBeforeDuration: gapBefore) : $0 }
        let binding = bindingLocked(context); let segments = context.segments
        stateLock.unlock()
        if let binding { journalCommands.enqueue(.recordSegments(binding, segments)) }
        return true
    }
    func bindSystemCandidate(_ context: Context, url: URL) -> Bool {
        clock.generationLock.lock(); defer { clock.generationLock.unlock() }
        stateLock.lock()
        guard isCurrentLocked(context), case .unresolved = context.stopSystem else { stateLock.unlock(); return false }
        context.systemCandidate = url; let binding = bindingLocked(context)
        stateLock.unlock()
        if let binding { journalCommands.enqueue(.recordSystemURL(binding, url)) }
        return true
    }
    func clearSystemCandidate(_ context: Context) -> Bool {
        clock.generationLock.lock(); defer { clock.generationLock.unlock() }
        stateLock.lock()
        guard isCurrentLocked(context), case .unresolved = context.stopSystem else { stateLock.unlock(); return false }
        context.systemCandidate = nil
        let binding = bindingLocked(context)
        stateLock.unlock()
        if let binding { journalCommands.enqueue(.clearSystemURL(binding)) }
        return true
    }
    func sealStop(expectedCaptureGeneration: UInt64) -> Ticket? {
        clock.generationLock.lock()
        stateLock.lock()
        guard let context = current, context.captureGeneration == expectedCaptureGeneration else {
            stateLock.unlock(); clock.generationLock.unlock(); return nil
        }
        if let existing = context.stopTicket {
            stateLock.unlock(); clock.generationLock.unlock(); return existing
        }
        guard clock.currentWhileLocked() == expectedCaptureGeneration else {
            stateLock.unlock(); clock.generationLock.unlock(); return nil
        }
        let generation = clock.advanceEpochWhileLocked()
        context.sealed = true
        let ticket = Ticket(context: context, stopGeneration: generation)
        context.stopTicket = ticket; stops[generation] = ticket
        stateLock.unlock()
        clock.setInFlightWhileLocked(generation)
        clock.publishMirrorWhileLocked(generation)
        let hook = clock.advanceHookSnapshotWhileLocked()
        clock.generationLock.unlock()
        hook?(generation)
        return ticket
    }
    func commitStopSystemHandoff(_ ticket: Ticket, url: URL?) {
        clock.generationLock.lock(); defer { clock.generationLock.unlock() }
        stateLock.lock()
        guard belongs(ticket.context) else { stateLock.unlock(); return }
        ticket.context.stopSystem = .handedOff(url)
        let binding = bindingLocked(ticket.context)
        stateLock.unlock()
        if let binding {
            if let url { journalCommands.enqueue(.recordSystemURL(binding, url)) }
            else { journalCommands.enqueue(.clearSystemURL(binding)) }
        }
    }
    func snapshotForMicClose(_ ticket: Ticket) -> Snapshot {
        clock.generationLock.lock(); defer { clock.generationLock.unlock() }
        stateLock.lock(); let snapshot = snapshotLocked(ticket); stateLock.unlock()
        if let binding = snapshot.binding { journalCommands.enqueue(.markStopping(binding)) }
        return snapshot
    }

    func requestDiscard(context: Context) -> DiscardAdmission {
        stateLock.lock(); defer { stateLock.unlock() }
        guard belongs(context) else { return .notOwned }
        if context.decision == .recovery { return .rejectedRecoveryOwner }
        if context.decision == .discard { return .alreadySelected }
        guard current === context else { return .notOwned }
        context.decision = .discard
        return .selected
    }
    func requestAbandon(stopGeneration: UInt64) -> AbandonAdmission {
        stateLock.lock(); defer { stateLock.unlock() }
        guard let ticket = stops[stopGeneration] else { return .notOwned }
        switch ticket.context.decision {
        case .discard: return .rejectedDiscardOwner
        case .recovery: return .alreadySelected
        case .undecided: break
        }
        guard !ticket.finalizerClaimed, !ticket.normalReleaseCommitted else { return .finalizerOwned }
        ticket.context.decision = .recovery
        return .selected
    }
    func claimQuiescentFinalization(_ ticket: Ticket) -> QuiescentClaim<E,T> {
        stateLock.lock(); defer { stateLock.unlock() }
        guard belongs(ticket.context), !ticket.finalizerClaimed, !ticket.completionScheduled else { return .notOwned }
        ticket.quiescent = true; ticket.finalizerClaimed = true
        let snapshot = snapshotLocked(ticket)
        switch ticket.context.decision {
        case .undecided: return .normal(snapshot)
        case .discard: return .normalThenDiscard(snapshot)
        case .recovery: return .recovery(snapshot)
        }
    }
    func normalFinalizationFinished(_ ticket: Ticket, actualFinalMicURL: URL?) -> Action {
        stateLock.lock(); defer { stateLock.unlock() }
        guard belongs(ticket.context), ticket.finalizerClaimed, !ticket.normalReleaseCommitted,
              !ticket.cleanupClaimed, !ticket.completionScheduled else { return .noAction }
        ticket.actualFinalMicURL = actualFinalMicURL; ticket.normalCompleted = true
        let snapshot = snapshotLocked(ticket)
        if ticket.context.decision == .discard {
            ticket.cleanupClaimed = true
            return .discard(snapshot, snapshot.inventory(finalMicURL: actualFinalMicURL), .pendingClaimHeld)
        }
        ticket.normalReleaseCommitted = true; ticket.completionScheduled = true; ticket.terminalFinished = true
        return .normalRelease(snapshot, outputLocked(ticket, disposition: .finalized))
    }
    /// Called only after the concrete ordinary release was enqueued (or the
    /// explicit no-binding path). A concurrent D cannot snapshot ahead of it.
    func normalReleaseEnqueued(_ ticket: Ticket) -> Action {
        stateLock.lock(); defer { stateLock.unlock() }
        guard belongs(ticket.context), ticket.normalReleaseCommitted else { return .noAction }
        ticket.normalReleaseEnqueued = true
        return claimReadyCurrentDiscardLocked(ticket.context)
    }
    func claimReadyCurrentDiscard(_ context: Context) -> Action {
        stateLock.lock(); defer { stateLock.unlock() }
        return claimReadyCurrentDiscardLocked(context)
    }
    private func claimReadyCurrentDiscardLocked(_ context: Context) -> Action {
        guard belongs(context), context.decision == .discard, let ticket = context.stopTicket,
              ticket.normalCompleted, ticket.normalReleaseCommitted, ticket.normalReleaseEnqueued, !ticket.cleanupClaimed else { return .waitForExistingNormalFinalizer }
        ticket.cleanupClaimed = true
        let snapshot = snapshotLocked(ticket)
        return .discard(snapshot, snapshot.inventory(finalMicURL: ticket.actualFinalMicURL), .afterNormalReleaseCompatibility)
    }
    func terminalCleanupFinished(_ ticket: Ticket, result: CleanupResult) -> Action {
        stateLock.lock(); defer { stateLock.unlock() }
        guard belongs(ticket.context), ticket.context.decision == .discard, ticket.cleanupClaimed else { return .noAction }
        ticket.terminalFinished = true
        guard !ticket.completionScheduled else { return .complete(.noneAlreadyScheduled) }
        ticket.completionScheduled = true
        return .complete(.stopOnce(outputLocked(ticket, disposition: .finalized)))
    }
    func recoveryReleaseFinished(_ ticket: Ticket) -> Action {
        stateLock.lock(); defer { stateLock.unlock() }
        guard belongs(ticket.context), ticket.context.decision == .recovery,
              ticket.quiescent, !ticket.completionScheduled else { return .noAction }
        ticket.completionScheduled = true; ticket.terminalFinished = true
        return .complete(.stopOnce(outputLocked(ticket, disposition: .journalRecoveryOwned)))
    }
    func ticket(forStopGeneration generation: UInt64) -> Ticket? {
        stateLock.lock(); defer { stateLock.unlock() }; return stops[generation]
    }
    func ticket(for context: Context) -> Ticket? {
        stateLock.lock(); defer { stateLock.unlock() }; return context.stopTicket
    }

    private func belongs(_ context: Context) -> Bool { context.ownerIdentity == ObjectIdentifier(self) }
    private func isCurrentLocked(_ context: Context) -> Bool {
        belongs(context) && current === context && !context.sealed && clock.currentWhileLocked() == context.captureGeneration
    }
    private func bindingLocked(_ context: Context) -> RecordingArtifactJournalBinding<E,T>? {
        context.token.map { RecordingArtifactJournalBinding(endpoint: context.endpoint, token: $0) }
    }
    private func snapshotLocked(_ ticket: Ticket) -> Snapshot {
        let context = ticket.context
        let systemURL: URL?
        switch context.stopSystem { case .unresolved: systemURL = nil; case .handedOff(let url): systemURL = url }
        return Snapshot(captureGeneration: context.captureGeneration, stopGeneration: ticket.stopGeneration,
                        primaryURL: context.primaryURL, segments: context.segments, finalSystemURL: systemURL,
                        binding: bindingLocked(context), terminalDecision: context.decision, allowedRoot: allowedRoot)
    }
    private func outputLocked(_ ticket: Ticket, disposition: RecordingStopFinalizationDisposition) -> FinalizationOutput {
        let snapshot = snapshotLocked(ticket)
        return FinalizationOutput(stopGeneration: ticket.stopGeneration,
            micURL: disposition == .journalRecoveryOwned ? nil : ticket.actualFinalMicURL,
            systemURL: snapshot.finalSystemURL, disposition: disposition)
    }
}
