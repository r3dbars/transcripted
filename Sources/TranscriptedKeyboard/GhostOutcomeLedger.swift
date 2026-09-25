#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif
import Foundation

/// Side-effect recorder next to the IME. It does not change marked text.
///
/// Writes one local file: text-free v3 events. Tilde also kept a plaintext
/// word diary here; Transcripted does not (docs/writing-plan.md). Accepted
/// text lives only in memory, for the 5 s / 30 s / segment-close kept-or-
/// edited checks, and never reaches disk from the keyboard.
enum GhostOutcomeLedger {
    private static let io = DispatchQueue(label: "com.justinbetker.draft.keyboard.outcome-ledger", qos: .utility)
    private static let lock = NSLock()
    private static var opportunity: LiveOnlineOpportunity?
    private static var watches: [PendingRetainedWatch] = []
    private static var lastActivity = Date.distantPast
    private static var contextProvider: (@Sendable () -> String?)?
    private static var excluded = false
    private static var seenGeneration: Int?
    /// Writing volume between ghosts; see `OpportunityCharacterMeter`.
    private static var meter = OpportunityCharacterMeter()

    /// An eligible opportunity the keyboard has asked the app about and not
    /// yet resolved. It becomes a shown opportunity or a silent event; a
    /// newer one arriving first closes it as superseded.
    private struct PendingOpportunity {
        let id: UUID
        let openedAt: Date
        let sessionDigestSHA256: String
        let variant: String
        let hostRegister: ContinuationRegister
        let boundary: String
    }

    private static var pending: PendingOpportunity?

    /// The keyboard is about to ask the app. From here the opportunity ends
    /// exactly once: shown, or silent with a terminal reason.
    static func noteOpportunityOpened(
        id: UUID,
        sessionIdentifier: String,
        hostRegister: ContinuationRegister,
        precedingCharacter: Character?,
        excluded: Bool,
        variant: String = "champion",
        at time: Date = Date()
    ) {
        _ = dropIfWiped()
        noteOpportunityEnded(
            id: pending?.id,
            reason: .supersededByTyping,
            receipt: nil,
            deadlineMissed: true,
            at: time
        )
        lock.lock()
        self.excluded = excluded
        guard !excluded else {
            pending = nil
            meter.reset()
            lock.unlock()
            return
        }
        pending = PendingOpportunity(
            id: id,
            openedAt: time,
            sessionDigestSHA256: TextFreeOnlineEvent.sessionDigest(sessionIdentifier: sessionIdentifier),
            variant: variant,
            hostRegister: hostRegister,
            boundary: TextFreeCursorBoundary.from(precedingCharacter: precedingCharacter).rawValue
        )
        lock.unlock()
    }

    /// The opportunity ended without a ghost. A `nil` or stale `id` is a
    /// no-op, so every path that might have ended it may say so safely.
    /// `receipt` fields are `nil` for an app older than the receipt and for
    /// the keyboard's own verdicts; nothing is guessed in their place.
    static func noteOpportunityEnded(
        id: UUID?,
        reason: SuggestionDecisionReason,
        receipt: GhostDecisionReceipt?,
        deadlineMissed: Bool,
        at time: Date = Date()
    ) {
        guard let id else { return }
        lock.lock()
        guard let open = pending, open.id == id, !excluded else {
            lock.unlock()
            return
        }
        pending = nil
        let opportunityCharacters = meter.takeForOpportunity()
        lastActivity = time
        lock.unlock()
        let register = receipt?.register ?? open.hostRegister
        let digest = receipt?.configurationDigest ?? ServedConfiguration.digest
        let elapsed = Int((max(0, time.timeIntervalSince(open.openedAt)) * 1_000).rounded())
        guard let event = try? TextFreeOnlineEvent.silent(
            id: open.id,
            occurredAt: open.openedAt,
            sessionDigestSHA256: open.sessionDigestSHA256,
            variant: open.variant,
            appCategory: TextFreeAppCategory.from(register: register).rawValue,
            register: register.rawValue,
            boundary: open.boundary,
            reason: receipt?.reason ?? reason,
            generated: receipt?.generated ?? false,
            deadlineMissed: deadlineMissed,
            generatorMilliseconds: receipt?.generatorMilliseconds,
            firstStableWordMilliseconds: receipt?.firstStableWordMilliseconds,
            nextActionMilliseconds: min(300_000, elapsed),
            opportunityCharacters: opportunityCharacters,
            configurationDigestSHA256: digest
        ) else { return }
        append(event: event)
    }

