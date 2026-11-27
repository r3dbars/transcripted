import SwiftUI
import TranscriptedCore

/// The Settings > Home (Meetings) page. This owns pure view assembly only:
/// the header (folded search, Import, Record), the titles opt-in line,
/// scan-warning and activity rows, and the day-grouped meeting cards (saved
/// and failed), one of
/// which can be open in place (saved and failed rows share the shell's one
/// open slot), with the open row's transcript reveal in the shell's
/// `MeetingsPageOpenState`. Days and times read through its own
/// `MeetingsPageClock`, refreshed at midnight and on time zone or locale
/// changes. It is where files get transcribed:
/// the header's Import and a drop anywhere on the page both feed the same
/// import queue as ⌘O (a meeting card's own Markdown dragged back onto the
/// page is ignored). Everything with side effects — delete/rename/copy/
/// retranscribe, the shared root alert, undo staging, and analytics — stays
/// in `TranscriptedSettingsView` (several pieces are pinned there by
/// `Tests/UIAutomationSurfaceContractTests.swift`) and arrives here as
/// injected values and closures, mirroring `StorageSettingsPage` /
/// `DictationsSettingsPage`.
struct HomeSettingsPage: View {
    @ObservedObject var homeViewModel: HomeViewModel
    @ObservedObject private var captureUndo = CaptureUndoManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isAudioDropTargeted = false
    /// Days and times: "Today" moves at midnight without a relaunch.
    @State private var clock = MeetingsPageClock.current()
    /// While search has keyboard focus, Esc belongs to it, not the open card.
    @State private var isSearchFocused = false

    let attentionTitle: String?
    let meetingDaySections: [HomeDaySection<HomeMeetingListItem>]
    let homeCopiedRowID: String?
    let homeExpandedMeetingID: String?
    let homeExpandedMeetingPreview: HomeMeetingPreview?
    let voiceProcessingEnabled: Bool
    let micBoostHintsHiddenThrough: Date?
    let canRetryFailedMeetings: Bool
    let failedMeetingRetryUnavailableReason: String?
    let transcriptionActivity: HomeTranscriptionActivityPresentation?
    let transcriptionActivityIsCancellable: Bool
    let recordingElapsed: String?

    @Binding var homeFindIsVisible: Bool
    @Binding var homeMeetingSearchQuery: String
    let homeFindFieldFocusToken: Int
    /// The open row's transcript reveal; follows `homeExpandedMeetingID`
    /// and survives a rename (the shell owns it so Rename can carry it).
    @Binding var openState: MeetingsPageOpenState

    let onAttention: () -> Void
    let onToggleFind: () -> Void
    let onRetryScanWarning: () -> Void
    let onRevealScanWarning: () -> Void
    let onDismissScanWarning: () -> Void
    let onCancelActivity: () -> Void
    /// Expands a just-saved meeting in the list below (the working row's Open).
    let onOpenSavedMeeting: (URL) -> Void
    let onStartMeeting: () -> Void
    let onImportAudioFile: () -> Void
    /// Audio or video files dropped anywhere on the page. The app filters out
    /// unsupported files and waits for an active recording to stop.
    let onDropAudioFiles: ([URL]) -> Void
    let onLoadMoreMeetings: () -> Void
    let onOpenMeeting: (RecentMeetingItem) -> Void
    let onCopyMeeting: (RecentMeetingItem) -> Void
    let onCollapseMeetingExpansion: (String?) -> Void
    let knownPeople: [SpeakerNameChoice]
    let savedSpeakerIDs: Set<UUID>
    let onAssignMeetingSpeakers: (RecentMeetingItem, [HomeMeetingSpeakerAssignment], @escaping (Bool) -> Void) -> Void
    let meetingRowMenuItems: (RecentMeetingItem) -> [HomeRowMenuItem]
    /// Voices a meeting still has to name, and opening its "Who spoke?" card.
    let meetingVoicesToName: (RecentMeetingItem) -> Int
    let onWhoSpoke: (RecentMeetingItem) -> Void
    /// The inline "Who spoke?" for a card's "N voices to name"; nil sends
    /// `onWhoSpoke` instead. The closure closes the popover.
    var makeWhoSpokeSession: (RecentMeetingItem, @escaping @MainActor () -> Void) -> HomeMeetingWhoSpokeSession? = { _, _ in nil }
    /// Opens a failed meeting in place, or closes it (the shared open slot).
    let onToggleFailedMeeting: (MeetingSessionController.FailedMeetingItem) -> Void
    let onRetryFailedMeeting: (MeetingSessionController.FailedMeetingItem) -> Void
    let onRevealFailedMeetingAudio: (MeetingSessionController.FailedMeetingItem) -> Void
    let onClearFailedMeeting: (MeetingSessionController.FailedMeetingItem) -> Void
    let failedMeetingAudioAttachment: (MeetingSessionController.FailedMeetingItem) -> MeetingAudioAttachment?
    /// Dictation key hint and post-setup checklist surfaced on Meetings' empty state.
    let keyHint: TodayKeyHint
    let setupChecklist: TodaySetupChecklistState
    let onSetupStep: (TodaySetupStep) -> Void
    let onDismissSetup: () -> Void

