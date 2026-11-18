import SwiftUI
import TranscriptedCore

/// The Settings > Home (Meetings) page. This owns pure view assembly only:
/// the header (search, ⋯, Record), the titles opt-in line, scan-warning and
/// activity rows, and the day-grouped meeting rows (saved and failed), one of
/// which can be open in place. It also holds which row's transcript is
/// revealed (`MeetingsPageOpenState`). It is where files get transcribed:
/// the header ⋯'s Transcribe a file… and a drop anywhere on the page both
/// feed the same import queue as ⌘O. Everything with side effects — delete/rename/copy/
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
    /// The open saved row's transcript reveal; follows `homeExpandedMeetingID`.
    @State private var openState = MeetingsPageOpenState()
    /// A failed meeting opened in place. Only one row is open at a time, so
    /// opening it closes a saved one and the other way around.
    @State private var openFailedMeetingID: UUID?

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
    @Binding var homeStarredOnly: Bool
    let homeFindFieldFocusToken: Int

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
    let onCollapseMeetingExpansion: () -> Void
    let knownPeople: [SpeakerNameChoice]
    let savedSpeakerIDs: Set<UUID>
    let onAssignMeetingSpeakers: (RecentMeetingItem, [HomeMeetingSpeakerAssignment], @escaping (Bool) -> Void) -> Void
    let meetingRowMenuItems: (RecentMeetingItem) -> [HomeRowMenuItem]
    /// Voices a meeting still has to name, and opening its "Who spoke?" card.
    let meetingVoicesToName: (RecentMeetingItem) -> Int
    let onWhoSpoke: (RecentMeetingItem) -> Void
    let onRetryFailedMeeting: (MeetingSessionController.FailedMeetingItem) -> Void
    let onRevealFailedMeetingAudio: (MeetingSessionController.FailedMeetingItem) -> Void
    let onClearFailedMeeting: (MeetingSessionController.FailedMeetingItem) -> Void
    let failedMeetingAudioAttachment: (MeetingSessionController.FailedMeetingItem) -> MeetingAudioAttachment?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                QuietHomeHeader(
                    attentionTitle: attentionTitle,
                    onAttention: onAttention,
                    searchQuery: $homeMeetingSearchQuery,
                    searchFocusToken: homeFindFieldFocusToken,
                    onStartMeeting: onStartMeeting,
                    onImportAudioFile: onImportAudioFile,
                    // The Only kept audio filter reads the same `starred` flag.
                    isKeptAudioOnly: homeStarredOnly,
                    onToggleKeptAudio: {
                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) { homeStarredOnly.toggle() }
                    }
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
        .onChange(of: homeExpandedMeetingID, initial: true) { _, openID in
            openState.sync(openID: openID)
            if openID != nil { openFailedMeetingID = nil }
        }
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            let fileURLs = urls.filter(\.isFileURL)
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
        HomeMeetingSearchPaging.isActive(query: homeMeetingSearchQuery, starredOnly: homeStarredOnly)
    }

    private var meetingsEmptyMessage: String {
        // A pass over every meeting can take a moment on a big library;
        // don't claim "no matches" before it has looked.
        HomeCaptureListCopy.meetingsEmptyMessage(
            isSearching: isSearchingMeetings,
            starredOnly: homeStarredOnly,
            query: homeMeetingSearchQuery,
            isSearchPassRunning: homeViewModel.isSearchingMeetings
        )
    }

    private var homeMeetingsListSection: some View {
        // Undo offers whose meeting is no longer in the scanned sections (a
        // background rescan during the grace window dropped the trashed
        // file). Render them here so the Undo affordance never disappears
        // before its window closes.
        let visibleRowIDs = Set(meetingDaySections.flatMap { $0.items }.map(\.id))
        let orphanedOffers = captureUndo.offers.filter {
            !DictationUndoID.isDictationUndoID($0.id) && !visibleRowIDs.contains($0.id)
        }
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(orphanedOffers) { offer in
                UndoLineView(offer: offer, manager: captureUndo)
            }
            homeMeetingsList
        }
    }

    private var homeMeetingsList: some View {
        HomeCaptureListSection(
            sections: meetingDaySections,
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
                secondaryAction: onImportAudioFile
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
            getID: { AnyHashable($0.id) },
            onLoadMore: onLoadMoreMeetings,
            // Whitespace separates rows; the open one carries its own card.
            showsRowDividers: false,
            headerStyle: .label
        ) { item in
            homeMeetingListRow(item)
        }
    }

    @ViewBuilder
    private func homeMeetingListRow(_ item: HomeMeetingListItem) -> some View {
        switch item {
        case .saved(let meeting):
            if let offer = captureUndo.offer(for: meeting.id) {
                UndoLineView(offer: offer, manager: captureUndo)
            } else {
                let isExpanded = homeExpandedMeetingID == meeting.id
                QuietMeetingCard(
                    item: meeting,
                    isExpanded: isExpanded,
                    preview: isExpanded && homeExpandedMeetingPreview?.id == meeting.id ? homeExpandedMeetingPreview : nil,
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
                    knownPeople: knownPeople,
                    savedSpeakerIDs: savedSpeakerIDs,
                    onToggleExpanded: { onOpenMeeting(meeting) },
                    onCollapse: onCollapseMeetingExpansion,
                    onCopy: { onCopyMeeting(meeting) },
                    onWhoSpoke: { onWhoSpoke(meeting) },
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
                isOpen: openFailedMeetingID == failedMeeting.id,
                onToggleOpen: { toggleFailedMeeting(failedMeeting.id) }
            )
        }
    }
}

extension HomeSettingsPage {
    /// Opens a failed meeting in place (closing any open saved one), or
    /// closes it when it is the open one.
    fileprivate func toggleFailedMeeting(_ id: UUID) {
        let next = MeetingsPageOpenState.nextOpenID(current: openFailedMeetingID?.uuidString, tapped: id.uuidString)
        if next != nil, homeExpandedMeetingID != nil {
            onCollapseMeetingExpansion()
        }
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) {
            openFailedMeetingID = next == nil ? nil : id
        }
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
