import SwiftUI

/// The Settings > Dictations page. Extracted from `TranscriptedSettingsView`
/// (see `docs/` audit 2026-07-08 wave 2, spec W2-A); restyled in the 2026-08
/// quiet-library redesign so each saved dictation is its own row instead of
/// one row per daily Markdown file (see `QuietDictationLibrary.swift`). The
/// daily file stays the storage shape — this is presentation only. All the
/// actual open/copy/reveal/delete logic stays owned by the parent and
/// arrives as focused closures.
struct DictationsSettingsPage: View {
    @ObservedObject var homeViewModel: HomeViewModel
    let homeCopiedRowID: String?
    let onStartDictation: () -> Void
    let onLoadMoreDictations: () -> Void
    let onOpenDictation: (SavedDictationEntry) -> Void
    let onCopyDictation: (SavedDictationEntry) -> Void
    let dictationRowMenuItems: (SavedDictationEntry) -> [HomeRowMenuItem]
    /// Deletes a single dictation entry immediately (no confirmation) once
    /// this page's own "Deleted · Undo" window expires. `nil` hides Delete
    /// from the row/expansion overflow menu entirely — safe default until
    /// the shell wires an undo-friendly delete path.
    var onDeleteDictation: ((SavedDictationEntry) -> Void)? = nil

    @State private var expandedEntryID: String?
    @State private var pendingDeletions: [String: PendingDictationDeletion] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsPageIntro(
                title: "Dictations",
                summary: dictationsSummary
            )

            homeDictationsListSection
        }
        .accessibilityIdentifier("transcripted.settings.page.dictations")
    }

    private var dictationsSummary: String {
        "\(homeViewModel.todayDictationCount) today"
    }

    private var homeDictationsListSection: some View {
        HomeCaptureListSection(
            sections: homeViewModel.dictationDaySections,
            emptyMessage: HomeCaptureListCopy.emptyDictations,
            emptyState: HomeListEmptyState(
                symbolName: "mic",
                title: "No dictations yet",
                message: "Hold your dictation shortcut and speak in any app — Transcripted types it out for you and keeps a copy here.",
                actionTitle: "Start a dictation",
                automationIdentifier: "transcripted.home.dictations.empty.start",
                action: onStartDictation
            ),
            isLoading: homeViewModel.isLoading,
            isLoadingMore: homeViewModel.isLoadingMore,
            canLoadMore: homeViewModel.canLoadMoreDictations,
            getID: { AnyHashable($0.id) },
            onLoadMore: onLoadMoreDictations
        ) { entry in
            dictationRow(for: entry)
        }
    }

    @ViewBuilder
    private func dictationRow(for entry: SavedDictationEntry) -> some View {
        if let pending = pendingDeletions[entry.id] {
            QuietDeletedDictationRow(preview: pending.preview) {
                undoDelete(entry.id)
            }
        } else if expandedEntryID == entry.id {
            QuietDictationExpansion(
                entry: entry,
                isCopied: homeCopiedRowID == entry.id,
                onCopy: { onCopyDictation(entry) },
                onOpenFile: { onOpenDictation(entry) },
                onCollapse: collapse,
                menuItems: menuItems(for: entry)
            )
        } else {
            QuietDictationRow(
                entry: entry,
                isCopied: homeCopiedRowID == entry.id,
                onOpen: { toggleExpansion(entry) },
                onCopy: { onCopyDictation(entry) },
                menuItems: menuItems(for: entry)
            )
        }
    }

    private func toggleExpansion(_ entry: SavedDictationEntry) {
        withAnimation(.snappy(duration: 0.2)) {
            expandedEntryID = (expandedEntryID == entry.id) ? nil : entry.id
        }
    }

    private func collapse() {
        withAnimation(.snappy(duration: 0.2)) {
            expandedEntryID = nil
        }
    }

    /// Builds the row/expansion overflow menu: Open file, Reveal in Finder,
    /// and Delete — never "Report issue". Sourced from the shell's
    /// `dictationRowMenuItems(_:)` (relabeling "Open Markdown" to "Open
    /// file" since it's the row's only open affordance) so Reveal-in-Finder
    /// stays a single owned implementation; the shell's confirm-dialog
    /// "Delete dictation" item is dropped in favor of this page's own
    /// inline undo delete.
    private func menuItems(for entry: SavedDictationEntry) -> [HomeRowMenuItem] {
        var items: [HomeRowMenuItem] = dictationRowMenuItems(entry).compactMap { item in
            switch item.title {
            case "Open Markdown":
                return HomeRowMenuItem(
                    title: "Open file",
                    symbolName: item.symbolName,
                    isEnabled: item.isEnabled,
                    action: item.action
                )
            case "Reveal in Finder":
                return item
            default:
                return nil
            }
        }

        if let onDeleteDictation {
            items.append(
                HomeRowMenuItem(title: "Delete", symbolName: "trash", isDestructive: true) {
                    requestDelete(entry, perform: onDeleteDictation)
                }
            )
        }

        return items
    }

    /// Optimistically hides the row behind a "Deleted · Undo" line for six
    /// seconds, then calls the injected delete closure. Undo cancels the
    /// pending task and restores the row with no disk mutation ever having
    /// happened.
    ///
    /// The pending entry is deliberately left in place (not cleared) once
    /// the timer fires and the delete closure runs: `homeViewModel` will
    /// drop the now-deleted entry from `dictationDaySections` on its own
    /// refresh, so this row simply stops being asked for and the stale
    /// dictionary entry is harmless. That also means a still-visible "Undo"
    /// after a failed delete safely restores the row, since the entry would
    /// still be present in `dictationDaySections`.
    private func requestDelete(_ entry: SavedDictationEntry, perform delete: @escaping (SavedDictationEntry) -> Void) {
        if expandedEntryID == entry.id {
            collapse()
        }

        let preview = QuietDictationLibraryFormatting.firstLine(of: entry.text, fallback: entry.title)
        let entryID = entry.id
        let task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            delete(entry)
        }
        pendingDeletions[entryID] = PendingDictationDeletion(preview: preview, task: task)
    }

    private func undoDelete(_ id: String) {
        pendingDeletions[id]?.task.cancel()
        pendingDeletions[id] = nil
    }
}

private struct PendingDictationDeletion {
    let preview: String
    let task: Task<Void, Never>
}
