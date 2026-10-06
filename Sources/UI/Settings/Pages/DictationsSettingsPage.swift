import SwiftUI

/// The Settings > Dictations page. One card per saved dictation, grouped by
/// day (`QuietDictationCard` in `QuietDictationLibrary.swift`; the 2026-10
/// redesign after Handy's history page). The daily Markdown file stays the
/// storage shape; this is presentation plus inline playback. Copy, reveal,
/// delete, and the STT call stay owned by the parent and arrive as closures.
///
/// Delete/undo routes through the app-wide `CaptureUndoManager` (not
/// page-local state) so a pending "Deleted · Undo" offer survives navigating
/// away and back during the grace window.
struct DictationsSettingsPage: View {
    @ObservedObject var homeViewModel: HomeViewModel
    let homeCopiedRowID: String?
    let onStartDictation: () -> Void
    let onLoadMoreDictations: () -> Void
    let onCopyDictation: (SavedDictationEntry) -> Void
    let dictationRowMenuItems: (SavedDictationEntry) -> [HomeRowMenuItem]
    /// Deletes a single dictation entry reversibly and stages the undo offer
    /// with `CaptureUndoManager.shared` (the shell owns the disk mutation).
    /// `nil` hides Delete from the card's ⋯ menu entirely.
    var onDeleteDictation: ((SavedDictationEntry) -> Void)? = nil
    /// Why Transcribe again can't run right now (dictating, recording,
    /// loading models, finishing a meeting), or nil when it can.
    var transcribeAgainUnavailableReason: String? = nil
    /// Local STT over 16 kHz mono samples. nil hides Transcribe again.
    var transcribeSamples: (([Float]) async throws -> String)? = nil
    /// Shows a Transcribe again failure; the closure retries.
    var onTranscribeAgainFailure: ((String, @escaping () -> Void) -> Void)? = nil

    @StateObject private var playback = DictationPlaybackController()
    @StateObject private var audioInfo = DictationAudioInfoStore()
    @ObservedObject private var transcribeAgain = DictationTranscribeAgainRunner.shared
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
        .onDisappear {
            playback.stop()
        }
        .accessibilityElement(children: .contain)
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
            onLoadMore: onLoadMoreDictations,
            showsRowDividers: false
        ) { entry in
            dictationRow(for: entry)
        }
    }

    @ViewBuilder
    private func dictationRow(for entry: SavedDictationEntry) -> some View {
        if let offer = captureUndo.offer(for: DictationUndoID.id(for: entry)) {
            UndoLineView(offer: offer, manager: captureUndo)
        } else {
            QuietDictationCard(
                entry: entry,
                isCopied: homeCopiedRowID == entry.id,
                audioInfo: audioInfo.info(for: entry),
                isTranscribingAgain: transcribeAgain.runningEntryID == entry.id,
                playback: playback,
                menuItems: menuItems(for: entry),
                onTogglePlayback: { togglePlayback(entry) },
                onCopy: { onCopyDictation(entry) },
                onLoadAudioInfo: { await audioInfo.load(entry) },
                onShowMore: {
                    ProductUsageTelemetry.trackResult(kind: .dictation, action: .preview, surface: .dictations,
                                                      succeeded: true, artifactDate: entry.createdAt)
                }
            )
        }
    }

    private func togglePlayback(_ entry: SavedDictationEntry) {
        let didToggle = playback.togglePlayback(entryID: entry.id) {
            audioInfo.playableURL(for: entry)
        }
        if !didToggle {
            NSSound.beep()
        }
    }

    private func transcribeAgainAvailability(for entry: SavedDictationEntry) -> DictationTranscribeAgainPolicy.Availability {
        DictationTranscribeAgainPolicy.availability(
            entryID: entry.id,
            hasAudio: transcribeSamples != nil && audioInfo.info(for: entry)?.isAvailable == true,
            runningEntryID: transcribeAgain.runningEntryID,
            globalUnavailableReason: transcribeAgainUnavailableReason
        )
    }

    private func startTranscribeAgain(_ entry: SavedDictationEntry) {
        guard let transcribeSamples,
              DictationTranscribeAgainPolicy.isEnabled(transcribeAgainAvailability(for: entry)) else { return }
        guard let url = audioInfo.playableURL(for: entry) else {
            onTranscribeAgainFailure?(
                "Transcripted couldn't find this dictation's audio. It may have aged out or been deleted.",
                {}
            )
            return
        }
        transcribeAgain.start(
            entry: entry,
            audioURL: url,
            transcribe: transcribeSamples,
            onFailure: { message in
                onTranscribeAgainFailure?(message, { startTranscribeAgain(entry) })
            }
        )
    }

    /// The card's ⋯ menu: Transcribe again (only with kept audio), Show in
    /// Finder, and Delete. "Show in Finder" is the shell's reveal item
    /// (picked by its automation id) relabeled, so revealing stays one owned
    /// implementation. The shell's Open Markdown item stays off this menu,
    /// per the approved mockup.
    private func menuItems(for entry: SavedDictationEntry) -> [HomeRowMenuItem] {
        var items: [HomeRowMenuItem] = []

        let availability = transcribeAgainAvailability(for: entry)
        if let title = DictationTranscribeAgainPolicy.menuTitle(for: availability) {
            items.append(
                HomeRowMenuItem(
                    title: title,
                    symbolName: "arrow.clockwise",
                    isEnabled: DictationTranscribeAgainPolicy.isEnabled(availability),
                    automationIdentifier: DictationRowMenuIdentifier.transcribeAgain
                ) {
                    startTranscribeAgain(entry)
                }
            )
        }

        items.append(contentsOf: dictationRowMenuItems(entry).compactMap { item in
            guard item.automationIdentifier == DictationRowMenuIdentifier.reveal else { return nil }
            return HomeRowMenuItem(
                title: "Show in Finder",
                symbolName: item.symbolName,
                isEnabled: item.isEnabled,
                automationIdentifier: DictationRowMenuIdentifier.reveal,
                action: item.action
            )
        })

        if let onDeleteDictation {
            items.append(
                HomeRowMenuItem(title: "Delete", symbolName: "trash", isDestructive: true) {
                    playback.stop(entryID: entry.id)
                    onDeleteDictation(entry)
                }
            )
        }

        return items
    }
}
