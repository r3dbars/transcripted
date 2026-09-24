import SwiftUI

/// One row of the Corrections editor as the past-meetings line sees it:
/// the row's id, and its correction when it is finished and active.
struct DictionaryPastMeetingsRow: Equatable {
    let id: UUID
    let entry: CustomDictionaryEntry?
}

/// A recent fix whose correction is no longer in the list.
struct DictionaryPastMeetingsEarlierFix: Identifiable, Equatable {
    let entry: CustomDictionaryEntry
    let meetings: Int

    var id: CustomDictionaryEntry { entry }
}

/// Tracks which Settings corrections still match saved meetings, and runs the
/// "Fix them" / "Undo" actions for the line under each correction.
///
/// Counting runs off the main actor after typing pauses, and a newer count
/// stops an older one. Until it finishes, each line keeps showing what it
/// showed for the row's last counted correction (with Fix disabled), so
/// typing never makes the list jump. Fix results are kept per row, so
/// editing a correction right after fixing it doesn't lose its Undo, and
/// they are also saved with the backups, so Undo is still offered after the
/// app relaunches.
@MainActor
final class DictionaryPastMeetingsModel: ObservableObject {
    enum LineState: Equatable {
        /// `note` says what just happened. `retry` means this fix was already
        /// confirmed, so the button runs it again without asking.
        case found(meetings: Int, note: String?, retry: Bool)
        case fixing
        case fixed(count: Int, remaining: Int, note: String?)
        case undoing
        case note(String)
        case earlierFix(DictionaryPastMeetingsEarlierFix)
    }

    private enum Action {
        case fixing
        case fixed([DictionaryPastMeetingFixReceipt], note: String?)
        case undoing
        case note(String, retry: Bool)
    }

    /// The last finished count, and which correction each row had when it
    /// started.
    private struct Counted: Equatable {
        var rowEntries: [UUID: CustomDictionaryEntry?] = [:]
        var scans: [CustomDictionaryEntry: DictionaryPastMeetingScan] = [:]
    }

    @Published private var counted = Counted()
    @Published private var actions: [UUID: Action] = [:]
    /// Recent fixes loaded from disk (and added this session), by correction.
    @Published private var recentFixes: [CustomDictionaryEntry: [DictionaryPastMeetingFixReceipt]] = [:]
    @Published private var undoingEarlierFixes: Set<CustomDictionaryEntry> = []

    private var rows: [DictionaryPastMeetingsRow] = []
    private var scanTask: Task<Void, Never>?
    private var scanToken: ScanCancellationToken?
    private let textCache = DictionaryPastMeetingTextCache()
    private let meetingsDirectory: @Sendable () -> URL
    private let backups: @Sendable () -> DictionaryPastMeetingBackupStore

    init(
        meetingsDirectory: @escaping @Sendable () -> URL = { MeetingStoragePaths.transcriptsFolder },
        backups: @escaping @Sendable () -> DictionaryPastMeetingBackupStore = { .default() }
    ) {
        self.meetingsDirectory = meetingsDirectory
        self.backups = backups
    }

    private var activeEntries: [CustomDictionaryEntry] {
        rows.compactMap(\.entry)
    }

    /// The row's correction as of the last finished count.
    private func countedEntry(for row: DictionaryPastMeetingsRow) -> CustomDictionaryEntry? {
        counted.rowEntries[row.id] ?? nil
    }

    // MARK: - State for the view

    /// True while the row's correction changed and hasn't been counted yet.
    func isPending(_ row: DictionaryPastMeetingsRow) -> Bool {
        countedEntry(for: row) != row.entry
    }

    func lineState(for row: DictionaryPastMeetingsRow) -> LineState? {
        let entry = countedEntry(for: row)
        let remaining = entry.flatMap { counted.scans[$0]?.meetingCount } ?? 0
        switch actions[row.id] {
        case .fixing:
            return .fixing
        case .undoing:
            return .undoing
        case .fixed(let receipts, let note):
            return .fixed(count: receipts.reduce(0) { $0 + $1.fixedCount }, remaining: remaining, note: note)
        case .note(let text, let retry):
            return remaining > 0 ? .found(meetings: remaining, note: text, retry: retry) : .note(text)
        case nil:
            if let entry, let receipts = recentFixes[entry], !receipts.isEmpty {
                return .fixed(count: receipts.reduce(0) { $0 + $1.fixedCount }, remaining: remaining, note: nil)
            }
            return remaining > 0 ? .found(meetings: remaining, note: nil, retry: false) : nil
        }
    }

