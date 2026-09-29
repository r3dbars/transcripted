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
    private static let unwrittenLimit = 32

    private let queue = DispatchQueue(label: "com.justinbetker.draft.writing.day-files", qos: .utility)
    private let directory: @Sendable () -> URL
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
    /// Entries whose append failed, retried on the next write.
    private var unwritten: [WritingEntryComposer.Entry] = []
    /// Its own lock, not the queue: the Writing tab reads it from the main
    /// thread and must not wait behind a slow write.
    private let failureLock = NSLock()
    private var failure: WriteFailure?

    /// `nil` until a write fails, and again once one succeeds. Any thread.
    var lastWriteFailure: WriteFailure? {
        failureLock.withLock { failure }
    }

    /// `writeFailed` runs on every failed append. `writeProblemStarted` runs
    /// once per problem: on the first failure after a success (or before any
    /// write), not again until a write succeeds and another fails.
    /// `releaseToPersonalHistory` gets cleared events in keyboard order, on
    /// the recorder's queue; it must hand them off, not wait on them.
    init(
        directory: @escaping @Sendable () -> URL,
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
    func ingest(_ events: [PersonalHistoryEvent]) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                ingestOnQueue(events)
                continuation.resume()
            }
        }
    }

    /// Writes the open entry once it has been idle for 2 minutes.
    func closeIdleEntries() {
        queue.sync {
            write(composer.closeIdle(now: now()))
            releaseClearedHistory()
        }
    }

    /// Writes whatever is open. The app calls it at quit.
    func flush() {
        queue.sync {
            write(composer.closeAll())
            releaseClearedHistory()
        }
    }

    /// Delete all writing: drops the open entry and anything unwritten, then
    /// removes every `Writing_*.md` in the writing folder.
    @discardableResult
    func deleteAll() -> Bool {
        queue.sync {
            composer.discardOpenEntry()
            unwritten.removeAll()
            rememberedEventIDs.removeAll()
            rememberedEventOrder.removeAll()
            return WritingDayFileStore.deleteAll(in: directory())
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

    private func ingestOnQueue(_ events: [PersonalHistoryEvent]) {
        let gate = gate()
        guard gate.enabled else {
            // Save my writing is off: whatever was open is never written.
            composer.discardOpenEntry()
            return
        }
        var admitted: [PersonalHistoryEvent] = []
        for event in events where gate.admits(
            appBundleIdentifier: event.appBundleIdentifier,
            historyIdentifier: event.historyIdentifier,
            consentIdentifier: event.consentIdentifier
        ) && remember(event.id) {
            admitted.append(event)
        }
        guard !admitted.isEmpty else { return }
        write(composer.ingest(admitted, receivedAt: now()))
        releaseClearedHistory()
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

    private func write(_ entries: [WritingEntryComposer.Entry]) {
        let pending = unwritten + entries
        unwritten.removeAll()
        guard !pending.isEmpty else { return }
        // Re-checked at write time: turning Save my writing off, deleting
        // everything, or narrowing the scope drops what was still open.
        let gate = gate()
        let folder = directory()
        let zone = timeZone()
        for entry in pending where gate.admits(
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
                    in: folder
                )
                failureLock.withLock { failure = nil }
                didWrite(url)
            } catch {
                if unwritten.count < Self.unwrittenLimit { unwritten.append(entry) }
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

    /// `true` once the batch is composed: the keyboard doesn't resend it.
    /// Personal History takes it later, when its entry closes.
    func ingest(_ events: [PersonalHistoryEvent]) async -> Bool {
        guard PersonalHistoryEvent.validBatch(events) else { return false }
        let scope = appScope()
        let inScope = events.filter { scope.includes($0.appBundleIdentifier) }
        // Acknowledged and never kept, like an excluded app in Tilde.
        guard !inScope.isEmpty else { return true }
        await dayFiles.ingest(inScope)
        return true
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
