import SwiftUI

/// The Settings > Home (Meetings) page. This owns pure view assembly only:
/// the header, scan-warning/activity rows, search field, and the day-grouped
/// meeting list (including inline failed-meeting recovery rows and the
/// expanded-row preview). Everything with side effects — delete/rename/copy/
/// retranscribe, the shared root alert, undo staging, and analytics — stays
/// in `TranscriptedSettingsView` (several pieces are pinned there by
/// `Tests/UIAutomationSurfaceContractTests.swift`) and arrives here as
/// injected values and closures, mirroring `StorageSettingsPage` /
/// `DictationsSettingsPage`.
struct HomeSettingsPage: View {
    @ObservedObject var homeViewModel: HomeViewModel
    @ObservedObject private var captureUndo = CaptureUndoManager.shared

    let capturesToday: Int
    let attentionTitle: String?
    let meetingDaySections: [HomeDaySection<HomeMeetingListItem>]
    let homeCopiedRowID: String?
    let homeExpandedMeetingID: String?
    let homeExpandedMeetingPreview: HomeMeetingPreview?
    let voiceProcessingEnabled: Bool
    let canRetryFailedMeetings: Bool
    let failedMeetingRetryUnavailableReason: String?
    let transcriptionActivity: HomeTranscriptionActivityPresentation?
    let transcriptionActivityIsCancellable: Bool
    let recordingElapsed: String?

    @Binding var homeFindIsVisible: Bool
    @Binding var homeMeetingSearchQuery: String
    let homeFindFieldFocusToken: Int

    let onAttention: () -> Void
    let onToggleFind: () -> Void
    let onRetryScanWarning: () -> Void
    let onRevealScanWarning: () -> Void
    let onDismissScanWarning: () -> Void
    let onCancelActivity: () -> Void
    let onStartMeeting: () -> Void
    let onImportAudioFile: () -> Void
    let onLoadMoreMeetings: () -> Void
    let onOpenMeeting: (RecentMeetingItem) -> Void
    let onCopyMeeting: (RecentMeetingItem) -> Void
    let onRevealMeetingInFinder: (RecentMeetingItem) -> Void
    let onCollapseMeetingExpansion: () -> Void
    let onRenameMeeting: (RecentMeetingItem, String) -> Void
    let onRenameMeetingSpeaker: (RecentMeetingItem, HomeMeetingSpeakerIdentity, String) -> Void
    let meetingRowMenuItems: (RecentMeetingItem) -> [HomeRowMenuItem]
    let onRetryFailedMeeting: (MeetingSessionController.FailedMeetingItem) -> Void
    let onRevealFailedMeetingAudio: (MeetingSessionController.FailedMeetingItem) -> Void
    let onClearFailedMeeting: (MeetingSessionController.FailedMeetingItem) -> Void
    let failedMeetingAudioAttachment: (MeetingSessionController.FailedMeetingItem) -> MeetingAudioAttachment?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            QuietHomeHeader(
                capturesToday: capturesToday,
                attentionTitle: attentionTitle,
                onAttention: onAttention,
                onToggleFind: onToggleFind
            )

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
                    onCancel: transcriptionActivityIsCancellable ? onCancelActivity : nil,
                    recordingElapsed: recordingElapsed
                )
                .transition(.opacity)
            }

            if homeFindIsVisible || !homeMeetingSearchQuery.isEmpty {
                HomeMeetingSearchField(
                    query: $homeMeetingSearchQuery,
                    focusRequestToken: homeFindFieldFocusToken
                )
                .padding(.top, 6)
                .transition(.opacity)
            }

            homeMeetingsListSection
                .padding(.top, 6)
        }
        .animation(.snappy(duration: 0.22), value: transcriptionActivity)
    }

    private var isSearchingMeetings: Bool {
        !homeMeetingSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
            emptyMessage: isSearchingMeetings ? HomeCaptureListCopy.noMeetingMatches : HomeCaptureListCopy.emptyMeetings,
            emptyState: isSearchingMeetings ? nil : HomeListEmptyState(
                symbolName: "waveform",
                title: "No meetings yet",
                message: "Record a meeting or transcribe an existing audio file. Transcripted labels each speaker and saves the transcript here.",
                actionTitle: "Start a meeting",
                automationIdentifier: "transcripted.home.meetings.empty.start",
                action: onStartMeeting,
                secondaryActionTitle: "Transcribe audio file",
                secondaryAutomationIdentifier: "transcripted.home.meetings.empty.import-audio",
                secondaryAction: onImportAudioFile
            ),
            isLoading: homeViewModel.isLoading,
            isLoadingMore: homeViewModel.isLoadingMore,
            canLoadMore: homeViewModel.canLoadMoreMeetings,
            getID: { AnyHashable($0.id) },
            onLoadMore: onLoadMoreMeetings
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
            } else if homeExpandedMeetingID == meeting.id {
                QuietMeetingExpansion(
                    item: meeting,
                    preview: homeExpandedMeetingPreview?.id == meeting.id ? homeExpandedMeetingPreview : nil,
                    isCopied: homeCopiedRowID == meeting.id,
                    onCopy: { onCopyMeeting(meeting) },
                    onRevealInFinder: { onRevealMeetingInFinder(meeting) },
                    onCollapse: onCollapseMeetingExpansion,
                    onRename: { newTitle in onRenameMeeting(meeting, newTitle) },
                    onRenameSpeaker: { identity, newName in onRenameMeetingSpeaker(meeting, identity, newName) },
                    menuItems: meetingRowMenuItems(meeting)
                )
            } else {
                QuietMeetingRow(
                    item: meeting,
                    isCopied: homeCopiedRowID == meeting.id,
                    isExpanded: false,
                    onOpen: { onOpenMeeting(meeting) },
                    onCopy: { onCopyMeeting(meeting) },
                    menuItems: meetingRowMenuItems(meeting),
                    showsMicBoostHint: RecentMeetingMicBoostHintPolicy.shouldOfferEnableAction(
                        audioHealth: meeting.audioHealth,
                        voiceProcessingPreferenceEnabled: voiceProcessingEnabled
                    )
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
                audioAttachment: failedMeetingAudioAttachment(failedMeeting)
            )
        }
    }
}