    /// The count behind the confirm step, only when it is current.
    func scan(for row: DictionaryPastMeetingsRow) -> DictionaryPastMeetingScan? {
        guard !isPending(row), let entry = row.entry else { return nil }
        return counted.scans[entry]
    }

    private var receiptIDsShownOnRows: Set<String> {
        var ids = Set<String>()
        for case .fixed(let receipts, _) in actions.values {
            ids.formUnion(receipts.map(\.id))
        }
        return ids
    }

    /// Recent fixes whose correction was edited or removed, so no row shows
    /// their Undo. They're listed under the corrections so a bad fix can
    /// still be put back after the rule changes or the app relaunches.
    var earlierFixes: [DictionaryPastMeetingsEarlierFix] {
        let shownEntries = Set(rows.compactMap(countedEntry(for:)))
        let shownIDs = receiptIDsShownOnRows
        return recentFixes
            .filter { entry, _ in !shownEntries.contains(entry) && !undoingEarlierFixes.contains(entry) }
            .compactMap { entry, receipts -> DictionaryPastMeetingsEarlierFix? in
                let hidden = receipts.filter { !shownIDs.contains($0.id) }
                let meetings = hidden.reduce(0) { $0 + $1.fixedCount }
                return meetings > 0 ? DictionaryPastMeetingsEarlierFix(entry: entry, meetings: meetings) : nil
            }
            .sorted { $0.entry.spoken.localizedCaseInsensitiveCompare($1.entry.spoken) == .orderedAscending }
    }

    /// Undo for an entry from `earlierFixes`.
    func undoEarlierFix(_ entry: CustomDictionaryEntry) {
        let shownIDs = receiptIDsShownOnRows
        let receipts = (recentFixes[entry] ?? []).filter { !shownIDs.contains($0.id) }
        guard !receipts.isEmpty, undoingEarlierFixes.insert(entry).inserted else { return }
        runUndo(receipts, rowID: nil) { [weak self] in
            self?.undoingEarlierFixes.remove(entry)
        }
    }

    // MARK: - Inputs

    /// The Corrections sheet opened: start fresh, reload fixes that can still
    /// be undone from disk, and count right away.
    func sheetOpened(rows: [DictionaryPastMeetingsRow]) {
        actions = actions.filter { _, action in
            if case .fixing = action { return true }
            if case .undoing = action { return true }
            return false
        }
        let backups = self.backups
        let meetingsDirectory = self.meetingsDirectory
        Task { [weak self] in
            let receipts = await Task.detached(priority: .utility) {
                backups().recentReceipts(meetingsDirectory: meetingsDirectory())
            }.value
            guard let self else { return }
            self.recentFixes = Dictionary(grouping: receipts, by: \.entry)
        }
        update(rows: rows, delay: .zero)
    }

    /// Rows changed. Recounts after `delay`; a newer call cancels an older one.
    func update(rows: [DictionaryPastMeetingsRow], delay: Duration = .milliseconds(600)) {
        let rowsChanged = rows != self.rows
        self.rows = rows
        let ids = Set(rows.map(\.id))
        if actions.keys.contains(where: { !ids.contains($0) }) {
            actions = actions.filter { ids.contains($0.key) }
        }
        if rowsChanged || delay == .zero {
            scheduleScan(delay: delay)
        }
    }

