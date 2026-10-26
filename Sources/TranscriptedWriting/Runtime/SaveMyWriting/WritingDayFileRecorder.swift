#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif
import Foundation

/// Save my writing inside the app: keyboard events in, Markdown day files
/// out. Gates every batch (Save my writing on, the current history and
/// consent, the app scope), composes entries, and appends each closed entry
/// to `<writing folder>/Writing_<date>.md`. It's also the only way into
/// Personal History: the events of each entry that closed with nothing to
/// scrub go to `releaseToPersonalHistory`, and an entry with a secret in it
/// never does. One serial queue owns the composer and every write, so
/// `flush()` at quit and `deleteAll()` never race an append. Not part of
/// Tilde.
final class WritingDayFileRecorder: @unchecked Sendable {
    /// Read fresh for every batch and every write, like Tilde's settings.
    struct Gate: Equatable, Sendable {
        var enabled: Bool
        var historyIdentifier: String?
        var consentIdentifier: String?
        var excludedApps: Set<String>
        var appScope: WritingAppScope

        init(
            enabled: Bool,
            historyIdentifier: String?,
            consentIdentifier: String?,
            excludedApps: Set<String> = [],
            appScope: WritingAppScope = .all
        ) {
            self.enabled = enabled
            self.historyIdentifier = historyIdentifier
            self.consentIdentifier = consentIdentifier
            self.excludedApps = excludedApps
            self.appScope = appScope
        }

        init(preferences: WritingPreferences) {
            let settings = preferences.tildeSettings
            self.init(
                enabled: settings.personalHistoryEnabled,
                historyIdentifier: settings.personalHistoryIdentifier,
                consentIdentifier: settings.personalHistoryConsentIdentifier,
                excludedApps: settings.personalHistoryExcludedApps,
                appScope: preferences.appScope
            )
        }

        func admits(
            appBundleIdentifier: String,
            historyIdentifier: String,
            consentIdentifier: String
        ) -> Bool {
            enabled
                && historyIdentifier == self.historyIdentifier
                && consentIdentifier == self.consentIdentifier
                && appScope.allows(appBundleIdentifier, excludedApps: excludedApps)
        }
    }

    /// The last day-file write that failed: which `StoreError` and when.
    /// Never a path or any text. The Writing tab reads it to say "Writing
    /// couldn't be saved to this folder."
    struct WriteFailure: Equatable, Sendable {
        let error: WritingDayFileStore.StoreError
        let date: Date
    }

    private static let rememberedEventLimit = 512

    /// One storage owner also orders privacy erase while the runtime is absent
    /// before a newly enabled runtime can admit writing. No async blind erase.
    private static let storageQueue = DispatchQueue(label: "com.justinbetker.draft.writing.day-files", qos: .utility)
    private var queue: DispatchQueue { Self.storageQueue }
    private let directory: @Sendable () -> URL
    private let pendingDirectory: @Sendable () -> URL
    private let savePending: @Sendable (WritingPendingEntryStore.Snapshot, URL) throws -> Void
    private let gate: @Sendable () -> Gate
    private let appName: @Sendable (String) -> String?
    private let now: @Sendable () -> Date
    private let timeZone: @Sendable () -> TimeZone
    private let locale: Locale
    private let didWrite: @Sendable (URL) -> Void
    private let writeFailed: @Sendable () -> Void
    private let writeProblemStarted: @Sendable (WritingDayFileStore.StoreError) -> Void
    private let releaseToPersonalHistory: @Sendable ([PersonalHistoryEvent]) -> Void
    private var composer: WritingEntryComposer
    private var rememberedEventIDs: Set<String> = []
    private var rememberedEventOrder: [String] = []
    private var pending = WritingPendingEntryStore.Snapshot()
    private var pendingLoaded = false
    private var accepting = true
    /// Its own lock, not the queue: the Writing tab reads it from the main
    /// thread and must not wait behind a slow write.
    private let failureLock = NSLock()
    private var failure: WriteFailure?

