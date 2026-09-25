#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif
import Foundation

/// Save my writing inside the app: keyboard events in, Markdown day files
/// out. Gates every batch (Save my writing on, the current history and
/// consent, the app scope), composes entries, and appends each closed entry
/// to `<writing folder>/Writing_<date>.md`. One serial queue owns the composer
/// and every write, so `flush()` at quit and `deleteAll()` never race an
/// append. Not part of Tilde.
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
    private var composer: WritingEntryComposer
    private var rememberedEventIDs: Set<String> = []
    private var rememberedEventOrder: [String] = []
    /// Entries whose append failed, retried on the next write.
    private var unwritten: [WritingEntryComposer.Entry] = []

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
        writeFailed: @escaping @Sendable () -> Void = {}
    ) {
        self.directory = directory
        self.gate = gate
        self.appName = appName
        self.now = now
        self.timeZone = timeZone
        self.locale = locale
        self.didWrite = didWrite
        self.writeFailed = writeFailed
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
        queue.sync { write(composer.closeIdle(now: now())) }
    }

    /// Writes whatever is open. The app calls it at quit.
    func flush() {
        queue.sync { write(composer.closeAll()) }
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
                didWrite(url)
            } catch {
                if unwritten.count < Self.unwrittenLimit { unwritten.append(entry) }
                writeFailed()
            }
        }
    }
}

/// What the socket server ingests: every Personal History batch goes to
/// Tilde's controller (the encrypted log and the predictor) and to the day
/// files. The app scope is re-checked here the way Tilde's app re-checks its
/// exclusions; the keyboard applied it already. Not part of Tilde.
struct WritingHistoryIngest: PersonalHistoryIngesting {
    let personalHistory: any PersonalHistoryIngesting
    let dayFiles: WritingDayFileRecorder
    let appScope: @Sendable () -> WritingAppScope

    func ingest(_ events: [PersonalHistoryEvent]) async -> Bool {
        guard PersonalHistoryEvent.validBatch(events) else { return false }
        let scope = appScope()
        let inScope = events.filter { scope.includes($0.appBundleIdentifier) }
        // Acknowledged and never kept, like an excluded app in Tilde.
        guard !inScope.isEmpty else { return true }
        await dayFiles.ingest(inScope)
        return await personalHistory.ingest(inScope)
    }
}