    private func scheduleScan(delay: Duration) {
        scanTask?.cancel()
        scanToken?.cancel()
        let token = ScanCancellationToken()
        scanToken = token
        let entries = activeEntries
        let rowEntries = Dictionary(rows.map { ($0.id, $0.entry) }, uniquingKeysWith: { first, _ in first })
        let meetingsDirectory = self.meetingsDirectory
        let cache = textCache
        scanTask = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !token.isCancelled else { return }
            let result = await Task.detached(priority: .utility) {
                DictionaryPastMeetingFix.scan(entries: entries, in: meetingsDirectory(), cache: cache) {
                    token.isCancelled
                }
            }.value
            guard let self, !token.isCancelled else { return }
            let next = Counted(rowEntries: rowEntries, scans: result)
            if self.counted != next {
                self.counted = next
            }
        }
    }

    // MARK: - Actions

    func fix(row: DictionaryPastMeetingsRow) {
        guard let entry = row.entry, !isPending(row),
              let urls = counted.scans[entry]?.meetingURLs, !urls.isEmpty else { return }
        let earlier = currentReceipts(for: row)
        actions[row.id] = .fixing
        let allEntries = activeEntries
        let backups = self.backups
        Task { [weak self] in
            let receipt = await Task.detached(priority: .userInitiated) {
                DictionaryPastMeetingFix.fix(entry, allEntries: allEntries, meetingsAt: urls, backups: backups())
            }.value
            guard let self else { return }
            if receipt.fixedCount > 0 {
                CaptureLibraryChangeBroadcaster.shared.noteArtifactsChanged(
                    transcriptURLs: receipt.changes.map { URL(fileURLWithPath: $0.path) }
                )
                self.remember([receipt])
                // Drop the fixed meetings from the count now, so the line
                // doesn't say "more couldn't be changed" until the recount.
                if let scan = self.counted.scans[entry] {
                    let changed = Set(receipt.changes.map(\.path))
                    let left = scan.meetingURLs.filter { !changed.contains($0.path) }
                    self.counted.scans[entry] = left.isEmpty
                        ? nil
                        : DictionaryPastMeetingScan(meetingURLs: left, spotCount: scan.spotCount)
                }
            }
            if self.rows.contains(where: { $0.id == row.id }) {
                if let note = DictionaryPastMeetingFixCopy.fixOutcomeNote(receipt), earlier.isEmpty {
                    self.actions[row.id] = .note(note, retry: receipt.skippedCount > 0)
                } else {
                    let receipts = receipt.fixedCount > 0 ? [receipt] + earlier : earlier
                    self.actions[row.id] = .fixed(receipts, note: nil)
                }
            }
            self.scheduleScan(delay: .zero)
        }
    }

    func undo(row: DictionaryPastMeetingsRow) {
        let receipts = currentReceipts(for: row)
        guard !receipts.isEmpty else { return }
        runUndo(receipts, rowID: row.id)
    }

    private func runUndo(
        _ receipts: [DictionaryPastMeetingFixReceipt],
        rowID: UUID?,
        completion: (@MainActor () -> Void)? = nil
    ) {
        if let rowID {
            actions[rowID] = .undoing
        }
        let backups = self.backups
        let meetingsDirectory = self.meetingsDirectory
        Task { [weak self] in
            let results = await Task.detached(priority: .userInitiated) { () -> [DictionaryPastMeetingUndoResult] in
                let store = backups()
                let directory = meetingsDirectory()
                // Newest first, so stacked fixes unwind in order.
                return receipts.map { DictionaryPastMeetingFix.undo($0, meetingsDirectory: directory, backups: store) }
            }.value
            guard let self else { return }
            let result = DictionaryPastMeetingUndoResult(
                restoredURLs: results.flatMap(\.restoredURLs),
                keptCount: results.reduce(0) { $0 + $1.keptCount },
                missingBackupCount: results.reduce(0) { $0 + $1.missingBackupCount },
                busyCount: results.reduce(0) { $0 + $1.busyCount }
            )
            let leftovers = results.compactMap(\.remaining)
            if !result.restoredURLs.isEmpty {
                CaptureLibraryChangeBroadcaster.shared.noteArtifactsChanged(
                    transcriptURLs: result.restoredURLs
                )
            }
            let undoneIDs = Set(receipts.map(\.id))
            self.recentFixes = self.recentFixes
                .mapValues { $0.filter { !undoneIDs.contains($0.id) } }
                .filter { !$0.value.isEmpty }
            // Busy meetings keep their backups, so their Undo stays.
            self.remember(leftovers)
            if let rowID, self.rows.contains(where: { $0.id == rowID }) {
                let note = DictionaryPastMeetingFixCopy.undone(result)
                if !leftovers.isEmpty {
                    self.actions[rowID] = .fixed(leftovers, note: note)
                } else if let note {
                    self.actions[rowID] = .note(note, retry: false)
                } else {
                    self.actions[rowID] = nil
                }
            }
            completion?()
            self.scheduleScan(delay: .zero)
        }
    }

    /// Adds fixes to `recentFixes`, newest first, replacing any with the same id.
    private func remember(_ receipts: [DictionaryPastMeetingFixReceipt]) {
        for receipt in receipts.reversed() {
            var list = recentFixes[receipt.entry] ?? []
            list.removeAll { $0.id == receipt.id }
            list.insert(receipt, at: 0)
            recentFixes[receipt.entry] = list
        }
    }

    private func currentReceipts(for row: DictionaryPastMeetingsRow) -> [DictionaryPastMeetingFixReceipt] {
        if case .fixed(let receipts, _) = actions[row.id] {
            return receipts
        }
        if actions[row.id] == nil, let entry = countedEntry(for: row) {
            return recentFixes[entry] ?? []
        }
        return []
    }
}