    static func configure(contextProvider: @escaping @Sendable () -> String?) {
        lock.lock()
        self.contextProvider = contextProvider
        meter.reset()
        lock.unlock()
    }

    /// `register` and `source` are the app's receipt for this ghost (or the
    /// dictionary path's own values); the ledger never derives a register
    /// from the host bundle.
    /// `opportunityID` is the pending opportunity this ghost answers, so the
    /// shown event keeps the id the request carried; a dictionary ghost has
    /// no pending opportunity and mints its own.
    static func noteShown(
        opportunityID: UUID?,
        sessionIdentifier: String,
        register: ContinuationRegister,
        source: TextFreeCandidateSource,
        candidateCharacters: Int,
        candidateWordCount: Int,
        precedingCharacter: Character?,
        excluded: Bool,
        variant: String = "champion",
        receipt: GhostDecisionReceipt? = nil,
        at time: Date = Date()
    ) {
        _ = dropIfWiped()
        closeOpenOpportunity(at: time)
        lock.lock()
        self.excluded = excluded
        guard !excluded else {
            opportunity = nil
            pending = nil
            meter.reset()
            lastActivity = time
            lock.unlock()
            return
        }
        let answered = pending.flatMap { open in open.id == opportunityID ? open : nil }
        // A ghost for a different opportunity than the pending one means the
        // pending one was answered by something else first; it is closed as
        // superseded rather than left to dangle.
        if let stale = pending, answered == nil {
            lock.unlock()
            noteOpportunityEnded(
                id: stale.id, reason: .supersededByTyping, receipt: nil, deadlineMissed: true, at: time
            )
            lock.lock()
        }
        pending = nil
        let opportunityCharacters = meter.takeForOpportunity()
        opportunity = LiveOnlineOpportunity(
            id: answered?.id ?? UUID(),
            shownAt: time,
            sessionDigestSHA256: TextFreeOnlineEvent.sessionDigest(
                sessionIdentifier: sessionIdentifier
            ),
            variant: variant,
            appCategory: TextFreeAppCategory.from(register: register).rawValue,
            register: register.rawValue,
            boundary: TextFreeCursorBoundary.from(precedingCharacter: precedingCharacter).rawValue,
            safeOpportunity: !excluded,
            candidateCharacters: candidateCharacters,
            candidateWordCount: candidateWordCount,
            candidateSource: source,
            opportunityCharacters: opportunityCharacters,
            generatorMilliseconds: receipt?.generatorMilliseconds,
            firstStableWordMilliseconds: receipt?.firstStableWordMilliseconds,
            configurationDigestSHA256: receipt?.configurationDigest ?? ServedConfiguration.digest
        )
        lastActivity = time
        lock.unlock()
    }

    /// The app's terminal receipt for the ghost on screen: a streamed
    /// partial opened the record without timings, and the final line has
    /// them. Merged in place; the source stays what the presentation said.
    static func noteReceipt(_ receipt: GhostDecisionReceipt) {
        lock.lock()
        defer { lock.unlock() }
        // A dictionary ghost never borrows a model's timings, even when a
        // rejected model answer arrives while it is on screen.
        guard opportunity?.candidateSource != TextFreeCandidateSource.dictionary.rawValue else { return }
        opportunity?.noteReceipt(
            source: nil,
            generatorMilliseconds: receipt.generatorMilliseconds,
            firstStableWordMilliseconds: receipt.firstStableWordMilliseconds
        )
    }