    static func reconcileStoredPrivacy(in directory: URL, gate: Gate,
        failed: @escaping @Sendable () -> Void = {}) {
        storageQueue.async {
            do {
                if !gate.enabled {
                    guard WritingPendingEntryStore.delete(in: directory) else { failed(); return }
                } else {
                    var snapshot = try WritingPendingEntryStore.load(in: directory)
                    guard WritingPendingEntryStore.removeInterruptedWrites(in: directory) else { failed(); return }
                    let prior = snapshot.entries
                    snapshot.entries.removeAll {
                        !gate.admits(appBundleIdentifier: $0.appBundleIdentifier,
                                     historyIdentifier: $0.historyIdentifier, consentIdentifier: $0.consentIdentifier)
                    }
                    let receipts = snapshot.receipts
                    snapshot.receipts.removeAll {
                        !gate.admits(appBundleIdentifier: $0.appBundleIdentifier,
                                     historyIdentifier: $0.historyIdentifier, consentIdentifier: $0.consentIdentifier)
                    }
                    if prior != snapshot.entries || receipts != snapshot.receipts {
                        try WritingPendingEntryStore.save(snapshot, in: directory)
                    }
                }
            } catch { failed() }
        }
    }

    static func deleteStoredWriting(in directory: URL, pendingDirectory: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            storageQueue.async {
                let pendingDeleted = WritingPendingEntryStore.delete(in: pendingDirectory)
                continuation.resume(returning: WritingDayFileStore.deleteAll(in: directory) && pendingDeleted)
            }
        }
    }

    /// Cleared only after ALL admitted pending entries have reached day files.
    var lastWriteFailure: WriteFailure? {
        failureLock.withLock { failure }
    }

    /// `writeFailed` runs on every failed append. `writeProblemStarted` runs
    /// once per problem: on the first failure after a success (or before any
    /// write), not again until every pending entry is resolved and another fails.
    /// `releaseToPersonalHistory` gets cleared events in keyboard order, on
    /// the recorder's queue; it must hand them off, not wait on them.
    init(
        directory: @escaping @Sendable () -> URL,
        pendingDirectory: @escaping @Sendable () -> URL,
        savePending: @escaping @Sendable (WritingPendingEntryStore.Snapshot, URL) throws -> Void = {
            try WritingPendingEntryStore.save($0, in: $1)
        },
        gate: @escaping @Sendable () -> Gate,
        appName: @escaping @Sendable (String) -> String?,
        now: @escaping @Sendable () -> Date = { Date() },
        timeZone: @escaping @Sendable () -> TimeZone = { .current },
        locale: Locale = .current,
        entryIDSuffix: @escaping @Sendable () -> String = {
            String(format: "%08x", UInt32.random(in: .min ... .max))
        },
        didWrite: @escaping @Sendable (URL) -> Void = { _ in },
        writeFailed: @escaping @Sendable () -> Void = {},
        writeProblemStarted: @escaping @Sendable (WritingDayFileStore.StoreError) -> Void = { _ in },
        releaseToPersonalHistory: @escaping @Sendable ([PersonalHistoryEvent]) -> Void = { _ in }
    ) {
        self.directory = directory
        self.pendingDirectory = pendingDirectory
        self.savePending = savePending
        self.gate = gate
        self.appName = appName
        self.now = now
        self.timeZone = timeZone
        self.locale = locale
        self.didWrite = didWrite
        self.writeFailed = writeFailed
        self.writeProblemStarted = writeProblemStarted
        self.releaseToPersonalHistory = releaseToPersonalHistory
        composer = WritingEntryComposer { milliseconds in
            WritingDayFileFormatter.entryID(
                forMilliseconds: milliseconds,
                hexSuffix: entryIDSuffix(),
                timeZone: timeZone()
            )
        }
    }

    /// A batch from the keyboard. A retried batch is recognized by its event
    /// IDs and not composed twice.
    @discardableResult
    func ingest(_ events: [PersonalHistoryEvent]) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            queue.async { [self] in
                continuation.resume(returning: ingestOnQueue(events))
            }
        }
    }

    /// Writes the open entry once it has been idle for 2 minutes.
    func closeIdleEntries() {
        queue.sync {
            guard preparePending() else { return }
            var next = composer
            if admit(next.closeIdle(now: now())) {
                composer = next
                releaseClearedHistory()
            }
            publishPending()
        }
    }

    /// Writes whatever is open. The app calls it at quit.
    @discardableResult
    func flush(sealForTermination: Bool = false) -> Bool {
        queue.sync {
            if !accepting { return true }
            guard preparePending() else { return false }
            publishPending()
            guard pendingLoaded else { return false }
            var next = composer
            guard admit(next.closeAll()) else { return false }
            composer = next
            releaseClearedHistory()
            publishPending()
            if sealForTermination { accepting = false }
            // The library may still be offline; the journal now owns every
            // closed entry. Open raw text has never been persisted.
            return true
        }
    }

    /// Quit goes on without a durable flush. Later batches are refused, so the
    /// keyboard keeps them; nothing waits on a library that may be stuck.
    func sealWithoutFlush() {
        queue.async { self.accepting = false }
    }

    /// Delete all writing: drops the open entry and anything unwritten, then
    /// removes every `Writing_*.md` in the writing folder.
    @discardableResult
    func deleteAll() -> Bool {
        queue.sync {
            composer.discardOpenEntry()
            pending = .init()
            pendingLoaded = false
            rememberedEventIDs.removeAll()
            rememberedEventOrder.removeAll()
            let removedPending = WritingPendingEntryStore.delete(in: pendingDirectory())
            if removedPending { failureLock.withLock { failure = nil } }
            return WritingDayFileStore.deleteAll(in: directory()) && removedPending
        }
    }

    /// Scrubs day files an older build wrote (`WritingDayFileRescrubber`).
    /// Each file on the same queue as appends, one at a time, so it never
    /// races an append and keyboard batches wait at most one file. Stops
    /// between files once `shouldContinue` says so (Writing stopping). Each
    /// rewritten file is announced through `didWrite`, like an append.
    @discardableResult
    func rescrubExistingDayFiles(
        shouldContinue: () -> Bool = { true }
    ) -> WritingDayFileRescrubber.Outcome {
        let folder = directory()
        var outcome = WritingDayFileRescrubber.Outcome()
        for name in WritingDayFileStore.dayFileNames(in: folder) {
            guard shouldContinue() else {
                outcome.failures += 1
                break
            }
            let result = queue.sync {
                WritingDayFileRescrubber.rescrub(dayFile: name, in: folder, timeZone: timeZone(), locale: locale)
            }
            outcome.record(result)
            if case let .changed(url) = result { didWrite(url) }
        }
        return outcome
    }

    private func ingestOnQueue(_ events: [PersonalHistoryEvent]) -> Bool {
        guard accepting else { return false }
        let gate = gate()
        guard gate.enabled else {
            // Save my writing is off: whatever was open is never written.
            composer.discardOpenEntry()
            return discardPendingForPrivacy()
        }
        guard preparePending() else { return false }
        publishPending()
        guard pendingLoaded else { return false }
        var admitted: [PersonalHistoryEvent] = []
        for event in events where gate.admits(
            appBundleIdentifier: event.appBundleIdentifier,
            historyIdentifier: event.historyIdentifier,
            consentIdentifier: event.consentIdentifier
        ) && !rememberedEventIDs.contains(event.id) && !admitted.contains(where: { $0.id == event.id }) {
            admitted.append(event)
        }
        guard !admitted.isEmpty else { publishPending(); return true }
        // Refusal must leave composer and dedup state unchanged: the keyboard
        // retains this batch and can resend it after storage/capacity recovers.
        var next = composer
        guard admit(next.ingest(admitted, receivedAt: now())) else { return false }
        composer = next
        for event in admitted { _ = remember(event.id) }
        releaseClearedHistory()
        publishPending()
        return true
    }

    /// Hands Personal History the events of entries that closed clean,
    /// re-checked against the gate like a write: turning Save my writing off
    /// or narrowing the scope drops them here too.
    private func releaseClearedHistory() {
        let cleared = composer.takeClearedHistory()
        guard !cleared.isEmpty else { return }
        let gate = gate()
        let admitted = cleared.filter {
            gate.admits(
                appBundleIdentifier: $0.appBundleIdentifier,
                historyIdentifier: $0.historyIdentifier,
                consentIdentifier: $0.consentIdentifier
            )
        }
        guard !admitted.isEmpty else { return }
        releaseToPersonalHistory(admitted)
    }

    private func remember(_ eventID: String) -> Bool {
        guard rememberedEventIDs.insert(eventID).inserted else { return false }
        rememberedEventOrder.append(eventID)
        if rememberedEventOrder.count > Self.rememberedEventLimit {
            rememberedEventIDs.remove(rememberedEventOrder.removeFirst())
        }
        return true
    }

    /// Load once, refuse unreadable/corrupt ownership rather than overwrite it,
    /// and durably discard pending entries no longer covered by consent/scope.
    private func preparePending(for privacyGate: Gate? = nil) -> Bool {
        do {
            if !pendingLoaded {
                pending = try WritingPendingEntryStore.load(in: pendingDirectory())
                guard WritingPendingEntryStore.removeInterruptedWrites(in: pendingDirectory()) else {
                    throw WritingDayFileStore.StoreError.pendingStoreUnavailable
                }
                pendingLoaded = true
                composer.reconcileOwnedOpenEntry(pending.entries)
                for receipt in pending.receipts { _ = remember(receipt.eventID) }
            }
            let current = privacyGate ?? gate()
            composer.discardOpenEntryUnlessAdmitted {
                current.admits(appBundleIdentifier: $0, historyIdentifier: $1, consentIdentifier: $2)
            }
            let entries = pending.entries.filter {
                current.admits(appBundleIdentifier: $0.appBundleIdentifier,
                               historyIdentifier: $0.historyIdentifier, consentIdentifier: $0.consentIdentifier)
            }
            let receipts = pending.receipts.filter {
                current.admits(appBundleIdentifier: $0.appBundleIdentifier,
                               historyIdentifier: $0.historyIdentifier, consentIdentifier: $0.consentIdentifier)
            }
            if entries != pending.entries || receipts != pending.receipts {
                var next = pending
                next.entries = entries
                next.receipts = receipts
                try persist(next)
                if pending.entries.isEmpty { failureLock.withLock { failure = nil } }
            }
            return true
        } catch { noteFailure(error); return false }
    }

    /// Only scrubbed closed entries cross this durable boundary. A normal open
    /// entry stays memory-only until it closes, preserving split-secret checks.
    private func admit(_ entries: [WritingEntryComposer.Entry]) -> Bool {
        let current = gate()
        let admitted = entries.filter {
            current.admits(appBundleIdentifier: $0.appBundleIdentifier,
                           historyIdentifier: $0.historyIdentifier, consentIdentifier: $0.consentIdentifier)
        }
        // Entry IDs, unlike text, are stable across a retry of the same composer.
        let additions = admitted.filter { entry in !pending.entries.contains { $0.entryID == entry.entryID } }
        guard !additions.isEmpty else { return true }
        var next = pending
        next.entries += additions
        for entry in additions {
            next.receipts += entry.eventIDs.map {
                WritingPendingEntryStore.Receipt(eventID: $0, appBundleIdentifier: entry.appBundleIdentifier,
                    historyIdentifier: entry.historyIdentifier, consentIdentifier: entry.consentIdentifier)
            }
        }
        next.receipts = Array(next.receipts.suffix(Self.rememberedEventLimit))
        do { try persist(next); return true }
        catch { noteFailure(error); return false }
    }

    private func persist(_ next: WritingPendingEntryStore.Snapshot) throws {
        do {
            try savePending(next, pendingDirectory())
            pending = next
        } catch {
            // A rename may have succeeded before directory sync failed. Reload
            // before retry so that uncertain ownership cannot be overwritten.
            pendingLoaded = false
            throw error
        }
    }

    @discardableResult
    func reconcilePrivacy() -> Bool {
        queue.sync {
            if !gate().enabled { composer.discardOpenEntry(); return discardPendingForPrivacy() }
            return preparePending()
        }
    }

    /// Enqueue the captured privacy decision before subsequent admissions,
    /// without making a Settings action wait behind filesystem recovery.
    func enqueuePrivacyReconciliation() {
        let captured = gate()
        queue.async { [self] in
            if !captured.enabled { composer.discardOpenEntry(); _ = discardPendingForPrivacy() }
            else { _ = preparePending(for: captured) }
        }
    }

    private func discardPendingForPrivacy() -> Bool {
        guard WritingPendingEntryStore.delete(in: pendingDirectory()) else {
            noteFailure(WritingDayFileStore.StoreError.pendingStoreUnavailable)
            return false
        }
        pending = .init()
        pendingLoaded = true
        failureLock.withLock { failure = nil }
        return true
    }

    private func publishPending() {
        let gate = gate()
        let folder = directory()
        let zone = timeZone()
        var next = pending
        for entry in pending.entries where gate.admits(
            appBundleIdentifier: entry.appBundleIdentifier,
            historyIdentifier: entry.historyIdentifier,
            consentIdentifier: entry.consentIdentifier
        ) {
            let section = WritingDayFileFormatter.section(
                WritingDayFileFormatter.Section(
                    entryID: entry.entryID,
                    capturedAtMilliseconds: entry.capturedAtMilliseconds,
                    sourceAppName: appName(entry.appBundleIdentifier) ?? "Unknown",
                    bundleIdentifier: entry.appBundleIdentifier,
                    wordCount: entry.wordCount,
                    characterCount: entry.characterCount,
                    acceptedWordCount: entry.acceptedWordCount,
                    text: entry.text
                ),
                timeZone: zone,
                locale: locale
            )
            do {
                let url = try WritingDayFileStore.append(
                    section: section,
                    header: WritingDayFileFormatter.dayHeader(
                        forMilliseconds: entry.capturedAtMilliseconds,
                        timeZone: zone,
                        locale: locale
                    ),
                    fileName: WritingDayFileFormatter.fileName(
                        forMilliseconds: entry.capturedAtMilliseconds,
                        timeZone: zone
                    ),
                    in: folder,
                    entryID: entry.entryID
                )
                next.entries.removeAll { $0.entryID == entry.entryID }
                didWrite(url)
            } catch {
                noteFailure(error)
            }
        }
        if next.entries != pending.entries {
            do { try persist(next) }
            catch { noteFailure(error); return }
        }
        if pending.entries.isEmpty { failureLock.withLock { failure = nil } }
    }

    private func noteFailure(_ error: Error) {
        let storeError = error as? WritingDayFileStore.StoreError ?? .writeFailed
        let startsProblem = failureLock.withLock { () -> Bool in
            let starts = failure == nil
            failure = WriteFailure(error: storeError, date: now())
            return starts
        }
        if startsProblem { writeProblemStarted(storeError) }
        writeFailed()
    }
}