    var body: some View {
        ScrollViewReader { proxy in
            page
                .onChange(of: homeExpandedMeetingID, initial: true) { _, openID in
                    // A rename keeps the same card (no reset, no scroll).
                    guard openState.sync(openID: openID), let openID else { return }
                    scrollOpenRowIntoView(openID, proxy: proxy)
                }
        }
        .onAppear { clock = .current() }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: DispatchQueue.main)) { _ in
            clock = .current()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange).receive(on: DispatchQueue.main)) { _ in
            clock = .current()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification).receive(on: DispatchQueue.main)) { _ in
            clock = .current()
        }
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                QuietHomeHeader(
                    attentionTitle: attentionTitle,
                    onAttention: onAttention,
                    searchQuery: $homeMeetingSearchQuery,
                    searchFocusToken: homeFindFieldFocusToken,
                    onSearchFocusChange: { isSearchFocused = $0 },
                    onStartMeeting: onStartMeeting,
                    onImportAudioFile: onImportAudioFile
                )

                MeetingTitlesOptInLineView(hasMeetings: !meetingDaySections.isEmpty || isSearchingMeetings)
            }

            if let warning = homeViewModel.scanWarning {
                HomeScanWarningCard(
                    model: warning,
                    onRetry: onRetryScanWarning,
                    onReveal: onRevealScanWarning,
                    onDismiss: onDismissScanWarning
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if let activity = transcriptionActivity {
                QuietWorkingRow(
                    title: activity.title,
                    status: activity.status,
                    progress: activity.progress,
                    symbolName: activity.symbolName,
                    tone: activity.tone,
                    onCancel: transcriptionActivityIsCancellable ? onCancelActivity : nil,
                    recordingElapsed: recordingElapsed,
                    // A failure says why right here instead of only "Needs
                    // attention"; working and saved rows stay one line.
                    detail: activity.tone == .caution ? activity.detail : nil,
                    onOpen: activity.transcriptURL.map { transcriptURL in
                        { onOpenSavedMeeting(transcriptURL) }
                    }
                )
                .transition(.opacity)
            }

            homeMeetingsListSection
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: transcriptionActivity)
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            // A card dragged back onto the page carries its own Markdown;
            // that is not something to transcribe.
            let fileURLs = urls.filter { $0.isFileURL && $0.pathExtension.lowercased() != "md" }
            guard !fileURLs.isEmpty else { return false }
            onDropAudioFiles(fileURLs)
            return true
        } isTargeted: { targeted in
            isAudioDropTargeted = targeted
        }
        .overlay {
            if isAudioDropTargeted {
                HomeAudioDropTargetOverlay()
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: isAudioDropTargeted)
    }

    private var isSearchingMeetings: Bool {
        HomeMeetingSearchPaging.isActive(query: homeMeetingSearchQuery, starredOnly: false)
    }

    private var meetingsEmptyMessage: String {
        // A pass over every meeting can take a moment on a big library;
        // don't claim "no matches" before it has looked.
        HomeCaptureListCopy.meetingsEmptyMessage(
            isSearching: isSearchingMeetings,
            starredOnly: false,
            query: homeMeetingSearchQuery,
            isSearchPassRunning: homeViewModel.isSearchingMeetings
        )
    }

    private var homeMeetingsListSection: some View {
        // Undo offers whose meeting is no longer in the scanned sections (a
        // background rescan during the grace window dropped the trashed
        // file). Render them here so the Undo affordance never disappears
        // before its window closes.
        let visibleRowIDs = Set(meetingDaySections.flatMap { $0.items }.compactMap { item -> String? in
            if case .saved(let meeting) = item { return meeting.id }
            return nil
        })
        let orphanedOffers = captureUndo.offers.filter {
            !DictationUndoID.isDictationUndoID($0.id) && !visibleRowIDs.contains($0.id)
        }
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(orphanedOffers) { offer in
                UndoLineView(offer: offer, manager: captureUndo)
            }
            homeMeetingsList
            if !isSearchingMeetings && !homeViewModel.isLoading && daySections.isEmpty && setupChecklist.isShown {
                TodaySetupChecklist(
                    state: setupChecklist,
                    onStep: onSetupStep,
                    onDismiss: onDismissSetup
                )
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 4)
            }
        }
    }

    private var homeMeetingsList: some View {
        HomeCaptureListSection(
            sections: daySections,
            emptyMessage: meetingsEmptyMessage,
            emptyState: isSearchingMeetings ? nil : HomeListEmptyState(
                symbolName: "waveform",
                title: "No meetings yet",
                message: "Record a call, or drop in a recording to transcribe it. Transcripts land here, with each speaker labeled.",
                actionTitle: "Record a meeting",
                automationIdentifier: "transcripted.home.meetings.empty.start",
                action: onStartMeeting,
                secondaryActionTitle: HomeCaptureListCopy.EmptyMeetingsImportAction.title,
                secondaryAutomationIdentifier: HomeCaptureListCopy.EmptyMeetingsImportAction.automationIdentifier,
                secondaryAction: onImportAudioFile,
                keyHint: keyHint
            ),
            // A background refresh of the recent slice shouldn't hide search
            // results behind a spinner.
            isLoading: isSearchingMeetings ? false : homeViewModel.isLoading,
            isLoadingMore: isSearchingMeetings
                ? homeViewModel.isSearchingMeetings && homeViewModel.canLoadMoreMeetingSearchResults
                : homeViewModel.isLoadingMore,
            canLoadMore: isSearchingMeetings
                ? homeViewModel.canLoadMoreMeetingSearchResults
                : homeViewModel.canLoadMoreMeetings,
            getID: { AnyHashable($0.item.id) },
            onLoadMore: onLoadMoreMeetings,
            // Every row is its own matte card; spacing comes from the card.
            showsRowDividers: false,
            headerStyle: .label
        ) { row in
            homeMeetingListRow(row.item, dayHeader: row.dayHeader)
        }
    }

    /// The rows regrouped with the page's clock, each carrying its header.
    private var daySections: [HomeDaySection<MeetingsPageDayRow<HomeMeetingListItem>>] {
        HomeMeetingCardPresentation.daySections(
            meetingDaySections.flatMap(\.items),
            date: \.date,
            clock: clock
        )
    }

    @ViewBuilder
    private func homeMeetingListRow(_ item: HomeMeetingListItem, dayHeader: String) -> some View {
        switch item {
        case .saved(let meeting):
            if let offer = captureUndo.offer(for: meeting.id) {
                UndoLineView(offer: offer, manager: captureUndo)
            } else {
                let isExpanded = openState.isOpen(meeting.id, expandedID: homeExpandedMeetingID)
                QuietMeetingCard(
                    item: meeting,
                    dayHeader: dayHeader,
                    clock: clock,
                    isExpanded: isExpanded,
                    // The preview belongs to the open meeting (under its new
                    // path while a rename settles).
                    preview: isExpanded && homeExpandedMeetingPreview?.id == homeExpandedMeetingID ? homeExpandedMeetingPreview : nil,
                    isCopied: homeCopiedRowID == meeting.id,
                    menuItems: meetingRowMenuItems(meeting),
                    showsMicBoostHint: RecentMeetingMicBoostHintPolicy.shouldOfferEnableAction(
                        audioHealth: meeting.audioHealth,
                        meetingDate: meeting.date,
                        voiceProcessingPreferenceEnabled: voiceProcessingEnabled,
                        hintsHiddenThrough: micBoostHintsHiddenThrough
                    ),
                    voicesToName: meetingVoicesToName(meeting),
                    isTranscriptShown: openState.isTranscriptShown(for: meeting.id),
                    showsAllLines: openState.showsAllLines(for: meeting.id),
                    escapeClosesCard: !isSearchFocused,
                    knownPeople: knownPeople,
                    savedSpeakerIDs: savedSpeakerIDs,
                    onToggleExpanded: { onOpenMeeting(meeting) },
                    onCollapse: { onCollapseMeetingExpansion(meeting.id) },
                    onCopy: { onCopyMeeting(meeting) },
                    onWhoSpoke: { onWhoSpoke(meeting) },
                    makeWhoSpokeSession: { onClose in makeWhoSpokeSession(meeting, onClose) },
                    onToggleTranscript: {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { openState.toggleTranscript() }
                    },
                    onShowAllLines: { openState.showAllLines() },
                    onAssignSpeakers: { assignments, completion in
                        onAssignMeetingSpeakers(meeting, assignments, completion)
                    }
                )
            }
        case .failed(let failedMeeting):
            HomeFailedMeetingInlineRow(
                item: failedMeeting,
                canRetry: canRetryFailedMeetings,
                retryUnavailableReason: failedMeetingRetryUnavailableReason,
                onRetry: { onRetryFailedMeeting(failedMeeting) },
                onRevealAudio: { onRevealFailedMeetingAudio(failedMeeting) },
                onClear: { onClearFailedMeeting(failedMeeting) },
                audioAttachment: failedMeetingAudioAttachment(failedMeeting),
                isOpen: homeExpandedMeetingID == MeetingsPageOpenState.failedMeetingKey(failedMeeting.id),
                dayHeader: dayHeader,
                clock: clock,
                escapeClosesCard: !isSearchFocused,
                onToggleOpen: { onToggleFailedMeeting(failedMeeting) },
                onCollapse: { onCollapseMeetingExpansion(MeetingsPageOpenState.failedMeetingKey(failedMeeting.id)) }
            )
        }
    }
}