    /// The model extended a dictionary ghost that was already on screen.
    /// One ghost, one record: the pending model opportunity folds into the
    /// shown record (source becomes the base model, timings fill in) instead
    /// of becoming a second, falsely superseded event.
    static func noteModelExtendedVisibleCandidate(opportunityID: UUID?, receipt: GhostDecisionReceipt?) {
        lock.lock()
        if let opportunityID, let open = pending, open.id == opportunityID {
            pending = nil
            opportunity?.adoptModelOpportunity(
                id: open.id,
                register: receipt?.register ?? open.hostRegister,
                configurationDigestSHA256: receipt?.configurationDigest ?? ServedConfiguration.digest
            )
        }
        opportunity?.noteReceipt(
            source: .baseModel,
            generatorMilliseconds: receipt?.generatorMilliseconds,
            firstStableWordMilliseconds: receipt?.firstStableWordMilliseconds
        )
        lock.unlock()
    }

    static func noteVisibleCandidate(characters: Int, wordCount: Int) {
        lock.lock()
        opportunity?.noteVisibleCandidate(characters: characters, wordCount: wordCount)
        lock.unlock()
    }

    static func noteTyped(at time: Date = Date()) {
        lock.lock()
        meter.noteTyped()
        opportunity?.noteTyped(at: time)
        lastActivity = time
        let stillVisible = opportunity != nil
        lock.unlock()
        if !stillVisible { return }
    }

    static func closeIfGhostGone(stillVisible: Bool, at time: Date = Date()) {
        guard !stillVisible else { return }
        closeOpenOpportunity(at: time)
    }

    static func noteAccepted(
        _ text: String,
        kind: LiveOnlineOpportunity.AcceptKind,
        remainderVisible: Bool,
        at time: Date = Date()
    ) {
        if dropIfWiped() { return }
        lock.lock()
        meter.noteAccepted(characters: text.count)
        opportunity?.noteAccepted(text, kind: kind, at: time)
        lastActivity = time
        let ready = remainderVisible ? nil : opportunity
        if !remainderVisible { opportunity = nil }
        lock.unlock()
        guard let ready, ready.didAccept else { return }
        startWatch(ready)
    }

    static func noteDismissed(at time: Date = Date()) {
        lock.lock()
        opportunity?.noteDismissed(at: time)
        lastActivity = time
        lock.unlock()
        closeOpenOpportunity(at: time)
    }

    static func markPrivacyExcluded() {
        lock.lock()
        excluded = true
        pending = nil
        meter.reset()
        var completed: [PendingRetainedWatch] = []
        for index in watches.indices {
            watches[index].markPrivacyExcluded()
            if watches[index].isComplete {
                completed.append(watches[index])
            }
        }
        watches.removeAll { $0.isComplete }
        let open = opportunity
        opportunity = nil
        lock.unlock()
        if let open, open.didAccept {
            var watch = PendingRetainedWatch(opportunity: open)
            watch.markPrivacyExcluded()
            emit(watch: &watch)
        } else if let open {
            emitWithoutWatch(open)
        }
        for var watch in completed {
            emit(watch: &watch)
        }
    }

    static func closeOpenGhost(at time: Date = Date()) {
        _ = dropIfWiped()
        closeOpenOpportunity(at: time)
    }

    static func closeSegment(at time: Date = Date()) {
        if dropIfWiped() { return }
        closeOpenOpportunity(at: time)
        let window = currentWindow()
        lock.lock()
        var completed: [PendingRetainedWatch] = []
        for index in watches.indices {
            try? watches[index].closeSegment(window: window)
            if watches[index].isComplete {
                completed.append(watches[index])
            }
        }
        watches.removeAll { $0.isComplete }
        meter.reset()
        lastActivity = time
        lock.unlock()
        for var watch in completed {
            emit(watch: &watch)
        }
    }

