import SwiftUI

/// Tracks which Settings corrections still match saved meetings, and runs the
/// "Fix them" / "Undo" actions for the line under each correction.
///
/// Counting runs off the main actor after typing pauses. While it runs the
/// line keeps showing the last result for unchanged corrections and shows
/// nothing for new ones, so typing never makes the list flicker.
@MainActor
final class DictionaryPastMeetingsModel: ObservableObject {
    enum LineState: Equatable {
        case found(meetings: Int)
        case fixing
        case fixed(DictionaryPastMeetingFixReceipt)
        case undoing
        case note(String)
    }

    @Published private var scans: [CustomDictionaryEntry: DictionaryPastMeetingScan] = [:]
    @Published private var actions: [CustomDictionaryEntry: LineState] = [:]

    private var scanTask: Task<Void, Never>?
    private var scanToken: ScanCancellationToken?
    private let meetingsDirectory: () -> URL

    init(meetingsDirectory: @escaping () -> URL = { MeetingStoragePaths.transcriptsFolder }) {
        self.meetingsDirectory = meetingsDirectory
    }

    func lineState(for entry: CustomDictionaryEntry?) -> LineState? {
        guard let entry else { return nil }
        if let action = actions[entry] { return action }
        if let scan = scans[entry], scan.meetingCount > 0 {
            return .found(meetings: scan.meetingCount)
        }
        return nil
    }

    /// Recounts after `delay`. A newer call cancels an older one, including a
    /// count already reading files, so typing only counts once the user pauses.
    func scheduleScan(entries: [CustomDictionaryEntry], delay: Duration = .milliseconds(600)) {
        // Finished results for corrections that no longer exist would come
        // back if the same correction were typed again later.
        let active = Set(entries)
        actions = actions.filter { active.contains($0.key) }

        scanTask?.cancel()
        scanToken?.cancel()
        let token = ScanCancellationToken()
        scanToken = token
        let directory = meetingsDirectory()
        scanTask = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !token.isCancelled else { return }
            let result = await Task.detached(priority: .utility) {
                DictionaryPastMeetingFix.scan(entries: entries, in: directory) {
                    token.isCancelled
                }
            }.value
            guard let self, !token.isCancelled else { return }
            self.scans = result
        }
    }

    func fix(_ entry: CustomDictionaryEntry, allEntries: [CustomDictionaryEntry]) {
        guard let urls = scans[entry]?.meetingURLs, !urls.isEmpty else { return }
        actions[entry] = .fixing
        Task { [weak self] in
            let receipt = await Task.detached(priority: .userInitiated) {
                DictionaryPastMeetingFix.fix(entry, meetingsAt: urls)
            }.value
            guard let self else { return }
            if receipt.fixedCount > 0 {
                CaptureLibraryChangeBroadcaster.shared.noteArtifactsChanged(
                    transcriptURLs: receipt.changes.map(\.url)
                )
                self.actions[entry] = .fixed(receipt)
            } else {
                self.actions[entry] = .note(DictionaryPastMeetingFixCopy.fixed(receipt))
            }
            self.scheduleScan(entries: allEntries, delay: .zero)
        }
    }

    func undo(_ entry: CustomDictionaryEntry, allEntries: [CustomDictionaryEntry]) {
        guard case .fixed(let receipt) = actions[entry] else { return }
        actions[entry] = .undoing
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                DictionaryPastMeetingFix.undo(receipt)
            }.value
            guard let self else { return }
            if !result.restoredURLs.isEmpty {
                CaptureLibraryChangeBroadcaster.shared.noteArtifactsChanged(
                    transcriptURLs: result.restoredURLs
                )
            }
            if let note = DictionaryPastMeetingFixCopy.undone(result) {
                self.actions[entry] = .note(note)
            } else {
                // Back to "Also in N past meetings. Fix them" once the recount lands.
                self.actions[entry] = nil
            }
            self.scheduleScan(entries: allEntries, delay: .zero)
        }
    }
}

/// The quiet line under one correction in the Corrections editor.
struct DictionaryPastMeetingsLine: View {
    let state: DictionaryPastMeetingsModel.LineState
    let onFix: () -> Void
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            leadingGlyph
                .frame(width: 14)
            Text(message)
                .font(LibraryTokens.meta)
                .foregroundStyle(LibraryTokens.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let action {
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
                    .settingsAutomationIdentifier(action.identifier)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: LibraryTokens.radiusControl, style: .continuous)
                .fill(LibraryTokens.raisedFill)
        )
        .accessibilityElement(children: .combine)
        .animation(.easeOut(duration: 0.15), value: state)
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
        case .found(let meetings):
            return DictionaryPastMeetingFixCopy.found(meetings)
        case .fixing:
            return DictionaryPastMeetingFixCopy.fixing
        case .fixed(let receipt):
            return DictionaryPastMeetingFixCopy.fixed(receipt)
        case .undoing:
            return DictionaryPastMeetingFixCopy.undoing
        case .note(let text):
            return text
        }
    }

    private var action: (title: String, identifier: String, run: () -> Void)? {
        switch state {
        case .found:
            return (DictionaryPastMeetingFixCopy.fixAction, "transcripted.settings.general.corrections.fix-past-meetings", onFix)
        case .fixed(let receipt) where receipt.fixedCount > 0:
            return (DictionaryPastMeetingFixCopy.undoAction, "transcripted.settings.general.corrections.undo-past-meetings", onUndo)
        default:
            return nil
        }
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
