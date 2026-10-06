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

            sidebarBottomLine
        }
        .frame(maxHeight: .infinity)
        .background(LibraryTokens.sidebarBackground.ignoresSafeArea())
    }

    /// One quiet line at the bottom of the sidebar (Things-style): a tiny
    /// gear that opens the settings area, and the app version. The version is
    /// always clickable — it runs an update check and answers inline ("You're
    /// up to date"); when an update is downloaded it swaps for "Update ready".
    private var sidebarBottomLine: some View {
        let isInSettings = SettingsSidebarSection.isSettingsPage(navigation.selectedPage)
        return HStack(spacing: 4) {
            Button {
                trackSettingsAction("open_settings_area", page: navigation.selectedPage)
                navigation.select(.general, source: .sidebar)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isInSettings ? Color.primary : Color.primary.opacity(0.45))
                    .frame(width: 24, height: 24)
                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(SidebarQuietButtonStyle())
            .help("Settings")
            .accessibilityLabel("Settings")
            .accessibilityIdentifier("transcripted.settings.sidebar.settings-toggle")

            if settingsFooterShowsUpdateBadge {
                Button {
                    guard settingsFooterActionEnabled else { return }
                    trackSettingsAction(settingsUpdateActionID, page: .general)
                    sparkleUpdater.performUserUpdateAction(surface: "settings_footer")
                } label: {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 6, height: 6)
                        Text(settingsFooterUpdateIsDownloaded ? "Update ready" : "Update available")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.primary.opacity(0.75))
                    }
                    .padding(.horizontal, 6)
                    .frame(height: 24)
                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(SidebarQuietButtonStyle())
                .disabled(!settingsFooterActionEnabled)
                .help(settingsFooterUpdateIsDownloaded ? "Install the downloaded update" : "Install the new version")
                .accessibilityIdentifier("transcripted.settings.footer.check-updates")
            } else {
                Button {
                    trackSettingsAction("footer_version_check_updates", page: navigation.selectedPage)
                    footerVersionCheckActive = true
                    sparkleUpdater.checkForUpdates()
                } label: {
                    Text(footerVersionLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(LibraryTokens.ink3)
                        .padding(.horizontal, 6)
                        .frame(height: 24)
                        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(SidebarQuietButtonStyle())
                .help("Check for updates")
                .accessibilityLabel("Check for updates")
                .accessibilityIdentifier("transcripted.settings.footer.version")
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onChange(of: sparkleUpdater.updateStatus) { _, status in
            // Let "You're up to date" linger briefly, then settle back to the
            // plain version number.
            guard footerVersionCheckActive, case .noUpdateAvailable = status.state else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(4))
                footerVersionCheckActive = false
            }
        }
    }

    private var footerVersionLabel: String {
        guard footerVersionCheckActive else { return appVersionText }
        switch sparkleUpdater.updateStatus.state {
        case .checking:
            return "Checking…"
        case .noUpdateAvailable:
            return "You're up to date"
        case .updateAvailable, .downloading:
            return "Downloading update…"
        case .unknown, .readyToCheck, .readyToInstall:
            return appVersionText
        }
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
                isSelected: navigation.selectedPage == page
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
        case .home:
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

    /// The whole settings surface as one scrolling page: what used to be the
    /// General / Storage / About tab strip now renders stacked, so everything
    /// is findable by scrolling instead of tab-hunting.
    private var settingsPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            generalPage
            storagePage
                .padding(.top, 8)
            aboutPage
                .padding(.top, 8)

            Text("Transcripts and audio never leave this Mac.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: 620)
                .multilineTextAlignment(.center)
                .padding(.top, 12)
        }
    }

    private var todayPage: some View {
        // The page reads the clock at minute granularity: a fresh Date() on
        // every shell evaluation made SwiftUI redraw every Today mark each
        // time the window above it changed. TimelineView still moves the
        // "Now" label and line each minute.
        TimelineView(.everyMinute) { context in
            TodaySettingsPage(
                todayViewModel: todayViewModel,
                now: context.date,
                onOpenRecentItem: { item in
                    switch item.kind {
                    case .meeting:
                        trackSettingsAction("today_open_recent_meeting", page: .today)
                        if let transcriptURL = item.transcriptURL {
                            navigation.select(.home, source: .settingsAction)
                            navigation.requestHomeRevealMeeting(transcriptURL: transcriptURL)
                        }
                    case .dictation:
                        trackSettingsAction("today_open_recent_dictation", page: .today)
                        navigation.select(.dictations, source: .settingsAction)
                    case .writing:
                        // No Writing page on main yet: open the day's file.
                        if let dayFile = item.transcriptURL {
                            NSWorkspace.shared.open(dayFile)
                        }
                    }
                },
                onShowMeetings: {
                    trackSettingsAction("today_show_meetings", page: .today)
                    navigation.select(.home, source: .settingsAction)
                },
                onShowDictations: {
                    trackSettingsAction("today_show_dictations", page: .today)
                    navigation.select(.dictations, source: .settingsAction)
                },
                onStartMeeting: {
                    trackSettingsAction("empty_start_meeting", page: .today)
                    actions.startMeeting()
                },
                onImportAudioFile: {
                    trackSettingsAction("empty_import_audio", page: .today)
                    actions.importAudioFile()
                },
                onStartDictation: {
                    trackSettingsAction("empty_start_dictation", page: .today)
                    actions.startDictation()
                }
            )
        }
        .onAppear {
            todayViewModel.setShown(true)
        }
        .onDisappear {
            todayViewModel.cancel()
        }
        .onReceive(todayViewModel.$snapshot) { snapshot in
            // The window opens on Today now, so the return signal Meetings
            // used to send on open comes from Today's list. Home owns the
            // once-per-window latch, so visiting Meetings after doesn't count twice.
            homeViewModel.trackActivationReturnProxyIfNeeded(todayRecent: snapshot.recent)
        }
    }

    private var homePage: some View {
        HomeSettingsPage(
            homeViewModel: homeViewModel,
            capturesToday: homeViewModel.todayDictationCount + homeViewModel.todayMeetingCount,
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
                meetingSession.cancelActiveTranscription(reason: .userRequested)
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
                if HomeMeetingSearchPaging.isActive(query: homeMeetingSearchQuery) {
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
            onRevealMeetingInFinder: { meeting in
                trackSettingsAction("reveal_meeting_in_finder", page: .home)
                _ = revealOwnFile(
                    candidateURLs: [meeting.transcriptURL],
                    failureTitle: "Could not show file",
                    failureMessage: SettingsArtifactMessage.meetingTranscriptNotFound
                )
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
            homePendingRevealMeetingKey = nil
            collapseHomeMeetingExpansion()
        }
        .onAppear {
            homeViewModel.updateMeetingSearch(query: homeMeetingSearchQuery)
        }
        .onChange(of: homeMeetingSearchQuery) { _, query in
            homeViewModel.updateMeetingSearch(query: query)
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
            homeRevealConsumedToken = navigation.homeRevealMeetingToken
            homePendingRevealMeetingKey = Self.homeRevealKey(for: transcriptURL)
            revealPendingHomeMeeting(in: homeViewModel.meetingDaySections)
            refreshRecentCaptures(force: true)
            // A just-saved meeting can take a refresh to show up. Stop waiting
            // after a while so a much later refresh never expands it out of
            // nowhere.
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled else { return }
            homePendingRevealMeetingKey = nil
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
        guard let key = homePendingRevealMeetingKey else { return }
        guard let item = sections.lazy
            .flatMap(\.items)
            .first(where: { Self.homeRevealKey(for: $0.transcriptURL) == key }) else {
            // Today can open any meeting from the past week, not only the 10
            // newest. Page the list until it shows up; each page publishes
            // new sections and lands back here. Deferred, and decided inside
            // the Task, because sections publish before the load sets
            // canLoadMoreMeetings and clears its in-flight flag.
            Task { @MainActor in
                guard HomeMeetingRevealPagingPolicy.shouldLoadNextPage(
                    pendingKey: homePendingRevealMeetingKey,
                    requestedKey: key,
                    canLoadMoreMeetings: homeViewModel.canLoadMoreMeetings
                ) else { return }
                homeViewModel.loadMoreMeetings()
            }
            return
        }
        homePendingRevealMeetingKey = nil
        // A search that hides the row would expand something off-screen.
        if !homeMeetingSearchQuery.isEmpty {
            homeMeetingSearchQuery = ""
        }
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
            onOpenDictation: { entry in
                trackSettingsAction("open_recent_dictation", page: navigation.selectedPage)
                let didOpen = openOwnFile(
                    candidateURLs: [entry.url],
                    failureTitle: "Could not open dictation",
                    failureMessage: SettingsArtifactMessage.dictationFileNotFound,
                    onComplete: { ProductUsageTelemetry.trackResult(kind: .dictation, action: .openMarkdown, surface: .dictations, succeeded: $0, artifactDate: entry.createdAt) }
                )
                ActivationTelemetry.trackArtifactAction(
                    artifactKind: .dictation,
                    actionKind: .openMarkdown,
                    surface: .homeRow,
                    artifactDate: entry.createdAt,
                    result: didOpen ? .success : .failed
                )
                ActivationTelemetry.trackHabitLoopAction(
                    actionKind: .reviewYesterday,
                    surface: .homeRow,
                    artifactKind: .dictation,
                    artifactDate: entry.createdAt,
                    result: didOpen ? .success : .failed
                )
            },
            onCopyDictation: { entry in handleCopyDictation(entry) },
            dictationRowMenuItems: { entry in dictationRowMenuItems(for: entry) },
            onDeleteDictation: { entry in deleteDictationWithUndo(entry) }
        )
    }

    /// Quiet-library delete for a dictation entry: the day file is rewritten
    /// (or trashed, when this was its only entry) immediately and reversibly,
    /// and the undo offer is staged with the app-wide manager so the
    /// "Deleted · Undo" line survives navigation and refreshes for the whole
    /// grace window. The file work runs off the main thread: it reads and
    /// rewrites the day file under the lock the dictation writer also takes.
    private func deleteDictationWithUndo(_ entry: SavedDictationEntry) {
        trackSettingsAction("delete_dictation_confirm", page: navigation.selectedPage)
        let undoID = DictationUndoID.id(for: entry)
        guard homeDeletionIDs.insert(undoID).inserted else { return }
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

    func openHomeSpeakerReview(actionName: String) {
        trackSettingsAction(actionName, page: navigation.selectedPage)
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

    private var storagePage: some View {
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
            supportFilesFolder: appStateFolder.deletingLastPathComponent(),
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

    private var aboutPage: some View {
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
            diagnosticsActionStatus: diagnosticsActionStatus,
            crashReportingEnabled: crashReportingEnabled,
            onSubmitFeedback: {
                trackSettingsAction("submit_feedback", page: .general)
                actions.sendFeedback()
            },
            onSendDiagnosticEvent: {
                trackSettingsAction("send_diagnostic_event", page: .general)
                sendDiagnosticEvent()
            }
        )
    }
}