/// What the socket server ingests. Every batch goes to the day files'
/// recorder, which is also the way into Tilde's controller (the encrypted
/// log and the predictor): an entry reaches it once it has closed with
/// nothing to scrub (`WritingDayFileRecorder`, `PersonalHistoryRelay`).
/// In Tilde a batch went to the controller as it arrived. The app scope is
/// re-checked here the way Tilde's app re-checks its exclusions; the
/// keyboard applied it already. Not part of Tilde.
struct WritingHistoryIngest: PersonalHistoryIngesting {
    let dayFiles: WritingDayFileRecorder
    let appScope: @Sendable () -> WritingAppScope

    /// `true` once composed; any entries closed by this batch have durable
    /// ownership. Open raw text is still memory-only. The keyboard won't resend.
    /// Personal History takes it later, when its entry closes.
    func ingest(_ events: [PersonalHistoryEvent]) async -> Bool {
        guard PersonalHistoryEvent.validBatch(events) else { return false }
        let scope = appScope()
        let inScope = events.filter { scope.includes($0.appBundleIdentifier) }
        // Acknowledged and never kept, like an excluded app in Tilde.
        guard !inScope.isEmpty else { return true }
        return await dayFiles.ingest(inScope)
    }

    /// Unlike a terminal invalid request, valid storage backpressure is
    /// retryable. The keyboard must not abandon it after 12 error replies.
    func recordingResponse(_ events: [PersonalHistoryEvent]) async -> GhostBrainResponse {
        guard PersonalHistoryEvent.validBatch(events) else { return .error }
        return await ingest(events) ? .recorded : .unavailable
    }
}