/// Lets a newer count stop an older one that is already reading files on a
/// background thread.
private final class ScanCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// The quiet line under one correction in the Corrections editor.
struct DictionaryPastMeetingsLine: View {
    let state: DictionaryPastMeetingsModel.LineState
    /// The correction is being recounted, so Fix waits for the new count.
    var isPending = false
    let onFix: () -> Void
    let onUndo: () -> Void

    private struct LineAction {
        let title: String
        let identifier: String
        var isEnabled = true
        let run: () -> Void
    }

    var body: some View {
        HStack(spacing: 8) {
            leadingGlyph
                .frame(width: 14)
            Text(message)
                .font(LibraryTokens.meta)
                .foregroundStyle(LibraryTokens.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            ForEach(actions, id: \.identifier) { action in
                Button(action.title, action: action.run)
                    .buttonStyle(.plain)
                    .font(LibraryTokens.meta.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 28)
                    .background(
                        RoundedRectangle(cornerRadius: LibraryTokens.radiusControl, style: .continuous)
                            .fill(LibraryTokens.rowHover)
                    )
                    .contentShape(Rectangle())
                    .disabled(!action.isEnabled)
                    .opacity(action.isEnabled ? 1 : 0.5)
                    .accessibilityIdentifier(action.identifier)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minHeight: LibraryTokens.minimumHitTarget)
        .background(
            RoundedRectangle(cornerRadius: LibraryTokens.radiusControl, style: .continuous)
                .fill(LibraryTokens.raisedFill)
        )
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var leadingGlyph: some View {
        switch state {
        case .fixing, .undoing:
            ProgressView().controlSize(.mini)
        case .fixed, .earlierFix:
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(LibraryTokens.ink2)
        case .found, .note:
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 11))
                .foregroundStyle(LibraryTokens.ink3)
        }
    }

    private var message: String {
        switch state {
        case .found(let meetings, let note, _):
            let found = DictionaryPastMeetingFixCopy.found(meetings)
            return note.map { "\($0) \(found)" } ?? found
        case .fixing:
            return DictionaryPastMeetingFixCopy.fixing
        case .fixed(let count, let remaining, let note):
            return note ?? DictionaryPastMeetingFixCopy.fixed(count: count, remaining: remaining)
        case .undoing:
            return DictionaryPastMeetingFixCopy.undoing
        case .note(let text):
            return text
        case .earlierFix(let fix):
            return DictionaryPastMeetingFixCopy.earlierFix(fix.entry, meetings: fix.meetings)
        }
    }

    private var actions: [LineAction] {
        let fixID = "transcripted.settings.general.corrections.fix-past-meetings"
        let undoID = "transcripted.settings.general.corrections.undo-past-meetings"
        switch state {
        case .found(let meetings, _, let retry):
            let title = retry ? DictionaryPastMeetingFixCopy.retryAction : DictionaryPastMeetingFixCopy.fixAction(meetings)
            return [LineAction(title: title, identifier: fixID, isEnabled: !isPending, run: onFix)]
        case .fixed(_, let remaining, let note):
            var actions = [LineAction(title: DictionaryPastMeetingFixCopy.undoAction, identifier: undoID, run: onUndo)]
            // A note here is about an unfinished Undo; Undo itself is the retry.
            if remaining > 0, note == nil {
                actions.append(LineAction(title: DictionaryPastMeetingFixCopy.retryAction, identifier: fixID, isEnabled: !isPending, run: onFix))
            }
            return actions
        case .earlierFix:
            return [LineAction(title: DictionaryPastMeetingFixCopy.undoAction, identifier: undoID, run: onUndo)]
        case .fixing, .undoing, .note:
            return []
        }
    }
}
