import SwiftUI

/// The Settings > Dictations page. Extracted from `TranscriptedSettingsView`
/// (see `docs/` audit 2026-07-08 wave 2, spec W2-A). All the actual
/// open/copy/flag/delete/track logic stays owned by the parent and arrives as
/// focused closures.
struct DictationsSettingsPage: View {
    @ObservedObject var homeViewModel: HomeViewModel
    let homeCopiedRowID: String?
    let onStartDictation: () -> Void
    let onLoadMoreDictations: () -> Void
    let onOpenDictation: (SavedDictationEntry) -> Void
    let onCopyDictation: (SavedDictationEntry) -> Void
    let onFlagDictation: (SavedDictationEntry) -> Void
    let dictationRowMenuItems: (SavedDictationEntry) -> [HomeRowMenuItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsPageIntro(
                title: "Dictations",
                summary: "Recent dictations saved to daily Markdown files."
            )

            homeDictationsListSection
        }
        .accessibilityIdentifier("transcripted.settings.page.dictations")
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
            HomeDictationRow(
                entry: entry,
                isCopied: homeCopiedRowID == entry.id,
                onOpen: { onOpenDictation(entry) },
                onCopy: { onCopyDictation(entry) },
                onFlag: { onFlagDictation(entry) },
                menuItems: dictationRowMenuItems(entry)
            )
        }
    }
}