extension HomeSettingsPage {
    /// Once a row opens, scroll just enough to show the opened card (the
    /// mockup's `scrollIntoView` nearest), after the open animation.
    fileprivate func scrollOpenRowIntoView(_ openID: String, proxy: ScrollViewProxy) {
        guard let rowID = listRowID(forOpenID: openID) else { return }
        let reduceMotion = reduceMotion
        Task { @MainActor in
            if !reduceMotion { try? await Task.sleep(nanoseconds: 240_000_000) }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                proxy.scrollTo(AnyHashable(rowID), anchor: nil)
            }
        }
    }

    /// The list's id (`HomeMeetingListItem.id`) for the shell's open id.
    private func listRowID(forOpenID openID: String) -> String? {
        meetingDaySections.lazy.flatMap(\.items).first { item in
            switch item {
            case .saved(let meeting): return meeting.id == openID
            case .failed(let failed): return MeetingsPageOpenState.failedMeetingKey(failed.id) == openID
            }
        }?.id
    }
}

/// Shown over Meetings while files are dragged over it.
private struct HomeAudioDropTargetOverlay: View {
    var body: some View {
        RoundedRectangle(cornerRadius: LibraryTokens.radiusRaised, style: .continuous)
            .strokeBorder(DesignTokens.hairlineStrong, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            .background(
                RoundedRectangle(cornerRadius: LibraryTokens.radiusRaised, style: .continuous)
                    .fill(DesignTokens.fill)
            )
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 22, weight: .regular))
                    Text("Drop to transcribe")
                        .font(TextRole.heading.font())
                }
                .foregroundStyle(LibraryTokens.ink)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