    static func observeDueHorizons(now: Date = Date()) {
        if dropIfWiped() { return }
        let window = currentWindow()
        lock.lock()
        var completed: [PendingRetainedWatch] = []
        for index in watches.indices {
            let shown = watches[index].opportunity.shownAt
            if now.timeIntervalSince(shown) >= RetainedSpanWatch.fiveSecondHorizon {
                try? watches[index].observeFiveSeconds(window: window)
            }
            if now.timeIntervalSince(shown) >= RetainedSpanWatch.thirtySecondHorizon {
                try? watches[index].observeThirtySeconds(window: window)
            }
            if now.timeIntervalSince(lastActivity) >= RetainedSpanWatch.idleSegmentSeconds {
                try? watches[index].closeSegment(window: window)
            }
            if watches[index].isComplete {
                completed.append(watches[index])
            }
        }
        watches.removeAll { $0.isComplete }
        lock.unlock()
        for var watch in completed {
            emit(watch: &watch)
        }
    }

    private static func startWatch(_ opportunity: LiveOnlineOpportunity) {
        lock.lock()
        if excluded {
            lock.unlock()
            return
        }
        if watches.count >= RetainedSpanWatch.maximumPendingWatches {
            var oldest = watches.removeFirst()
            oldest.stopObserver()
            lock.unlock()
            emit(watch: &oldest)
            lock.lock()
        }
        watches.append(PendingRetainedWatch(opportunity: opportunity))
        lock.unlock()
        scheduleHorizonChecks()
    }

    private static func closeOpenOpportunity(at time: Date) {
        lock.lock()
        var closing = opportunity
        opportunity = nil
        closing?.settleVisible(at: time)
        lock.unlock()
        guard let closing else { return }
        if closing.didAccept {
            startWatch(closing)
            return
        }
        emitWithoutWatch(closing)
    }

    private static func emitWithoutWatch(_ opportunity: LiveOnlineOpportunity) {
        guard let event = try? opportunity.eventWithoutAcceptedSpan() else { return }
        append(event: event)
    }

    private static func emit(watch: inout PendingRetainedWatch) {
        guard let event = try? watch.finishedEvent() else { return }
        append(event: event)
    }

    private static func currentWindow() -> String? {
        lock.lock()
        let provider = contextProvider
        let isExcluded = excluded
        lock.unlock()
        if isExcluded { return nil }
        guard Thread.isMainThread else { return nil }
        return provider?()
    }

    private static func scheduleHorizonChecks() {
        DispatchQueue.main.asyncAfter(deadline: .now() + RetainedSpanWatch.fiveSecondHorizon) {
            observeDueHorizons()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + RetainedSpanWatch.thirtySecondHorizon) {
            observeDueHorizons()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + RetainedSpanWatch.idleSegmentSeconds) {
            observeDueHorizons()
        }
    }

    private static func dropIfWiped() -> Bool {
        let current = UserDefaults.standard.integer(
            forKey: PersonalHistorySettingsContract.outcomeLedgerGenerationKey
        )
        lock.lock()
        defer { lock.unlock() }
        if seenGeneration == nil {
            seenGeneration = current
            return false
        }
        guard seenGeneration != current else { return false }
        seenGeneration = current
        opportunity = nil
        pending = nil
        watches = []
        meter.reset()
        excluded = true
        return true
    }

    private static func append(event: TextFreeOnlineEvent) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let support = TildeProductProfile.current.supportDirectoryName
        let eventURL = TextFreeOnlineEventFile.url(
            homeDirectory: home,
            supportDirectoryName: support
        )
        guard let eventLine = try? TextFreeOnlineEvent.encodeJSONL(event) else { return }
        let generation = UserDefaults.standard.integer(
            forKey: PersonalHistorySettingsContract.outcomeLedgerGenerationKey
        )
        io.async {
            let live = UserDefaults.standard.integer(
                forKey: PersonalHistorySettingsContract.outcomeLedgerGenerationKey
            )
            guard live == generation else { return }
            appendOwnerOnly(eventLine, to: eventURL)
        }
    }

    private static func appendOwnerOnly(_ data: Data, to url: URL) {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(
                atPath: url.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