/// Hands the events Save my writing cleared to Personal History, in the
/// order they cleared, in batches the controller takes. A batch the
/// controller refuses (storage down) is not retried: the controller's
/// storage health already shows it isn't saving. Not part of Tilde.
final class PersonalHistoryRelay: @unchecked Sendable {
    private let personalHistory: any PersonalHistoryIngesting
    private let lock = NSLock()
    private var tail = OrderedAsyncTaskTail()

    init(personalHistory: any PersonalHistoryIngesting) {
        self.personalHistory = personalHistory
    }

    /// Returns at once; the batches go out in call order.
    func send(_ events: [PersonalHistoryEvent]) {
        let batches = Self.batches(events)
        guard !batches.isEmpty else { return }
        let personalHistory = personalHistory
        lock.withLock {
            _ = tail.enqueue {
                for batch in batches { _ = await personalHistory.ingest(batch) }
            }
        }
    }

    /// Waits until everything sent so far has been handed over.
    func drain() async {
        let marker = lock.withLock { tail.enqueue {} }
        _ = await marker.result
    }

    /// Consecutive batches the controller accepts, in order.
    private static func batches(_ events: [PersonalHistoryEvent]) -> [[PersonalHistoryEvent]] {
        var batches: [[PersonalHistoryEvent]] = []
        var remaining = events[...]
        while !remaining.isEmpty {
            let batch = PersonalHistoryEvent.boundedBatchPrefix(Array(remaining))
            // Every event fits a batch on its own; this only guards the loop.
            guard !batch.isEmpty else { break }
            batches.append(batch)
            remaining = remaining.dropFirst(batch.count)
        }
        return batches
    }
}
