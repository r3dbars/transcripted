import AppKit
import Observation
import SwiftUI
import TranscriptedCore
import UniformTypeIdentifiers

extension TranscriptedSettingsView {
    @ViewBuilder
    var sidebarColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The unified titlebar already insets content below the traffic
            // lights via the safe area; only a small breath is needed here.
            Spacer().frame(height: 6)

            VStack(spacing: 1) {
                sidebarRows(for: SettingsSidebarSection.primarySection.pages)
            }
            .padding(.horizontal, 8)

            Spacer(minLength: 0)

            VStack(spacing: 1) {
                sidebarSettingsButton
                sidebarFeedbackButton
            }
            .padding(.horizontal, 8)

            sidebarVersionLine
        }
        .frame(maxHeight: .infinity)
        .background(LibraryTokens.sidebarBackground.ignoresSafeArea())
    }

    /// Settings by name, a row like the six above it (it used to be a 12 pt
    /// gear). Keeps the old toggle's automation id.
    private var sidebarSettingsButton: some View {
        Button {
            trackSettingsAction("open_settings_area", page: navigation.selectedPage)
            navigation.select(.general, source: .sidebar)
        } label: {
            SettingsSidebarRowLabel(
                title: TranscriptedSettingsPage.general.title,
                systemImage: "gearshape",
                isSelected: SettingsSidebarSection.isSettingsPage(navigation.selectedPage),
                help: "Settings  ⌘,"
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Settings")
        .accessibilityIdentifier("transcripted.settings.sidebar.settings-toggle")
    }

    private var sidebarFeedbackButton: some View {
        Button {
            feedbackComposer.open(area: "general")
            feedbackIsPresented = true
        } label: {
            SettingsSidebarRowLabel(
                title: "Feedback",
                systemImage: "bubble.left",
                isSelected: false,
                help: "Report a problem or share an idea"
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("transcripted.settings.sidebar.feedback")
        .background {
            FeedbackPopoverAnchor(isPresented: $feedbackIsPresented) {
                FeedbackComposerView(
                    model: feedbackComposer,
                    onClose: { feedbackIsPresented = false },
                    onPickerClosed: { feedbackIsPresented = true }
                )
            }
        }
    }

    /// The version, small and quiet, under Settings and Feedback. Clicking it
    /// checks for updates and answers in place ("Up to date" for a few
    /// seconds). An update that needs a click takes its place, with the
    /// attention dot. Every word comes from `UpdateStatusWords`.
    private var sidebarVersionLine: some View {
        let phase = UpdateStatusWords.Phase(sparkleUpdater.updateStatus.state)
        let downloadsAutomatically = sparkleUpdater.availableUpdateDownloadsAutomatically
        return HStack(spacing: 4) {
            if settingsFooterShowsUpdateBadge {
                Button {
                    guard settingsFooterActionEnabled else { return }
                    trackSettingsAction(settingsUpdateActionID, page: .general)
                    sparkleUpdater.performUserUpdateAction(surface: "settings_footer")
                } label: {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(LibraryTokens.attention)
                            .frame(width: 6, height: 6)
                        Text(UpdateStatusWords.title(for: phase, downloadsAutomatically: downloadsAutomatically))
                            .textRole(.small, weight: .medium)
                            .foregroundStyle(LibraryTokens.ink)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 6)
                    .frame(height: 24)
                    .contentShape(RoundedRectangle(cornerRadius: LibraryTokens.radiusControl, style: .continuous))
                }
                .buttonStyle(SidebarQuietButtonStyle())
                .disabled(!settingsFooterActionEnabled)
                .help(UpdateStatusWords.detail(for: phase, downloadsAutomatically: downloadsAutomatically)
                    ?? UpdateStatusWords.action(for: phase, downloadsAutomatically: downloadsAutomatically)
                    ?? "")
                .accessibilityIdentifier("transcripted.settings.footer.check-updates")
            } else {
                Button {
                    trackSettingsAction("footer_version_check_updates", page: navigation.selectedPage)
                    footerVersionCheckActive = true
                    sparkleUpdater.checkForUpdates()
                } label: {
                    Text(footerVersionLabel(phase: phase, downloadsAutomatically: downloadsAutomatically))
                        .textRole(.small)
                        .foregroundStyle(LibraryTokens.ink3)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .frame(height: 24)
                        .contentShape(RoundedRectangle(cornerRadius: LibraryTokens.radiusControl, style: .continuous))
                }
                .buttonStyle(SidebarQuietButtonStyle())
                .help(UpdateStatusWords.checkForUpdates)
                .accessibilityLabel(UpdateStatusWords.checkForUpdates)
                .accessibilityIdentifier("transcripted.settings.footer.version")
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .padding(.top, 2)
        .padding(.bottom, 8)
        .onChange(of: sparkleUpdater.updateStatus) { _, status in
            // Let "Up to date" linger briefly, then settle back to the
            // plain version number.
            guard footerVersionCheckActive, case .noUpdateAvailable = status.state else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(4))
                footerVersionCheckActive = false
            }
        }
    }

    /// The version alone, or what the check the person started found.
    private func footerVersionLabel(phase: UpdateStatusWords.Phase, downloadsAutomatically: Bool) -> String {
        guard footerVersionCheckActive else { return appVersionText }
        let checkedUpToDate: Bool
        if case .noUpdateAvailable = sparkleUpdater.updateStatus.state { checkedUpToDate = true } else { checkedUpToDate = false }
        return UpdateStatusWords.versionNote(
            for: phase,
            checkedUpToDate: checkedUpToDate,
            downloadsAutomatically: downloadsAutomatically
        ) ?? appVersionText
    }

    private var appVersionText: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? ""
    }

    var detailColumn: some View {
        ZStack {
            LibraryTokens.contentBackground.ignoresSafeArea()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        pageBody
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 4)
                    .padding(.bottom, 28)
                    .frame(maxWidth: 860, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .onChange(of: speakerInboxScrollRequest) { _, _ in
                    speakerInboxScrollAwaitingQueue = speakerPeopleModel.reviewStack.calls.isEmpty
                    scrollToSpeakerInbox(using: proxy)
                }
                .onChange(of: settingsScrollTargetID) { _, target in
                    guard let target else { return }
                    Task { @MainActor in
                        await Task.yield()
                        withAnimation(.snappy(duration: 0.22)) {
                            proxy.scrollTo(target, anchor: .top)
                        }
                        settingsScrollTargetID = nil
                    }
                }
                .onChange(of: speakerPeopleModel.reviewStack.calls.count) { oldCount, newCount in
                    guard speakerInboxScrollAwaitingQueue, oldCount == 0, newCount > 0 else { return }
                    speakerInboxScrollAwaitingQueue = false
                    scrollToSpeakerInbox(using: proxy)
                }
            }
        }
    }

    private func sidebarRows(for pages: [TranscriptedSettingsPage]) -> some View {
        ForEach(pages) { page in
            SettingsSidebarButton(
                page: page,
                isSelected: navigation.selectedPage == page,
                isRecordingMeeting: meetingSession.isRecording
            ) {
                navigation.select(page, source: .sidebar)
            }
        }
    }

    @ViewBuilder
    private var pageBody: some View {
        switch navigation.selectedPage {
        case .today:
            todayPage
        case .home, .files:
            // `.files` never gets here (navigation redirects it), but a
            // stray one still lands on Meetings.
            homePage
        case .dictations:
            dictationsPage
        case .writing:
            writingPage
        case .general:
            settingsPage
        case .people:
            peoplePage
        case .connectAgent:
            connectAgentPage
        }
    }

    /// The whole settings surface as one scrolling page. `generalPage` lays
    /// out the four groups and Advanced, and places Library (`storagePage`)
    /// and About (`aboutPage`) inside them.
    private var settingsPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            generalPage

            // Write for Me and the ChatGPT companion can send text off this Mac
            // (DeveloperPreview.nextSentence, CompanionSettingsCard), so say when.
            Text("Recordings and transcripts stay on this Mac. Write for Me and the ChatGPT companion send text only when you use them.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: 620)
                .multilineTextAlignment(.center)
                .padding(.top, 12)
        }
    }

    private var homePage: some View {
        HomeSettingsPage(
            homeViewModel: homeViewModel,
            attentionTitle: homeAttentionIssues.first?.title,
            meetingDaySections: homeMeetingDaySections,
            homeCopiedRowID: homeCopiedRowID,
            homeExpandedMeetingID: homeExpandedMeetingID,
            homeExpandedMeetingPreview: homeExpandedMeetingPreview,
            voiceProcessingEnabled: meetingMicProcessingMode.usesAppleVoiceProcessing,
            micBoostHintsHiddenThrough: micBoostHintsHiddenThrough,
            canRetryFailedMeetings: canRetryFailedMeetings,
            failedMeetingRetryUnavailableReason: failedMeetingRetryUnavailableReason,
            transcriptionActivity: homeTranscriptionActivity,
            transcriptionActivityIsCancellable: homeTranscriptionActivityIsCancellable,
            recordingElapsed: meetingSession.isRecording
                ? QuietWorkingRow.formatElapsed(meetingSession.recordingDuration)
                : nil,
            homeFindIsVisible: $homeFindIsVisible,
            homeMeetingSearchQuery: $homeMeetingSearchQuery,
            homeStarredOnly: $homeStarredOnly,
            homeFindFieldFocusToken: homeFindFieldFocusToken,
            onAttention: {
                if let issue = homeAttentionIssues.first {
                    reviewHomeAttentionIssue(issue)
                }
            },
            onToggleFind: {
                withAnimation(.snappy(duration: 0.18)) {
                    homeFindIsVisible.toggle()
                    if homeFindIsVisible {
                        homeFindFieldFocusToken += 1
                    } else {
                        homeMeetingSearchQuery = ""
                    }
                }
            },
            onRetryScanWarning: {
                trackSettingsAction("home_scan_warning_retry", page: .home)
                homeViewModel.retryScan()
            },
            onRevealScanWarning: {
                trackSettingsAction("home_scan_warning_reveal", page: .home)
                NSWorkspace.shared.activateFileViewerSelecting([MeetingStoragePaths.transcriptsFolder])
            },
            onDismissScanWarning: {
                trackSettingsAction("home_scan_warning_dismiss", page: .home)
                homeViewModel.dismissScanWarning()
            },
            onCancelActivity: {
                trackSettingsAction("cancel_current_activity", page: .home)
                actions.cancelPendingAudioImports()
                meetingSession.cancelActiveTranscription()
            },
            onOpenSavedMeeting: { transcriptURL in
                trackSettingsAction("open_saved_meeting", page: .home)
                // Same path as the pill's Open, so the 10s give-up applies.
                navigation.requestHomeRevealMeeting(transcriptURL: transcriptURL)
            },
            onStartMeeting: {
                trackSettingsAction("empty_start_meeting", page: .home)
                actions.startMeeting()
            },
            onImportAudioFile: {
                trackSettingsAction("empty_import_audio", page: .home)
                actions.importAudioFile()
            },
            onDropAudioFiles: { urls in
                trackSettingsAction("drop_import_audio", page: .home)
                actions.importAudioFiles(urls)
            },
            onLoadMoreMeetings: {
                trackSettingsAction("load_more_meetings", page: navigation.selectedPage)
                if HomeMeetingSearchPaging.isActive(query: homeMeetingSearchQuery, starredOnly: homeStarredOnly) {
                    homeViewModel.loadMoreMeetingSearchResults()
                } else {
                    homeViewModel.loadMoreMeetings()
                }
            },
            onOpenMeeting: { meeting in
                toggleHomeMeetingExpansion(meeting)
            },
            onCopyMeeting: { meeting in
                handleCopyMeeting(meeting)
            },
            onCollapseMeetingExpansion: {
                collapseHomeMeetingExpansion()
            },
            knownPeople: homeKnownPeopleOptions,
            savedSpeakerIDs: homeSavedSpeakerIDs,
            onAssignMeetingSpeakers: { meeting, assignments, completion in
                guard let preview = homeExpandedMeetingPreview,
                      preview.id == meeting.id else {
                    completion(false)
                    return
                }
                assignMeetingSpeakers(assignments, in: preview, completion: completion)
            },
            meetingRowMenuItems: { item in meetingRowMenuItems(for: item) },
            meetingVoicesToName: { item in
                speakerPeopleModel.hasLoadedProfiles ? speakerPeopleModel.voicesToName(forTranscript: item.transcriptURL) : 0
            },
            onWhoSpoke: { item in
                openWhoSpokeCard(for: item)
            },
            onRetryFailedMeeting: { failedMeeting in
                trackSettingsAction("home_retry_failed_meeting", page: navigation.selectedPage)
                retryFailedMeeting(failedMeeting)
            },
            onRevealFailedMeetingAudio: { failedMeeting in
                trackSettingsAction("home_reveal_failed_meeting_audio", page: navigation.selectedPage)
                revealFailedMeetingAudio(failedMeeting)
            },
            onClearFailedMeeting: { failedMeeting in
                requestClearFailedMeeting(failedMeeting)
            },
            failedMeetingAudioAttachment: { failedMeeting in
                failedMeetingAudioAttachment(for: failedMeeting)
            }
        )
        .homeBackgroundTapCatcher {
            if homeExpandedMeetingID != nil {
                collapseHomeMeetingExpansion()
            }
        }
        .onDisappear {
            homeViewModel.finishMeetingReveal(token: homeRevealConsumedToken)
            homePendingRevealMeetingKey = nil
            collapseHomeMeetingExpansion()
        }
        .onAppear {
            homeViewModel.updateMeetingSearch(query: homeMeetingSearchQuery, starredOnly: homeStarredOnly)
        }
        .onChange(of: homeMeetingSearchQuery) { _, query in
            homeViewModel.updateMeetingSearch(query: query, starredOnly: homeStarredOnly)
        }
        .onChange(of: homeStarredOnly) { _, starredOnly in
            homeViewModel.updateMeetingSearch(query: homeMeetingSearchQuery, starredOnly: starredOnly)
        }
        .task(id: navigation.homeFindFocusToken) {
            guard navigation.homeFindFocusToken > homeFindConsumedFocusToken else { return }
            homeFindConsumedFocusToken = navigation.homeFindFocusToken
            homeFindIsVisible = true
            homeFindFieldFocusToken += 1
        }
        .task(id: navigation.homeRevealMeetingToken) {
            guard navigation.homeRevealMeetingToken > homeRevealConsumedToken,
                  let transcriptURL = navigation.homeRevealMeetingURL else { return }
            let token = navigation.homeRevealMeetingToken
            homeRevealConsumedToken = token
            homePendingRevealMeetingKey = Self.homeRevealKey(for: transcriptURL)
            homeViewModel.requestMeetingReveal(at: transcriptURL, token: token)
            revealPendingHomeMeeting(in: homeViewModel.meetingDaySections)
            // A just-saved meeting can take a refresh to show up. Stop waiting
            // after a while so a much later refresh never expands it out of
            // nowhere.
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled else { return }
            homeViewModel.finishMeetingReveal(token: token)
            if homeRevealConsumedToken == token { homePendingRevealMeetingKey = nil }
        }
        .onReceive(homeViewModel.$meetingDaySections) { sections in
            revealPendingHomeMeeting(in: sections)
        }
    }

    private static func homeRevealKey(for transcriptURL: URL) -> String {
        transcriptURL.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Expands the meeting the pill's Open asked for, once it is in the list.
    private func revealPendingHomeMeeting(in sections: [HomeDaySection<RecentMeetingItem>]) {
        guard navigation.isWindowOpen,
              SettingsRecentCaptureRefreshPolicy.mode(for: navigation.selectedPage) == .homeDashboard,
              let key = homePendingRevealMeetingKey else { return }
        guard let item = sections.lazy
            .flatMap(\.items)
            .first(where: { Self.homeRevealKey(for: $0.transcriptURL) == key }) else {
            return
        }
        homeViewModel.finishMeetingReveal(token: homeRevealConsumedToken)
        homePendingRevealMeetingKey = nil
        // A search or the Starred filter could hide the row, and it would
        // expand off-screen.
        if !homeMeetingSearchQuery.isEmpty {
            homeMeetingSearchQuery = ""
        }
        homeStarredOnly = false
        guard homeExpandedMeetingID != item.id else { return }
        toggleHomeMeetingExpansion(item)
    }

    private var dictationsPage: some View {
        DictationsSettingsPage(
            homeViewModel: homeViewModel,
            homeCopiedRowID: homeCopiedRowID,
            onStartDictation: {
                trackSettingsAction("empty_start_dictation", page: .dictations)
                actions.startDictation()
            },
            onLoadMoreDictations: {
                trackSettingsAction("load_more_dictations", page: navigation.selectedPage)
                homeViewModel.loadMoreDictations()
            },
            onCopyDictation: { entry in handleCopyDictation(entry) },
            dictationRowMenuItems: { entry in dictationRowMenuItems(for: entry) },
            onDeleteDictation: { entry in deleteDictationWithUndo(entry) },
            transcribeAgainUnavailableReason: savedMeetingRetranscriptionUnavailableReason,
            // File-based STT over the kept take; no engine or input device.
            transcribeSamples: { [sttRouter] samples in
                try await sttRouter.transcribeSavedDictation(samples: samples)
            },
            onTranscribeAgainFailure: { message, retry in
                presentHomeActionFailure(
                    title: "Could not transcribe dictation again",
                    message: message,
                    retry: retry
                )
            }
        )
        .task(id: navigation.dictationRevealToken) {
            guard navigation.dictationRevealToken > dictationRevealConsumedToken,
                  let entryID = navigation.dictationRevealEntryID else { return }
            dictationRevealConsumedToken = navigation.dictationRevealToken
            dictationPendingReveal = DictationPendingReveal(entryID: entryID)
            revealPendingDictation(in: homeViewModel.dictationDaySections)
            // Older entries may take a few pages to load. Stop waiting after
            // a while so a much later load never scrolls out of nowhere.
            try? await Task.sleep(for: TodayDictationRevealPolicy.giveUpAfter)
            guard !Task.isCancelled else { return }
            dictationPendingReveal = nil
        }
        .onReceive(homeViewModel.$dictationDaySections) { _ in
            // The list publishes before its load flags settle (same pass),
            // so look once that pass is over.
            guard dictationPendingReveal != nil else { return }
            Task { @MainActor in
                revealPendingDictation(in: homeViewModel.dictationDaySections)
            }
        }
        .onDisappear { dictationPendingReveal = nil }
    }

    /// Quiet-library delete for a dictation entry: the day file is rewritten
    /// (or trashed, when this was its only entry) immediately and reversibly,
    /// and the undo offer is staged with the app-wide manager so the
    /// "Deleted · Undo" line survives navigation and refreshes for the whole
    /// grace window. The file work runs off the main thread: it reads and
    /// rewrites the day file under the lock the dictation writer also takes.
    private func deleteDictationWithUndo(_ entry: SavedDictationEntry) {
        let undoID = DictationUndoID.id(for: entry)
        guard homeDeletionIDs.insert(undoID).inserted else { return }
        trackSettingsAction("delete_dictation_confirm", page: navigation.selectedPage)
        Task { @MainActor in
            defer { homeDeletionIDs.remove(undoID) }
            do {
                let undoPayload = try await Task.detached(priority: .userInitiated) {
                    try DictationTranscriptStore.deleteEntryReversibly(entry)
                }.value
                let preview = QuietDictationLibraryFormatting.truncated(
                    QuietDictationLibraryFormatting.firstLine(of: entry.text, fallback: entry.title),
                    maxLength: 34
                )
                captureUndo.stage(
                    id: undoID,
                    message: CaptureUndoMessage.deleted(preview),
                    undoAction: {
                        Task { @MainActor in
                            do {
                                try await Task.detached(priority: .userInitiated) {
                                    try DictationTranscriptStore.restoreDeletedEntry(undoPayload)
                                }.value
                            } catch {
                                presentHomeDeleteFailure(
                                    title: "Could not restore dictation",
                                    error: error,
                                    retry: { refreshRecentCaptures(force: true) }
                                )
                            }
                            refreshRecentCaptures(force: true)
                        }
                    },
                    finalize: {
                        // The delete is permanent now, so its kept audio goes too.
                        Task { @MainActor in
                            await Task.detached(priority: .utility) {
                                _ = DictationAudioArchive.deleteKeptAudio(for: entry)
                            }.value
                            refreshRecentCaptures(force: true)
                        }
                    }
                )
            } catch {
                presentHomeDeleteFailure(
                    title: "Could not delete dictation",
                    error: error,
                    retry: { deleteDictationWithUndo(entry) }
                )
            }
        }
    }

    private func reviewHomeAttentionIssue(_ issue: HomeAttentionIssue) {
        switch issue.destination {
        case .failedMeetings:
            // Failed meetings live inline in the day list now; the link just
            // makes sure the user is on Home where those rows are.
            trackSettingsAction("open_needs_attention_failed_meetings", page: .home)
            navigation.select(.home, source: .settingsAction)
        case .speakers:
            openHomeSpeakerReview(actionName: "open_needs_attention_speakers")
        case .privacy:
            trackSettingsAction("open_needs_attention_privacy", page: .home)
            navigation.select(.general, source: .settingsAction)
            settingsScrollTargetID = "transcripted.settings.section.permissions"
        case .models:
            trackSettingsAction("open_needs_attention_models", page: .home)
            navigation.select(.general, source: .settingsAction)
            settingsScrollTargetID = "transcripted.settings.section.transcription"
        }
    }

    /// Opens Speakers at its "Who spoke?" cards; with a meeting, that
    /// meeting's card goes on top.
    func openHomeSpeakerReview(actionName: String, transcriptURL: URL? = nil) {
        trackSettingsAction(actionName, page: navigation.selectedPage)
        speakerPeopleModel.focusMeeting(transcriptURL: transcriptURL)
        speakerPeopleModel.refresh()
        speakerPeopleModel.searchText = ""
        navigation.select(.people, source: .settingsAction)
        requestSpeakerInboxFocus()
    }

    private func requestSpeakerInboxFocus() {
        speakerInboxScrollRequest += 1
    }

    private var peoplePage: some View {
        PeopleSettingsPage(
            speakerPeopleModel: speakerPeopleModel,
            onStartMeeting: { actions.startMeeting() }
        )
    }

    var storagePage: some View {
        StorageSettingsPage(
            captureLibraryURL: captureLibraryURL,
            unavailableCaptureLibraryPath: unavailableCaptureLibraryPath,
            captureLibraryMigrationInProgress: captureLibraryMigrationInProgress,
            captureLibraryMigrationStatus: captureLibraryMigrationStatus,
            captureLibraryMigrationStatusDetails: captureLibraryMigrationStatusDetails,
            captureLibraryChoicePromptBinding: captureLibraryChoicePromptBinding,
            pendingCaptureLibraryChoice: pendingCaptureLibraryChoice,
            audioRetentionWindow: audioRetentionWindow,
            dictationAudioKeepWindow: dictationAudioKeepWindow,
            modelCacheSnapshot: modelCacheSnapshot,
            modelCacheLoading: modelCacheLoading,
            modelCacheCleanupInProgress: modelCacheCleanupInProgress,
            modelCacheCleanupStatus: modelCacheCleanupStatus,
            modelCacheCleanupStatusDetails: modelCacheCleanupStatusDetails,
            effectiveTranscriptionModelIsWhisper: effectiveTranscriptionModel.isWhisper,
            writingModelRoot: writingController.modelRoot,
            onChooseCaptureLibrary: {
                trackSettingsAction("choose_capture_library", page: .general)
                chooseCaptureLibrary()
            },
            onResetCaptureLibrary: {
                trackSettingsAction("reset_capture_library", page: .general)
                resetCaptureLibraryToDefault()
            },
            onMoveCapturesThenSwitchLibrary: { choice in
                moveCapturesThenSwitchLibrary(choice)
            },
            onCopyCapturesThenSwitchLibrary: { choice in
                copyCapturesThenSwitchLibrary(choice)
            },
            onSwitchLibraryWithoutCopying: { choice in
                switchLibraryWithoutCopying(choice)
            },
            onRemoveReclaimableModelCaches: {
                removeReclaimableModelCaches()
            },
            onLoadModelCacheSnapshot: {
                refreshModelCacheSnapshot()
            },
            onRefreshModelCacheSnapshot: {
                trackSettingsAction("refresh_model_cache_storage", page: .general)
                refreshModelCacheSnapshot()
            },
            onApplyAudioRetentionWindow: { window in
                applyAudioRetentionWindow(window)
            },
            onApplyDictationAudioKeepWindow: { window in
                applyDictationAudioKeepWindow(window)
            },
            failureDetailsButton: { details in
                settingsFailureDetailsButton(details)
            }
        )
    }

    private var connectAgentPage: some View {
        AgentConnectionSettingsPage()
    }

    private var writingPage: some View {
        WritingSettingsPage(
            controller: writingController,
            isCaptureBusy: {
                sttRouter.isRecording
                    || meetingSession.isCaptureSessionActive
                    || meetingSession.hasRuntimeDiagnosticsWork
            }
        )
    }

    var aboutPage: some View {
        AboutSettingsPage(
            sparkleUpdater: sparkleUpdater,
            onTrackSettingsToggle: { settingID, enabled, page in
                trackSettingsToggle(settingID, enabled: enabled, page: page)
            },
            updateActionEnabled: { status in updateActionEnabled(for: status) },
            updateBlockedDetail: { status in
                UpdateActionSafetyPolicy.blockedDetail(
                    state: updateActionSafetyState(for: status.state),
                    reason: updateBlockedReason
                )
            },
            onPerformUpdateAction: {
                trackSettingsAction(settingsUpdateActionID, page: .general)
                sparkleUpdater.performUserUpdateAction(surface: "settings_about")
            },
            onSubmitFeedback: {
                trackSettingsAction("submit_feedback", page: .general)
                feedbackComposer.open(area: "general")
                feedbackIsPresented = true
            }
        )
    }
}
