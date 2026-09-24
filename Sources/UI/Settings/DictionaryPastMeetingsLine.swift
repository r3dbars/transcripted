import SwiftUI

/// One row of the Corrections editor as the past-meetings line sees it:
/// the row's id, and its correction when it is finished and active.
struct DictionaryPastMeetingsRow: Equatable {
    let id: UUID
    let entry: CustomDictionaryEntry?
}

/// Tracks which Settings corrections still match saved meetings, and runs the
/// "Fix them" / "Undo" actions for the line under each correction.
///
/// Counting runs off the main actor after typing pauses, and a newer count
/// stops an older one. While it runs the line keeps showing the last result
/// for unchanged corrections and shows nothing for new ones, so typing never
/// makes the list flicker. Fix results are kept per row, so editing a
/// correction right after fixing it doesn't lose its Undo, and they are also
/// saved with the backups, so Undo is still offered after the app relaunches.
@MainActor
final class DictionaryPastMeetingsModel: ObservableObject {
    enum LineState: Equatable {
        case found(meetings: Int, note: String?)
        case fixing
        case fixed(count: Int, remaining: Int)
        case undoing
        case note(String)
    }

    private enum Action {
        case fixing
        case fixed([DictionaryPastMeetingFixReceipt])
        case undoing
        case note(String)
    }

    @Published private var scans: [CustomDictionaryEntry: DictionaryPastMeetingScan] = [:]
    @Published private var actions: [UUID: Action] = [:]
    /// Recent fixes loaded from disk (and added this session), by correction.
    @Published private var recentFixes: [CustomDictionaryEntry: [DictionaryPastMeetingFixReceipt]] = [:]

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

    // MARK: - State for the view

    func lineState(for row: DictionaryPastMeetingsRow) -> LineState? {
        let remaining = row.entry.flatMap { scans[$0]?.meetingCount } ?? 0
        switch actions[row.id] {
        case .fixing:
            return .fixing
        case .undoing:
            return .undoing
        case .fixed(let receipts):
            return .fixed(count: receipts.reduce(0) { $0 + $1.fixedCount }, remaining: remaining)
        case .note(let text):
            return remaining > 0 ? .found(meetings: remaining, note: text) : .note(text)
        case nil:
            if let entry = row.entry, let receipts = recentFixes[entry], !receipts.isEmpty {
                return .fixed(count: receipts.reduce(0) { $0 + $1.fixedCount }, remaining: remaining)
            }
            return remaining > 0 ? .found(meetings: remaining, note: nil) : nil
        }
    }

    func scan(for row: DictionaryPastMeetingsRow) -> DictionaryPastMeetingScan? {
        row.entry.flatMap { scans[$0] }
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
        Task { [weak self] in
            let receipts = await Task.detached(priority: .utility) {
                backups().recentReceipts()
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
            if self.scans != result {
                self.scans = result
            }
        }
    }

    // MARK: - Actions

    func fix(row: DictionaryPastMeetingsRow) {
        guard let entry = row.entry, let urls = scans[entry]?.meetingURLs, !urls.isEmpty else { return }
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
                    transcriptURLs: receipt.changes.map(\.url)
                )
                self.recentFixes[entry, default: []].insert(receipt, at: 0)
            }
            if self.rows.contains(where: { $0.id == row.id }) {
                let receipts = receipt.fixedCount > 0 ? [receipt] + earlier : earlier
                if let note = DictionaryPastMeetingFixCopy.fixOutcomeNote(receipt), earlier.isEmpty {
                    self.actions[row.id] = .note(note)
                } else {
                    self.actions[row.id] = .fixed(receipts)
                }
            }
            self.scheduleScan(delay: .zero)
        }
    }

    func undo(row: DictionaryPastMeetingsRow) {
        let receipts = currentReceipts(for: row)
        guard !receipts.isEmpty else { return }
        actions[row.id] = .undoing
        let backups = self.backups
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> DictionaryPastMeetingUndoResult in
                let store = backups()
                // Newest first, so stacked fixes unwind in order.
                let results = receipts.map { DictionaryPastMeetingFix.undo($0, backups: store) }
                return DictionaryPastMeetingUndoResult(
                    restoredURLs: results.flatMap(\.restoredURLs),
                    keptCount: results.reduce(0) { $0 + $1.keptCount }
                )
            }.value
            guard let self else { return }
            if !result.restoredURLs.isEmpty {
                CaptureLibraryChangeBroadcaster.shared.noteArtifactsChanged(
                    transcriptURLs: result.restoredURLs
                )
            }
            let undoneIDs = Set(receipts.map(\.id))
            self.recentFixes = self.recentFixes
                .mapValues { $0.filter { !undoneIDs.contains($0.id) } }
                .filter { !$0.value.isEmpty }
            if self.rows.contains(where: { $0.id == row.id }) {
                if let note = DictionaryPastMeetingFixCopy.undone(result) {
                    self.actions[row.id] = .note(note)
                } else {
                    self.actions[row.id] = nil
                }
            }
            self.scheduleScan(delay: .zero)
        }
    }

    private func currentReceipts(for row: DictionaryPastMeetingsRow) -> [DictionaryPastMeetingFixReceipt] {
        if case .fixed(let receipts) = actions[row.id] {
            return receipts
        }
        if actions[row.id] == nil, let entry = row.entry {
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
    let onFix: () -> Void
    let onUndo: () -> Void

    private struct LineAction {
        let title: String
        let identifier: String
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
        case .fixed:
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
        case .found(let meetings, let note):
            return note ?? DictionaryPastMeetingFixCopy.found(meetings)
        case .fixing:
            return DictionaryPastMeetingFixCopy.fixing
        case .fixed(let count, let remaining):
            return DictionaryPastMeetingFixCopy.fixed(count: count, remaining: remaining)
        case .undoing:
            return DictionaryPastMeetingFixCopy.undoing
        case .note(let text):
            return text
        }
    }

    private var actions: [LineAction] {
        let fixID = "transcripted.settings.general.corrections.fix-past-meetings"
        let undoID = "transcripted.settings.general.corrections.undo-past-meetings"
        switch state {
        case .found(let meetings, let note):
            let title = note == nil ? DictionaryPastMeetingFixCopy.fixAction(meetings) : DictionaryPastMeetingFixCopy.retryAction
            return [LineAction(title: title, identifier: fixID, run: onFix)]
        case .fixed(_, let remaining):
            var actions = [LineAction(title: DictionaryPastMeetingFixCopy.undoAction, identifier: undoID, run: onUndo)]
            if remaining > 0 {
                actions.append(LineAction(title: DictionaryPastMeetingFixCopy.retryAction, identifier: fixID, run: onFix))
            }
            return actions
        case .fixing, .undoing, .note:
            return []
        }
    }
}
