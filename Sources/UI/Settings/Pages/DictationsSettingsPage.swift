import SwiftUI

/// The Settings > Dictations page. Extracted from `TranscriptedSettingsView`
/// (see `docs/` audit 2026-07-08 wave 2, spec W2-A); restyled in the 2026-08
/// quiet-library redesign so each saved dictation is its own row instead of
/// one row per daily Markdown file (see `QuietDictationLibrary.swift`). The
/// daily file stays the storage shape — this is presentation only. All the
/// actual open/copy/reveal/delete logic stays owned by the parent and
/// arrives as focused closures.
///
/// Delete/undo routes through the app-wide `CaptureUndoManager` (not
/// page-local state) so a pending "Deleted · Undo" offer survives navigating
/// away and back during the grace window.
struct DictationsSettingsPage: View {
    @ObservedObject var homeViewModel: HomeViewModel
    let homeCopiedRowID: String?
    let onStartDictation: () -> Void
    let onLoadMoreDictations: () -> Void
    let onOpenDictation: (SavedDictationEntry) -> Void
    let onCopyDictation: (SavedDictationEntry) -> Void
    let dictationRowMenuItems: (SavedDictationEntry) -> [HomeRowMenuItem]
    /// Deletes a single dictation entry reversibly and stages the undo offer
    /// with `CaptureUndoManager.shared` (the shell owns the disk mutation).
    /// `nil` hides Delete from the row/expansion overflow menu entirely.
    var onDeleteDictation: ((SavedDictationEntry) -> Void)? = nil

    @State private var expandedEntryID: String?
    @ObservedObject private var captureUndo = CaptureUndoManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsPageIntro(
                title: "Dictations",
                summary: dictationsSummary
            )

            orphanedUndoOffers

            homeDictationsListSection
        }
        .accessibilityIdentifier("transcripted.settings.page.dictations")
    }

    private var dictationsSummary: String {
        "\(homeViewModel.todayDictationCount) today"
    }

    /// Undo offers whose entry is no longer in the loaded day sections
    /// (a refresh rescanned disk mid-window and dropped the rewritten
    /// entry). Rendering them here keeps the Undo affordance alive for the
    /// whole grace window no matter what refreshes happen underneath.
    @ViewBuilder
    private var orphanedUndoOffers: some View {
        let visibleIDs = Set(
            homeViewModel.dictationDaySections
                .flatMap { $0.items }
                .map { DictationUndoID.id(for: $0) }
        )
        let orphans = captureUndo.offers.filter {
            DictationUndoID.isDictationUndoID($0.id) && !visibleIDs.contains($0.id)
        }
        if !orphans.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(orphans) { offer in
                    UndoLineView(offer: offer, manager: captureUndo)
                }
            }
        }
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
        if let offer = captureUndo.offer(for: DictationUndoID.id(for: entry)) {
            UndoLineView(offer: offer, manager: captureUndo)
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
    /// stays a single owned implementation.
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
                    if expandedEntryID == entry.id {
                        collapse()
                    }
                    onDeleteDictation(entry)
                }
            )
        }

        return items
    }
}
