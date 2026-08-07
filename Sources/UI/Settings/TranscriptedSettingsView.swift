import AppKit
import Observation
import SwiftUI
import TranscriptedCore
import UniformTypeIdentifiers

struct TranscriptedSettingsView: View {
    @Bindable var navigation: TranscriptedSettingsNavigationModel
    @ObservedObject var speakerPeopleModel: SpeakerPeopleSettingsViewModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ObservedObject private var sttRouter: STTRouter
    @ObservedObject private var meetingSession: MeetingSessionController
    @ObservedObject private var sparkleUpdater: SparkleUpdaterController

    private let actions: TranscriptedSettingsActions
    private let appLogger: AppLogSink

    @State private var dictationTriggerSystemWarning = PhysicalDictationTriggerPreferences.functionKeyConflictWarning(
        for: PhysicalDictationTriggerPreferences.pushToTalkBinding()
    )
    @State private var dictationShortcutsEnabled = HotkeyPreferences.dictationShortcutsEnabled()
    @State private var showTranscriptedInDock = DockVisibilityPreferences.isVisible()
    @State private var launchAtLoginEnabled = LaunchAtLoginController.isEnabled
    @State private var launchAtLoginStatus = LaunchAtLoginController.statusDescription
    @State private var showGeneralModelSettings = false
    @State private var showGeneralShortcutSettings = false
    @State private var showGeneralPrivacySettings = false
    @State private var customDictionaryText = CustomDictionaryPreferences.rawText()
    @State private var customDictionaryRows = CorrectionDraftRow.rows(from: CustomDictionaryPreferences.rawText())
    @State private var customDictionaryPreviewInput = ""
    @State private var showGeneralCorrections = false
    @State private var showCorrectionPreview = false
    @State private var dictationCleanupEnabled = DictationCleanupPreferences.isEnabled()
    @State private var dictationOverlayMode = DictationOverlayPresentationPreferences.mode()
    @State private var showAdvancedCorrectionsText = false
    @State private var preferredTranscriptionModel = TranscriptionModelPreferences.preferredModel()
    @State private var showAdvancedModelControls = false
    @State private var preferredSpeakerEmbedder = SpeakerEmbedderPreferences.preferredChoice()
    @State private var showSpeakerEmbedderSwitchConfirm = false
    @State private var uiSoundsEnabled = UISoundPreferences.isEnabled()
    @State private var autoEnterEnabled = DictationAutoSendPreferences.isEnabled()
    @State private var keepRecommendedMicrophoneActive = DictationPersistentInputPreferences.isEnabled()
    @State private var preferredDictationInputUID = DictationPersistentInputPreferences.preferredDeviceUID()
    @State private var availableDictationInputs = (try? CoreAudioInputDeviceLookup.availableInputDevices()) ?? []
    @State private var autoEnterKey = DictationAutoSendPreferences.sendKey()
    @State private var autoEnterAllowedBundleIDs = DictationAutoSendPreferences.allowedBundleIDs()
    @State private var autoEnterAppCandidates: [AutoEnterAppCandidate] = []
    @State private var crashReportingEnabled = CrashReportingPreferences.isEnabled()
    @State private var anonymousAnalyticsEnabled = AnalyticsPreferences.isEnabled()
    @State private var sentryTestStatus: String?
    @State private var diagnosticsActionStatus: String?
    @State private var permissionStates = PermissionSnapshot.current()
    @State private var permissionRevalidationTask: Task<Void, Never>?
    @State private var captureLibraryURL = FileManager.default.transcriptedCaptureLibraryDir
    @State private var unavailableCaptureLibraryPath = TranscriptedStoragePreferences.unavailableCustomCaptureLibraryPath()
    @State private var pendingCaptureLibraryChoice: PendingCaptureLibraryChoice?
    @State private var captureLibraryMigrationInProgress = false
    @State private var captureLibraryMigrationStatus: String?
    @State private var homeDashboardRefreshTask: Task<Void, Never>?
    @State private var homeDashboardRefreshInFlight = false
    @State private var homeDashboardRefreshGeneration = SupersessionEpoch()
    @State private var lastHomeDashboardRefreshStartedAt: Date?
    @State private var modelCacheSnapshot: ModelCacheSnapshot?
    @State private var modelCacheLoading = false
    @State private var modelCacheCleanupInProgress = false
    @State private var modelCacheCleanupStatus: String?
    @State private var meetingMicProcessingMode = MicrophoneProcessingPreferences.mode()
    @State private var splitLocalSpeakersEnabled = LocalSpeakerPreferences.isEnabled()
    @State private var confirmQuitDuringMeetingEnabled = QuitConfirmationPreferences.confirmQuitDuringActiveMeetingRecording()
    @State private var autoDetectCallsEnabled = AutoCallDetectionPreferences.isEnabled()
    @State private var missedCallNudgeEnabled = MissedCallNudgePreferences.isEnabled()
    @State private var audioRetentionWindow = AudioStoragePreferences.deleteAudioAfter()
    @StateObject private var homeViewModel = HomeViewModel()
    @State private var homeCopiedRowID: String?
    @State private var homeDeleteConfirmation: HomeDeleteConfirmation?
    @State private var homeDeleteFailure: HomeDeleteFailure?
    @State private var homeFeedbackTarget: HomeFeedbackTarget?
    @State private var homeFindIsVisible = false
    @State private var homeFindConsumedFocusToken = 0
    @State private var homeFindFieldFocusToken = 0
    @State private var homeExpandedMeetingID: String?
    @State private var homeExpandedMeetingPreview: HomeMeetingPreview?
    @ObservedObject private var captureUndo = CaptureUndoManager.shared
    @State private var homeMeetingSearchQuery = ""
    @State private var homeMeetingPreviewLoadTask: Task<Void, Never>?
    @AppStorage(SpeechModelBetaPreferences.nemotronEnabledKey) private var betaNemotronModelEnabled = SpeechModelBetaPreferences.defaultNemotronEnabled
    @State private var modelCacheCleanupStatusDetails: String?
    @State private var captureLibraryMigrationStatusDetails: String?
    @State private var speakerInboxScrollRequest = 0
    @State private var speakerInboxScrollAwaitingQueue = false

    init(
        appState: TranscriptedAppState,
        navigation: TranscriptedSettingsNavigationModel,
        speakerPeopleModel: SpeakerPeopleSettingsViewModel,
        actions: TranscriptedSettingsActions
    ) {
        self.navigation = navigation
        self.speakerPeopleModel = speakerPeopleModel
        self.actions = actions
        self.appLogger = appState.logger
        _sttRouter = ObservedObject(wrappedValue: appState.sttRouter)
        _meetingSession = ObservedObject(wrappedValue: appState.meetingSession)
        _sparkleUpdater = ObservedObject(wrappedValue: appState.sparkleUpdater)
    }

    var body: some View {
        // Things-style two-tone split: solid darker sidebar, solid lighter
        // content, no toolbar chrome. The sidebar is permanent and narrow —
        // four destinations plus one quiet bottom line need no more.
        HStack(spacing: 0) {
            sidebarColumn
                .frame(width: 184)

            detailColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 880, minHeight: 640)
        .background(LibraryTokens.contentBackground.ignoresSafeArea())
        .sheet(item: $homeFeedbackTarget) { target in
            HomeFeedbackSheet(
                target: target,
                onCancel: {
                    homeFeedbackTarget = nil
                },
                onSubmit: { submission in
                    submitHomeFeedback(submission)
                }
            )
        }
        // One Home alert modifier, not two. Stacking multiple legacy `.alert(item:)`
        // on the same view shadows all but the last — which silently killed the
        // meeting-delete confirmation. `rootAlertBinding` routes
        // the two independent states through a single presenter so the active
        // one always shows; every existing call site stays unchanged.
        .alert(item: rootAlertBinding) { alert in
            switch alert {
            case .deleteConfirmation(let confirmation):
                // Cancel is the primary (default) button so Return lands on the
                // safe, reversible choice; the destructive action stays a clearly
                // marked `.destructive` secondary button.
                return Alert(
                    title: Text(confirmation.title),
                    message: Text(confirmation.message),
                    primaryButton: .cancel(),
                    secondaryButton: .destructive(Text(confirmation.confirmTitle)) {
                        confirmation.perform()
                    }
                )
            case .deleteFailure(let failure):
                return Alert(
                    title: Text(failure.title),
                    message: Text(failure.message),
                    primaryButton: .default(Text(failure.retryTitle)) {
                        failure.retry()
                    },
                    secondaryButton: .cancel(Text(failure.details == nil ? "Dismiss" : HomeActionFailureCopy.detailsTitle)) {
                        if let details = failure.details {
                            copyHomeFailureDetails(details)
                        }
                    }
                )
            }
        }
        .task(id: navigation.presentationID) {
            refreshState()
            expandGeneralDisclosureForPresentedPage()
            trackSettingsPageViewed(
                navigation.selectedPage,
                source: navigation.presentationSource,
                discoveredPage: navigation.presentedPage
            )
        }
        .onChange(of: navigation.selectedPage) { oldPage, page in
            if oldPage == .people && page != .people {
                SpeakerClipPlayback.stop()
            }
            refreshRecentCaptures()
            if page == .people {
                speakerPeopleModel.refresh()
            }
            if pageShowsAutoEnterSettings(page) {
                refreshAutoEnterPreferences(includeCandidates: true)
            }
            let isPresentationSelectionChange = page == navigation.presentedPage.consolidatedDestination
            trackSettingsPageViewed(
                page,
                source: "navigation",
                trackFeatureDiscovery: !isPresentationSelectionChange
            )
        }
        .onChange(of: meetingSession.lastSavedTranscriptURL) { _, newURL in
            refreshRecentCaptures(force: true)
            if SettingsSpeakerQueueRefreshPolicy.shouldRefreshAfterMeetingTranscriptSave(newURL) {
                speakerPeopleModel.refresh()
            }
        }
        .onChange(of: meetingSession.savedMeetingReplacementCommitCount) { _, _ in
            refreshRecentCaptures(force: true)
            speakerPeopleModel.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .dictationTranscriptDidSave)) { _ in
            refreshRecentCaptures(force: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .transcriptionModelPreferenceDidChange)) { _ in
            preferredTranscriptionModel = TranscriptionModelPreferences.preferredModel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .dockVisibilityPreferencesDidChange)) { _ in
            refreshDockVisibility()
        }
        .onReceive(NotificationCenter.default.publisher(for: .hotkeysDidChange)) { _ in
            refreshShortcutState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .localSpeakerPrefsDidChange)) { _ in
            splitLocalSpeakersEnabled = LocalSpeakerPreferences.isEnabled()
        }
        .onReceive(NotificationCenter.default.publisher(for: .autoCallDetectionPrefsDidChange)) { _ in
            autoDetectCallsEnabled = AutoCallDetectionPreferences.isEnabled()
        }
        .onReceive(NotificationCenter.default.publisher(for: .microphoneProcessingPrefsDidChange)) { _ in
            // Accepting the mid-meeting mic-boost prompt flips this preference
            // outside Settings; keep an open window's picker in sync.
            meetingMicProcessingMode = MicrophoneProcessingPreferences.mode()
        }
        .onReceive(NotificationCenter.default.publisher(for: .transcriptedPermissionsDidChange)) { _ in
            refreshPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
            refreshRecentCaptures()
            refreshShortcutState()
        }
        .onDisappear {
            homeDashboardRefreshTask?.cancel()
            homeDashboardRefreshTask = nil
            homeDashboardRefreshInFlight = false
            homeMeetingPreviewLoadTask?.cancel()
            homeMeetingPreviewLoadTask = nil
            homeViewModel.cancel()
        }
    }

    @ViewBuilder
    private var sidebarColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Room for the taller unified titlebar (and its inset traffic
            // lights) over the sidebar tone.
            Spacer().frame(height: 56)

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
    /// gear that opens the settings area, and the app version. When an
    /// update is ready, the version swaps for a clickable "Update ready".
    private var sidebarBottomLine: some View {
        let isInSettings = SettingsSidebarSection.isSettingsPage(navigation.selectedPage)
        return HStack(spacing: 8) {
            Button {
                trackSettingsAction("open_settings_area", page: navigation.selectedPage)
                navigation.selectedPage = .general
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isInSettings ? Color.primary : Color.primary.opacity(0.45))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Settings")
            .accessibilityLabel("Settings")
            .accessibilityIdentifier("transcripted.settings.sidebar.settings-toggle")

            if settingsFooterShowsUpdateBadge {
                Button {
                    guard settingsFooterActionEnabled else { return }
                    trackSettingsAction(settingsUpdateActionID, page: .about)
                    sparkleUpdater.performUserUpdateAction(surface: "settings_footer")
                } label: {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 6, height: 6)
                        Text("Update ready")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.primary.opacity(0.75))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!settingsFooterActionEnabled)
                .help("Install the downloaded update")
                .accessibilityIdentifier("transcripted.settings.footer.check-updates")
            } else {
                Text(appVersionText)
                    .font(.system(size: 11))
                    .foregroundStyle(LibraryTokens.ink3)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var appVersionText: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? ""
    }

    private var detailColumn: some View {
        ZStack {
            LibraryTokens.contentBackground.ignoresSafeArea()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if SettingsSidebarSection.isSettingsPage(navigation.selectedPage) {
                            settingsTabStrip
                        }
                        pageBody
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 14)
                    .padding(.bottom, 28)
                    .frame(maxWidth: 860, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .onChange(of: speakerInboxScrollRequest) { _, _ in
                    speakerInboxScrollAwaitingQueue = speakerPeopleModel.reviewQueueItems.isEmpty
                    scrollToSpeakerInbox(using: proxy)
                }
                .onChange(of: speakerPeopleModel.reviewQueueItems.count) { oldCount, newCount in
                    guard speakerInboxScrollAwaitingQueue, oldCount == 0, newCount > 0 else { return }
                    speakerInboxScrollAwaitingQueue = false
                    scrollToSpeakerInbox(using: proxy)
                }
            }
        }
    }

    private func sidebarRows(for pages: [TranscriptedSettingsPage]) -> some View {
        ForEach(pages) { page in
            Button {
                navigation.selectedPage = page
            } label: {
                SettingsSidebarRow(
                    page: page,
                    isSelected: navigation.selectedPage == page
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var settingsTabStrip: some View {
        HStack(spacing: 6) {
            ForEach(SettingsSidebarSection.settingsSections.flatMap(\.pages)) { page in
                let isSelected = navigation.selectedPage == page
                Button {
                    navigation.selectedPage = page
                } label: {
                    Text(page.title)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.75))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 5)
                        .background(
                            Capsule(style: .continuous)
                                .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.055))
                        )
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("transcripted.settings.tab.\(page.rawValue)")
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private var pageBody: some View {
        switch navigation.selectedPage {
        case .home:
            homePage
        case .dictations:
            dictationsPage
        case .general, .models, .shortcuts, .privacy, .beta:
            generalPage
        case .people:
            peoplePage
        case .storage:
            storagePage
        case .connectAgent:
            connectAgentPage
        case .about, .support:
            aboutPage
        }
    }

    private var homePage: some View {
        VStack(alignment: .leading, spacing: 20) {
            QuietHomeHeader(
                greeting: homeGreeting,
                capturesToday: homeViewModel.todayDictationCount + homeViewModel.todayMeetingCount,
                attentionTitle: homeAttentionIssues.first?.title,
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
                }
            )
            .padding(.top, 8)

            if let warning = homeViewModel.scanWarning {
                HomeScanWarningCard(
                    model: warning,
                    onRetry: {
                        trackSettingsAction("home_scan_warning_retry", page: .home)
                        homeViewModel.retryScan()
                    },
                    onReveal: {
                        trackSettingsAction("home_scan_warning_reveal", page: .home)
                        NSWorkspace.shared.activateFileViewerSelecting([MeetingStoragePaths.transcriptsFolder])
                    },
                    onDismiss: {
                        trackSettingsAction("home_scan_warning_dismiss", page: .home)
                        homeViewModel.dismissScanWarning()
                    }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if let activity = homeTranscriptionActivity {
                QuietWorkingRow(
                    title: activity.title,
                    status: activity.status,
                    progress: activity.progress,
                    onCancel: homeTranscriptionActivityIsCancellable
                        ? {
                            trackSettingsAction("cancel_current_activity", page: .home)
                            meetingSession.cancelActiveTranscription(reason: .userRequested)
                        }
                        : nil,
                    recordingElapsed: meetingSession.isRecording
                        ? QuietWorkingRow.formatElapsed(meetingSession.recordingDuration)
                        : nil
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
        .homeBackgroundTapCatcher {
            if homeExpandedMeetingID != nil {
                collapseHomeMeetingExpansion()
            }
        }
        .onDisappear {
            collapseHomeMeetingExpansion()
        }
        .task(id: navigation.homeFindFocusToken) {
            guard navigation.homeFindFocusToken > homeFindConsumedFocusToken else { return }
            homeFindConsumedFocusToken = navigation.homeFindFocusToken
            homeFindIsVisible = true
            homeFindFieldFocusToken += 1
        }
        .animation(.snappy(duration: 0.22), value: homeTranscriptionActivity)
    }

    /// Show the meetings filter once there is at least one loaded meeting to
    /// filter, or while a query is active so the user can always clear it.
    private var homeMeetingSearchIsAvailable: Bool {
        !homeMeetingSearchQuery.isEmpty
            || !homeViewModel.meetingDaySections.isEmpty
            || !meetingSession.failedMeetings.isEmpty
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
                    failureMessage: SettingsArtifactMessage.dictationFileNotFound
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
    /// grace window.
    private func deleteDictationWithUndo(_ entry: SavedDictationEntry) {
        trackSettingsAction("delete_dictation_confirm", page: navigation.selectedPage)
        do {
            let undoPayload = try DictationTranscriptStore.deleteEntryReversibly(entry)
            let preview = QuietDictationLibraryFormatting.truncated(
                QuietDictationLibraryFormatting.firstLine(of: entry.text, fallback: entry.title),
                maxLength: 34
            )
            captureUndo.stage(
                id: DictationUndoID.id(for: entry),
                message: CaptureUndoMessage.deleted(preview),
                undoAction: {
                    do {
                        try DictationTranscriptStore.restoreDeletedEntry(undoPayload)
                    } catch {
                        presentHomeDeleteFailure(
                            title: "Could not restore dictation",
                            error: error,
                            retry: { refreshRecentCaptures(force: true) }
                        )
                    }
                    refreshRecentCaptures(force: true)
                },
                finalize: {
                    refreshRecentCaptures(force: true)
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

    private var homeMeetingsListSection: some View {
        let isSearchingMeetings = !homeMeetingSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let visibleRowIDs = Set(homeMeetingDaySections.flatMap { $0.items }.map(\.id))
        // Undo offers whose meeting is no longer in the scanned sections (a
        // background rescan during the grace window dropped the trashed
        // file). Render them here so the Undo affordance never disappears
        // before its window closes.
        let orphanedOffers = captureUndo.offers.filter {
            !DictationUndoID.isDictationUndoID($0.id) && !visibleRowIDs.contains($0.id)
        }
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(orphanedOffers) { offer in
                UndoLineView(offer: offer, manager: captureUndo)
            }
            homeMeetingsList(isSearchingMeetings: isSearchingMeetings)
        }
    }

    private func homeMeetingsList(isSearchingMeetings: Bool) -> some View {
        HomeCaptureListSection(
            sections: homeMeetingDaySections,
            emptyMessage: isSearchingMeetings ? HomeCaptureListCopy.noMeetingMatches : HomeCaptureListCopy.emptyMeetings,
            emptyState: isSearchingMeetings ? nil : HomeListEmptyState(
                symbolName: "waveform",
                title: "No meetings yet",
                message: "Record a meeting or transcribe an existing audio file. Transcripted labels each speaker and saves the transcript here.",
                actionTitle: "Start a meeting",
                automationIdentifier: "transcripted.home.meetings.empty.start",
                action: {
                    trackSettingsAction("empty_start_meeting", page: .home)
                    actions.startMeeting()
                },
                secondaryActionTitle: "Transcribe audio file",
                secondaryAutomationIdentifier: "transcripted.home.meetings.empty.import-audio",
                secondaryAction: {
                    trackSettingsAction("empty_import_audio", page: .home)
                    actions.importAudioFile()
                }
            ),
            isLoading: homeViewModel.isLoading,
            isLoadingMore: homeViewModel.isLoadingMore,
            canLoadMore: homeViewModel.canLoadMoreMeetings,
            getID: { AnyHashable($0.id) },
            onLoadMore: {
                trackSettingsAction("load_more_meetings", page: navigation.selectedPage)
                homeViewModel.loadMoreMeetings()
            }
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
                    onCopy: { handleCopyMeeting(meeting) },
                    onRevealInFinder: {
                        trackSettingsAction("reveal_meeting_in_finder", page: .home)
                        _ = revealOwnFile(
                            candidateURLs: [meeting.transcriptURL],
                            failureTitle: "Could not show file",
                            failureMessage: SettingsArtifactMessage.meetingTranscriptNotFound
                        )
                    },
                    onCollapse: { collapseHomeMeetingExpansion() },
                    onRename: { newTitle in
                        // Don't drop a rename committed before the async
                        // preview load finishes — the item carries everything
                        // the rename needs.
                        let preview = (homeExpandedMeetingPreview?.id == meeting.id
                            ? homeExpandedMeetingPreview
                            : nil) ?? HomeMeetingPreview(item: meeting, markdown: "")
                        renameMeetingPreview(preview, to: newTitle)
                    },
                    menuItems: meetingRowMenuItems(for: meeting)
                )
            } else {
                QuietMeetingRow(
                    item: meeting,
                    isCopied: homeCopiedRowID == meeting.id,
                    isExpanded: false,
                    onOpen: { toggleHomeMeetingExpansion(meeting) },
                    onCopy: { handleCopyMeeting(meeting) },
                    menuItems: meetingRowMenuItems(for: meeting),
                    showsMicBoostHint: RecentMeetingMicBoostHintPolicy.shouldOfferEnableAction(
                        audioHealth: meeting.audioHealth,
                        voiceProcessingPreferenceEnabled: meetingMicProcessingMode.usesAppleVoiceProcessing
                    )
                )
            }
        case .failed(let failedMeeting):
            HomeFailedMeetingInlineRow(
                item: failedMeeting,
                canRetry: canRetryFailedMeetings,
                retryUnavailableReason: failedMeetingRetryUnavailableReason,
                onRetry: {
                    trackSettingsAction("home_retry_failed_meeting", page: navigation.selectedPage)
                    retryFailedMeeting(failedMeeting)
                },
                onRevealAudio: {
                    trackSettingsAction("home_reveal_failed_meeting_audio", page: navigation.selectedPage)
                    revealFailedMeetingAudio(failedMeeting)
                },
                onClear: { requestClearFailedMeeting(failedMeeting) },
                audioAttachment: failedMeetingAudioAttachment(for: failedMeeting)
            )
        }
    }


    private var homeGreeting: String {
        HomeCanvasGreeting.text(
            hour: Calendar.current.component(.hour, from: Date()),
            firstName: homeViewModel.welcomeName
        )
    }

    private func reviewHomeAttentionIssue(_ issue: HomeAttentionIssue) {
        switch issue.destination {
        case .failedMeetings:
            // Failed meetings live inline in the day list now; the link just
            // makes sure the user is on Home where those rows are.
            trackSettingsAction("open_needs_attention_failed_meetings", page: .home)
            navigation.selectedPage = .home
        case .speakers:
            openHomeSpeakerReview(actionName: "open_needs_attention_speakers")
        case .privacy:
            trackSettingsAction("open_needs_attention_privacy", page: .home)
            showGeneralPrivacySettings = true
            navigation.selectedPage = .general
        case .models:
            trackSettingsAction("open_needs_attention_models", page: .home)
            showGeneralModelSettings = true
            navigation.selectedPage = .general
        }
    }

    private func openHomeSpeakerReview(actionName: String) {
        trackSettingsAction(actionName, page: navigation.selectedPage)
        speakerPeopleModel.refresh()
        speakerPeopleModel.searchText = ""
        navigation.selectedPage = .people
        requestSpeakerInboxFocus()
    }

    private func requestSpeakerInboxFocus() {
        speakerInboxScrollRequest += 1
    }

    private func scrollToSpeakerInbox(using proxy: ScrollViewProxy) {
        Task { @MainActor in
            await Task.yield()
            withAnimation(.snappy(duration: 0.22)) {
                proxy.scrollTo(SpeakerPeopleSettingsSection.ScrollTarget.reviewQueue, anchor: .top)
            }
        }
    }

    private func handleCopyDictation(_ entry: SavedDictationEntry) {
        trackSettingsAction("copy_dictation", page: .home)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.text, forType: .string)
        flashCopied(rowID: entry.id)
    }

    private func handleCopyMeeting(_ item: RecentMeetingItem) {
        trackSettingsAction("copy_meeting", page: .home)
        // Resolution + the transcript read (and bundle assembly) touch disk and
        // can be sizeable for long meetings, so do them off the main thread and
        // hop back only to write the clipboard / update UI state.
        Task { @MainActor in
            let result = await Self.loadCopyMeetingText(for: item)
            switch result {
            case .missingFile:
                // Resolution failed so a row whose path drifted (restyle/rename
                // after scanning) still copies, and a genuinely missing file
                // surfaces an error instead of silently no-op'ing on the empty
                // clipboard.
                ActivationTelemetry.trackHabitLoopAction(
                    actionKind: .whatDidIPromise,
                    surface: .homeRow,
                    artifactKind: .meeting,
                    artifactDate: item.date,
                    result: .failed
                )
                ActivationTelemetry.trackAgentPromptAction(
                    promptKind: .meetingBundle,
                    actionKind: .copied,
                    agentTarget: .localAgent,
                    surface: .homeRow,
                    result: .failed,
                    artifactKind: .meeting
                )
                presentHomeActionFailure(
                    title: "Could not copy meeting",
                    message: SettingsArtifactMessage.meetingTranscriptNotFound,
                    retry: {
                        handleCopyMeeting(item)
                    }
                )
            case .readFailure:
                ActivationTelemetry.trackHabitLoopAction(
                    actionKind: .whatDidIPromise,
                    surface: .homeRow,
                    artifactKind: .meeting,
                    artifactDate: item.date,
                    result: .failed
                )
                ActivationTelemetry.trackAgentPromptAction(
                    promptKind: .meetingBundle,
                    actionKind: .copied,
                    agentTarget: .localAgent,
                    surface: .homeRow,
                    result: .failed,
                    artifactKind: .meeting
                )
                presentHomeActionFailure(
                    title: "Could not copy meeting",
                    message: "Transcripted found this meeting's transcript but couldn't read it. The file may be open exclusively elsewhere or corrupted.",
                    retry: {
                        handleCopyMeeting(item)
                    }
                )
            case .success(let text, let usedBundle):
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                ActivationTelemetry.trackHabitLoopAction(
                    actionKind: .whatDidIPromise,
                    surface: .homeRow,
                    artifactKind: .meeting,
                    artifactDate: item.date
                )
                ActivationTelemetry.trackAgentPromptAction(
                    promptKind: usedBundle ? .meetingBundle : .meetingMarkdown,
                    actionKind: .copied,
                    agentTarget: .localAgent,
                    surface: .homeRow,
                    result: usedBundle ? .success : .fallbackCopied,
                    artifactKind: .meeting
                )
                flashCopied(rowID: item.id)
            }
        }
    }

    private func handleRetranscribeMeeting(_ item: RecentMeetingItem) {
        guard !hasSpeakerReviewWork(for: item) else {
            openHomeSpeakerReview(actionName: "open_speaker_review_before_retranscribe")
            return
        }

        guard let input = item.audio?.retranscriptionInput else {
            presentHomeActionFailure(
                title: "Could not re-transcribe meeting",
                message: "Transcripted couldn't find the retained audio for this meeting. It may have been recompressed or removed by the audio-retention setting.",
                retry: {
                    handleRetranscribeMeeting(item)
                }
            )
            return
        }

        // The recorded input paths can drift after scanning (a plain move keeps
        // the extension; the resolver re-finds it). The system track is required,
        // so a missing/unresolvable one surfaces an error instead of a silent
        // beep; the optional mic track is resolved when present.
        let micURL = input.micURL.flatMap { OwnFileResolver.resolveExistingFile(candidateURLs: [$0]) }
        guard let systemURL = OwnFileResolver.resolveExistingFile(candidateURLs: [input.systemURL]) else {
            presentHomeActionFailure(
                title: "Could not re-transcribe meeting",
                message: SettingsArtifactMessage.meetingRetainedAudioNotFound,
                retry: {
                    handleRetranscribeMeeting(item)
                }
            )
            return
        }

        trackSettingsAction("retranscribe_saved_meeting", page: .home)
        Task { @MainActor in
            let didStart = await meetingSession.retranscribeSavedMeeting(
                micAudioURL: micURL,
                systemAudioURL: systemURL,
                title: item.title,
                transcriptURL: item.transcriptURL,
                recordingDate: item.startDate ?? item.date
            )
            if !didStart {
                presentHomeActionFailure(
                    title: "Could not re-transcribe meeting",
                    message: "Transcripted couldn't start re-transcription from the retained audio. The saved files may be incomplete or already in use.",
                    retry: {
                        handleRetranscribeMeeting(item)
                    }
                )
            }
        }
    }

    /// Expand a capture in place (quiet-library interaction). Clicking the
    /// same row again, pressing Esc, or expanding another row collapses it.
    private func toggleHomeMeetingExpansion(_ item: RecentMeetingItem) {
        if homeExpandedMeetingID == item.id {
            collapseHomeMeetingExpansion()
            return
        }
        trackSettingsAction("preview_recent_meeting", page: .home)
        withAnimation(.snappy(duration: 0.22)) {
            homeExpandedMeetingID = item.id
        }
        homeExpandedMeetingPreview = nil
        homeMeetingPreviewLoadTask?.cancel()
        homeMeetingPreviewLoadTask = Task { @MainActor in
            let readResult = await Self.readMeetingMarkdown(at: item.transcriptURL)
            guard !Task.isCancelled, homeExpandedMeetingID == item.id else { return }
            switch readResult {
            case .success(let markdown):
                homeExpandedMeetingPreview = HomeMeetingPreview(item: item, markdown: markdown)
                ActivationTelemetry.trackArtifactAction(
                    artifactKind: .meeting,
                    actionKind: .preview,
                    surface: .homeRow,
                    artifactDate: item.date,
                    result: .success
                )
                ActivationTelemetry.trackHabitLoopAction(
                    actionKind: .openRecentMeeting,
                    surface: .homeRow,
                    artifactKind: .meeting,
                    artifactDate: item.date
                )
            case .failure(let message):
                homeExpandedMeetingPreview = HomeMeetingPreview(item: item, markdown: "", readError: message)
                ActivationTelemetry.trackArtifactAction(
                    artifactKind: .meeting,
                    actionKind: .preview,
                    surface: .homeRow,
                    artifactDate: item.date,
                    result: .failed
                )
                ActivationTelemetry.trackHabitLoopAction(
                    actionKind: .openRecentMeeting,
                    surface: .homeRow,
                    artifactKind: .meeting,
                    artifactDate: item.date,
                    result: .failed
                )
            }
        }
    }

    private func collapseHomeMeetingExpansion() {
        homeMeetingPreviewLoadTask?.cancel()
        MeetingAudioPlayback.shared.stop()
        withAnimation(.snappy(duration: 0.22)) {
            homeExpandedMeetingID = nil
        }
        homeExpandedMeetingPreview = nil
    }

    private static func readMeetingMarkdown(at url: URL) async -> HomeMeetingMarkdownReadResult {
        await Task.detached(priority: .userInitiated) {
            // Follow a drifted transcript (restyle/rename after scanning) so the
            // preview still loads instead of falling straight to a read error.
            let resolved = OwnFileResolver.resolveExistingFile(candidateURLs: [url]) ?? url
            do {
                return .success(try String(contentsOf: resolved, encoding: .utf8))
            } catch {
                return .failure(error.localizedDescription)
            }
        }.value
    }

    private enum HomeCopyMeetingReadResult {
        case missingFile
        case readFailure
        case success(text: String, usedBundle: Bool)
    }

    private static func loadCopyMeetingText(for item: RecentMeetingItem) async -> HomeCopyMeetingReadResult {
        await Task.detached(priority: .userInitiated) {
            guard let transcriptURL = OwnFileResolver.resolveExistingFile(candidateURLs: [item.transcriptURL]) else {
                return .missingFile
            }
            if let bundle = AgentConnectionGuide.portableMeetingBundle(
                title: item.title,
                date: item.date,
                transcriptURL: transcriptURL
            ) {
                return .success(text: bundle, usedBundle: true)
            } else if let raw = try? String(contentsOf: transcriptURL, encoding: .utf8) {
                return .success(text: raw, usedBundle: false)
            } else {
                return .readFailure
            }
        }.value
    }

    private func submitHomeFeedback(_ submission: HomeFeedbackSubmission) {
        trackSettingsAction("submit_home_feedback", page: .home)
        EventReporter.shared.capture(
            level: .info,
            engine: "feedback",
            event: "capture_feedback_prepared",
            message: "User prepared capture feedback",
            context: [
                "source_kind": submission.target.sourceKind,
                "issue_kind": submission.issueKind.rawValue,
                "include_diagnostics": submission.includeDiagnostics ? "true" : "false",
            ]
        )

        let report = FeedbackReport(
            sourceKind: submission.target.sourceKind,
            referenceID: submission.target.referenceID,
            occurredAt: submission.target.createdAt,
            issueKind: submission.issueKind.label,
            userNotes: submission.notes,
            appVersion: TranscriptedSupportActions.appVersionDescription,
            includeDiagnostics: submission.includeDiagnostics
        )

        guard let url = FeedbackIssueBuilder.emailURL(
            report: report,
            rawLogLines: submission.includeDiagnostics ? appLogger.entries : nil
        ) else {
            return
        }

        homeFeedbackTarget = nil
        NSWorkspace.shared.open(url)
    }

    private func flashCopied(rowID: String) {
        homeCopiedRowID = rowID
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if homeCopiedRowID == rowID {
                homeCopiedRowID = nil
            }
        }
    }

    private func dictationRowMenuItems(for entry: SavedDictationEntry) -> [HomeRowMenuItem] {
        [
            HomeRowMenuItem(title: "Open Markdown", symbolName: "doc.text") {
                trackSettingsAction("open_recent_dictation_file", page: .home)
                let didOpen = openOwnFile(
                    candidateURLs: [entry.url],
                    failureTitle: "Could not open dictation",
                    failureMessage: SettingsArtifactMessage.dictationFileNotFound
                )
                ActivationTelemetry.trackArtifactAction(
                    artifactKind: .dictation,
                    actionKind: .openMarkdown,
                    surface: .homeMenu,
                    artifactDate: entry.createdAt,
                    result: didOpen ? .success : .failed
                )
                ActivationTelemetry.trackHabitLoopAction(
                    actionKind: .reviewYesterday,
                    surface: .homeMenu,
                    artifactKind: .dictation,
                    artifactDate: entry.createdAt,
                    result: didOpen ? .success : .failed
                )
            },
            HomeRowMenuItem(title: "Reveal in Finder", symbolName: "folder") {
                trackSettingsAction("reveal_dictation_in_finder", page: .home)
                let didReveal = revealOwnFile(
                    candidateURLs: [entry.url],
                    failureTitle: "Could not show dictation",
                    failureMessage: SettingsArtifactMessage.dictationFileNotFound
                )
                ActivationTelemetry.trackArtifactAction(
                    artifactKind: .dictation,
                    actionKind: .revealFolder,
                    surface: .homeMenu,
                    artifactDate: entry.createdAt,
                    result: didReveal ? .success : .failed
                )
            }
            // No Report issue and no Delete here: dictations are quiet rows;
            // the Dictations page drives per-entry delete itself through the
            // inline-undo flow (QuietDictationLibrary), with no dialog.
        ]
    }

    private func meetingRowMenuItems(for item: RecentMeetingItem) -> [HomeRowMenuItem] {
        var items: [HomeRowMenuItem] = []
        let hasPendingSpeakerReview = hasSpeakerReviewWork(for: item)

        items.append(contentsOf: [
            HomeRowMenuItem(title: "Report issue", symbolName: "flag") {
                trackSettingsAction("flag_meeting", page: .home)
                homeFeedbackTarget = HomeFeedbackTarget.meeting(item)
            },
            HomeRowMenuItem(title: "Show transcript in Finder", symbolName: "doc.text") {
                trackSettingsAction("reveal_meeting_in_finder", page: .home)
                let didReveal = revealOwnFile(
                    candidateURLs: HomeMeetingRowActionTargets.transcriptRevealURLs(for: item),
                    failureTitle: "Could not show transcript",
                    failureMessage: SettingsArtifactMessage.meetingTranscriptNotFound
                )
                ActivationTelemetry.trackArtifactAction(
                    artifactKind: .meeting,
                    actionKind: .revealFolder,
                    surface: .homeMenu,
                    artifactDate: item.date,
                    result: didReveal ? .success : .failed
                )
                ActivationTelemetry.trackHabitLoopAction(
                    actionKind: .openRecentMeeting,
                    surface: .homeMenu,
                    artifactKind: .meeting,
                    artifactDate: item.date,
                    result: didReveal ? .success : .failed
                )
            }
        ])

        if hasPendingSpeakerReview {
            items.append(
                HomeRowMenuItem(title: "Review speakers", symbolName: "person.crop.circle.badge.questionmark") {
                    openHomeSpeakerReview(actionName: "review_meeting_speakers_row")
                }
            )
        }

        if RecentMeetingMicBoostHintPolicy.shouldOfferEnableAction(
            audioHealth: item.audioHealth,
            voiceProcessingPreferenceEnabled: meetingMicProcessingMode.usesAppleVoiceProcessing
        ) {
            items.append(
                HomeRowMenuItem(title: "Use enhanced mic pickup next time", symbolName: "mic.badge.plus") {
                    trackSettingsToggle("meeting_voice_processing", enabled: true, page: .home)
                    MicrophoneProcessingPreferences.setVoiceProcessingEnabled(true)
                    meetingMicProcessingMode = .appleVoiceProcessing
                }
            )
        }

        if let audio = item.audio {
            let audioRevealURLs = HomeMeetingRowActionTargets.audioRevealURLs(for: item)
            if !audioRevealURLs.isEmpty {
                if audio.retranscriptionInput != nil {
                    items.append(
                        HomeRowMenuItem(
                            title: "Re-transcribe with speaker ID",
                            symbolName: "person.2.fill",
                            isEnabled: RecentMeetingRetranscriptionMenuActionPolicy.isEnabled(
                                globalUnavailableReason: savedMeetingRetranscriptionUnavailableReason,
                                hasSpeakerReviewWork: hasPendingSpeakerReview
                            )
                        ) {
                            handleRetranscribeMeeting(item)
                        }
                    )
                }

                items.append(
                    HomeRowMenuItem(title: "Show audio in Finder", symbolName: "waveform") {
                        trackSettingsAction("reveal_meeting_audio_in_finder", page: .home)
                        revealOwnFile(
                            candidateURLs: audioRevealURLs,
                            failureTitle: "Could not show audio",
                            failureMessage: SettingsArtifactMessage.meetingRetainedAudioNotFound
                        )
                    }
                )
            }
        }

        items.append(
            HomeRowMenuItem(title: "Delete meeting", symbolName: "trash", isDestructive: true) {
                trackSettingsAction("delete_meeting_request", page: .home)
                deleteMeetingWithUndo(item)
            }
        )

        return items
    }

    /// Quiet-library delete: trash immediately, offer an inline Undo for a few
    /// seconds instead of a confirmation dialog. Files move to the Trash (not
    /// a permanent delete), so even a missed Undo window is recoverable.
    ///
    /// Known limitation (pre-existing class of race, unchanged from the old
    /// confirm-dialog path): deletion does not coordinate with
    /// `MeetingTranscriptFileUpdateSerializer`, so an in-flight background
    /// transcript restyle could theoretically recreate the file it just
    /// rewrote. The next refresh re-scans disk and re-lists it, so nothing is
    /// lost — the row reappears.
    private func deleteMeetingWithUndo(_ item: RecentMeetingItem) {
        if homeExpandedMeetingID == item.id {
            collapseHomeMeetingExpansion()
        }
        Task { @MainActor in
            // Planning hashes retained audio files for duplicate signatures —
            // keep that off the main thread for large libraries.
            let plan = await Task.detached(priority: .userInitiated) {
                HomeMeetingDeletion.plan(for: item)
            }.value
            MeetingAudioPlayback.shared.stopIfActive(attachmentIDs: Set(plan.audioAttachmentIDs))
            let urls = plan.transcriptURLs + plan.summaryURLs + plan.audioDirectoryURLs
            do {
                _ = try captureUndo.deleteFiles(
                    id: item.id,
                    urls: urls,
                    message: CaptureUndoMessage.deleted(item.title),
                    finalize: {
                        refreshRecentCaptures(force: true)
                    }
                )
                trackSettingsAction("delete_meeting_confirm", page: .home)
            } catch {
                presentHomeDeleteFailure(
                    title: "Could not delete meeting",
                    error: error,
                    retry: { deleteMeetingWithUndo(item) }
                )
            }
        }
    }

    // MARK: - Home root alert

    /// The Home surface drives two independent confirmation/failure alerts
    /// (`homeDeleteConfirmation`, `homeDeleteFailure`).
    /// They are presented through a *single* `.alert(item:)` because SwiftUI
    /// shadows all but the last when several legacy `.alert(item:)` are stacked
    /// on one view — that is what silently broke the meeting-delete confirmation.
    private enum RootAlert: Identifiable {
        case deleteConfirmation(HomeDeleteConfirmation)
        case deleteFailure(HomeDeleteFailure)

        var id: String {
            switch self {
            case .deleteConfirmation(let confirmation): return "delete-confirmation-\(confirmation.id)"
            case .deleteFailure(let failure): return "delete-failure-\(failure.id)"
            }
        }
    }

    /// Snapshot of which Home alert states are currently set, fed to
    /// `HomeRootAlertPolicy` so presentation priority and dismissal stay in sync.
    private var rootAlertStates: HomeRootAlertStates {
        HomeRootAlertStates(
            hasDeleteConfirmation: homeDeleteConfirmation != nil,
            hasDeleteFailure: homeDeleteFailure != nil
        )
    }

    /// Whichever Home alert should present, in `HomeRootAlertPolicy` priority order.
    private var activeRootAlert: RootAlert? {
        switch HomeRootAlertPolicy.activeSlot(rootAlertStates) {
        case .deleteConfirmation: return homeDeleteConfirmation.map(RootAlert.deleteConfirmation)
        case .deleteFailure: return homeDeleteFailure.map(RootAlert.deleteFailure)
        case .none: return nil
        }
    }

    /// Binds the single alert presenter to the two underlying states. On
    /// dismissal it clears only the alert being dismissed, not both: a
    /// confirm action can set a follow-up alert (e.g. a delete failure) before
    /// SwiftUI writes nil, and clearing everything would wipe it before it can
    /// present. Call sites keep setting their own `@State` directly.
    private var rootAlertBinding: Binding<RootAlert?> {
        Binding(
            get: { activeRootAlert },
            set: { newValue in
                guard newValue == nil else { return }
                switch activeRootAlert {
                case .deleteConfirmation: homeDeleteConfirmation = nil
                case .deleteFailure: homeDeleteFailure = nil
                case .none: break
                }
            }
        )
    }

    private func renameMeetingPreview(_ preview: HomeMeetingPreview, to rawTitle: String) {
        trackSettingsAction("rename_recent_meeting", page: .home)

        let sourceURL = preview.transcriptURL
        let attachmentID = preview.audio?.id

        let renameTask = Task.detached(priority: .userInitiated) { () throws -> HomeMeetingRenameResult in
            if let attachmentID {
                await MainActor.run {
                    MeetingAudioPlayback.shared.stopIfActive(attachmentIDs: [attachmentID])
                }
            }
            return try HomeMeetingRename.rename(transcriptAt: sourceURL, to: rawTitle)
        }

        Task { @MainActor in
            do {
                let result = try await renameTask.value
                let audio = MeetingAudioArchiveResolver.attachment(forTranscript: result.transcriptURL)
                if homeExpandedMeetingID == preview.id || homeExpandedMeetingPreview?.id == preview.id {
                    // Base the update on the loaded preview when it arrived
                    // meanwhile (keeps the transcript body); fall back to the
                    // rename's own preview otherwise.
                    let base = (homeExpandedMeetingPreview?.id == preview.id
                        ? homeExpandedMeetingPreview
                        : nil) ?? preview
                    homeExpandedMeetingPreview = base.updatingAfterRename(
                        transcriptURL: result.transcriptURL,
                        title: result.title,
                        audio: audio
                    )
                    // The expansion is keyed by the row id (transcript path),
                    // which the rename just changed — follow it so the card
                    // stays open on the renamed capture after refresh.
                    homeExpandedMeetingID = result.transcriptURL.path
                }
                refreshRecentCaptures(force: true)
            } catch HomeMeetingRenameError.emptyTitle {
                // Empty title is treated as a cancelled edit — leave everything untouched.
            } catch {
                refreshRecentCaptures(force: true)
                presentHomeDeleteFailure(
                    title: "Could not rename meeting",
                    error: error,
                    retry: {
                        renameMeetingPreview(preview, to: rawTitle)
                    }
                )
            }
        }
    }

    private func failedMeetingAudioAttachment(
        for item: MeetingSessionController.FailedMeetingItem
    ) -> MeetingAudioAttachment? {
        MeetingAudioAttachment.retainedAudio(urls: item.audioURLs)
    }

    private func revealFailedMeetingAudio(_ item: MeetingSessionController.FailedMeetingItem) {
        revealOwnFile(
            candidateURLs: HomeMeetingRowActionTargets.audioRevealURLs(audioURLs: item.audioURLs),
            failureTitle: "Could not show audio",
            failureMessage: "Transcripted couldn't find this meeting's retained audio on disk. It may have been moved, recompressed, or already cleared."
        )
    }

    private func requestClearFailedMeeting(_ item: MeetingSessionController.FailedMeetingItem) {
        trackSettingsAction("home_delete_failed_meeting_request", page: .home)
        let presentation = HomeDeleteConfirmationPolicy.failedMeeting
        homeDeleteConfirmation = HomeDeleteConfirmation(
            title: presentation.title,
            message: presentation.message,
            confirmTitle: presentation.confirmTitle
        ) {
            trackSettingsAction("home_delete_failed_meeting_confirm", page: .home)
            clearFailedMeeting(item)
        }
    }

    private func clearFailedMeeting(_ item: MeetingSessionController.FailedMeetingItem) {
        if let audio = failedMeetingAudioAttachment(for: item),
           MeetingAudioPlayback.shared.isActive(audio) {
            MeetingAudioPlayback.shared.stop()
        }

        let didClear = meetingSession.deleteFailedMeeting(id: item.id)

        if !didClear {
            presentHomeActionFailure(
                title: "Could not delete failed meeting",
                message: "Transcripted couldn't remove this meeting. Check that your capture folder is available, then try again.",
                retry: {
                    clearFailedMeeting(item)
                }
            )
        } else {
            ActivationTelemetry.trackWorkflowAbandoned(
                workflowKind: .failedMeetingRetry,
                stage: "retry_available",
                reasonKind: .deleted,
                surface: .home,
                priorReadyState: canRetryFailedMeetings ? "retry_ready" : "retry_blocked"
            )
        }
    }

    /// Reveals an app-owned capture artifact in Finder, tolerant to the file
    /// having moved since the row was scanned (transcript restyle/rename,
    /// WAV→M4A audio recompression). Never silently no-ops: if nothing on disk
    /// can be revealed it surfaces a failure alert instead of a dead click.
    @discardableResult
    private func revealOwnFile(
        candidateURLs: [URL],
        failureTitle: String,
        failureMessage: String
    ) -> Bool {
        switch OwnFileResolver.resolveForReveal(candidateURLs: candidateURLs) {
        case .reveal(let urls):
            NSWorkspace.shared.activateFileViewerSelecting(urls)
            return true
        case .unavailable:
            presentHomeActionFailure(
                title: failureTitle,
                message: failureMessage,
                retry: {
                    revealOwnFile(
                        candidateURLs: candidateURLs,
                        failureTitle: failureTitle,
                        failureMessage: failureMessage
                    )
                }
            )
            return false
        }
    }

    /// Opens an app-owned capture artifact, tolerant to a stem-only rename
    /// (e.g. WAV→M4A) since the row was scanned. Requires a real file — it will
    /// not open an enclosing folder — and surfaces a failure alert instead of a
    /// silent no-op when nothing on disk backs the URL.
    @discardableResult
    private func openOwnFile(
        candidateURLs: [URL],
        failureTitle: String,
        failureMessage: String
    ) -> Bool {
        guard let url = OwnFileResolver.resolveExistingFile(candidateURLs: candidateURLs) else {
            presentHomeActionFailure(
                title: failureTitle,
                message: failureMessage,
                retry: {
                    _ = openOwnFile(
                        candidateURLs: candidateURLs,
                        failureTitle: failureTitle,
                        failureMessage: failureMessage
                    )
                }
            )
            return false
        }
        return NSWorkspace.shared.open(url)
    }

    private func presentHomeDeleteFailure(
        title: String,
        error: Error,
        retry: @escaping () -> Void
    ) {
        presentHomeActionFailure(
            title: title,
            message: HomeActionFailureCopy.message(forFailureTitle: title),
            details: error.localizedDescription,
            retry: retry
        )
    }

    private func presentHomeActionFailure(
        title: String,
        message: String,
        details: String? = nil,
        retry: @escaping () -> Void
    ) {
        NSSound.beep()
        // Defer to the next runloop turn so a failure raised synchronously inside
        // an alert's confirm action lands after that alert finishes dismissing.
        // SwiftUI won't present a second alert during the first one's dismissal,
        // and the shared binding clears the dismissed alert on the same turn.
        DispatchQueue.main.async {
            homeDeleteFailure = HomeDeleteFailure(
                title: title,
                message: message,
                details: details,
                retry: retry
            )
        }
    }

    private func copyHomeFailureDetails(_ details: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(details, forType: .string)
    }

    /// Subtle "Copy Details" reveal shown under a failed settings-action status
    /// line. The raw error lives here, never inline in the status message; the
    /// action's own button (Set up / Remove / toggle) is the retry.
    @ViewBuilder
    private func settingsFailureDetailsButton(_ details: String?) -> some View {
        if let details {
            Button(SettingsActionFailureCopy.detailsTitle) {
                copyHomeFailureDetails(details)
            }
            .buttonStyle(.link)
            .font(.caption)
        }
    }

    private func retryFailedMeeting(_ item: MeetingSessionController.FailedMeetingItem) {
        let didStart = meetingSession.retryFailedMeeting(id: item.id)
        if !didStart {
            presentHomeActionFailure(
                title: "Could not retry meeting",
                message: failedMeetingRetryUnavailableReason
                    ?? "Transcripted could not start that retry. The saved audio may already be cleared.",
                retry: {
                    retryFailedMeeting(item)
                }
            )
        }
    }

    private var homeAttentionIssues: [HomeAttentionIssue] {
        var issues: [HomeAttentionIssue] = []

        if !missingRequiredPermissions.isEmpty {
            issues.append(
                HomeAttentionIssue(
                    id: "permissions",
                    title: "Permissions need attention",
                    detail: permissionsDetailLine,
                    tone: .warning,
                    destination: .privacy
                )
            )
        }

        if !meetingSession.failedMeetings.isEmpty {
            let count = meetingSession.failedMeetings.count
            issues.append(
                HomeAttentionIssue(
                    id: "failed-meetings",
                    title: count == 1 ? "1 meeting failed" : "\(count) meetings failed",
                    detail: count == 1
                        ? "Saved audio is waiting for review or retry."
                        : "\(count) saved recordings are waiting for review or retry.",
                    tone: .failure,
                    destination: .failedMeetings
                )
            )
        }

        let reviewCount = speakerPeopleModel.pendingVoiceGroups.count
        if reviewCount > 0 {
            issues.append(
                HomeAttentionIssue(
                    id: "speakers",
                    title: reviewCount == 1 ? "1 speaker needs a name" : "\(reviewCount) speakers need names",
                    detail: "Name saved speaker labels so transcripts read like a conversation.",
                    tone: .warning,
                    destination: .speakers
                )
            )
        }

        let modelCard = FirstRunExperience.modelCard(
            for: sttRouter.modelDownloadState,
            model: effectiveTranscriptionModel
        )
        if modelCard.tone == .failed {
            issues.append(
                HomeAttentionIssue(
                    id: "voice-model-failed",
                    title: "Voice model needs attention",
                    detail: modelCard.detail,
                    tone: .warning,
                    destination: .models
                )
            )
        } else if preferredTranscriptionModel != effectiveTranscriptionModel {
            issues.append(
                HomeAttentionIssue(
                    id: "voice-model-mismatch",
                    title: "Voice model mismatch",
                    detail: "\(preferredTranscriptionModel.title) is selected but \(effectiveTranscriptionModel.title) is being used.",
                    tone: .warning,
                    destination: .models
                )
            )
        }

        return issues
    }

    private var homeMeetingDaySections: [HomeDaySection<HomeMeetingListItem>] {
        let query = homeMeetingSearchQuery
        let savedMeetings = homeViewModel.meetingDaySections
            .flatMap { $0.items }
            .filter { HomeMeetingListFilter.matches(query: query, in: Self.searchFields(for: $0)) }
            .map(HomeMeetingListItem.saved)
        let failedMeetings = meetingSession.failedMeetings
            .filter { HomeMeetingListFilter.matches(query: query, in: Self.searchFields(for: $0)) }
            .map(HomeMeetingListItem.failed)
        let items = (savedMeetings + failedMeetings)
            .sorted { $0.date > $1.date }

        return HomeViewModel.groupByDay(items, dateForItem: \.date)
    }

    /// Already-loaded text fields the meetings filter matches against. Kept to
    /// metadata so filtering never touches transcript bodies on disk.
    private static func searchFields(for meeting: RecentMeetingItem) -> [String] {
        var fields = [meeting.title]
        fields.append(HomeMeetingListFilter.dateSearchText(for: meeting.date))
        return fields
    }

    private static func searchFields(for meeting: MeetingSessionController.FailedMeetingItem) -> [String] {
        [
            meeting.title,
            meeting.detail,
            meeting.meta,
            HomeMeetingListFilter.dateSearchText(for: meeting.timestamp)
        ]
    }

    private var canRetryFailedMeetings: Bool {
        failedMeetingRetryUnavailableReason == nil
    }

    private func hasSpeakerReviewWork(for meeting: RecentMeetingItem) -> Bool {
        guard speakerPeopleModel.hasLoadedProfiles else {
            return meeting.speakerStatus.needsReview
        }
        return speakerPeopleModel.hasPendingReview(forTranscript: meeting.transcriptURL)
    }

    private var canRetranscribeSavedMeetings: Bool {
        savedMeetingRetranscriptionUnavailableReason == nil
    }

    private var failedMeetingRetryUnavailableReason: String? {
        if sttRouter.isRecording || sttRouter.isTranscribing {
            return "Wait for the current dictation to finish before retrying a failed meeting."
        }
        if meetingSession.isRecording {
            return "Stop the current recording before retrying a failed meeting."
        }
        if meetingSession.hasRuntimeDiagnosticsWork {
            return "Wait for the current meeting to finish saving or transcribing before retrying."
        }
        if meetingSession.isSpeakerReviewPending {
            return "Finish the speaker review window before retrying a failed meeting."
        }
        return nil
    }

    private var savedMeetingRetranscriptionUnavailableReason: String? {
        SavedMeetingRetranscriptionAvailabilityPolicy.unavailableReason(
            isDictationActive: sttRouter.isRecording || sttRouter.isTranscribing,
            isMeetingRecording: meetingSession.isRecording,
            isPreparingModels: meetingSession.state == .loadingModels,
            hasMeetingWork: meetingSession.hasRuntimeDiagnosticsWork,
            isSpeakerReviewPending: meetingSession.isSpeakerReviewPending
        )
    }

    private var generalPage: some View {
        GeneralSettingsPage(
            launchAtLoginEnabled: Binding(
                get: { launchAtLoginEnabled },
                set: { updateLaunchAtLogin($0) }
            ),
            launchAtLoginStatus: launchAtLoginStatus,
            showTranscriptedInDock: persistedSettingsBinding(
                $showTranscriptedInDock,
                persist: { DockVisibilityPreferences.setVisible($0) },
                track: { trackSettingsToggle("show_in_dock", enabled: $0, page: .general) }
            ),
            uiSoundsEnabled: persistedSettingsBinding(
                $uiSoundsEnabled,
                persist: { UISoundPreferences.setEnabled($0) },
                track: { trackSettingsToggle("dictation_sounds", enabled: $0, page: .general) }
            ),
            dictationCleanupEnabled: persistedSettingsBinding(
                $dictationCleanupEnabled,
                persist: { DictationCleanupPreferences.setEnabled($0) },
                track: { trackSettingsToggle("dictation_cleanup", enabled: $0, page: .general) }
            ),
            dictationOverlayMode: persistedSettingsBinding(
                $dictationOverlayMode,
                persist: { DictationOverlayPresentationPreferences.setMode($0) },
                track: { _ in trackSettingsAction("change_dictation_overlay_mode", page: .general) }
            ),
            confirmQuitDuringMeetingEnabled: persistedSettingsBinding(
                $confirmQuitDuringMeetingEnabled,
                persist: { QuitConfirmationPreferences.setConfirmQuitDuringActiveMeetingRecording($0) },
                track: { trackSettingsToggle("meeting_quit_confirmation", enabled: $0, page: .general) }
            ),
            autoDetectCallsEnabled: persistedSettingsBinding(
                $autoDetectCallsEnabled,
                persist: { AutoCallDetectionPreferences.setEnabled($0) },
                track: { trackSettingsToggle("auto_call_detection", enabled: $0, page: .general) }
            ),
            missedCallNudgeEnabled: persistedSettingsBinding(
                $missedCallNudgeEnabled,
                persist: { MissedCallNudgePreferences.setEnabled($0) },
                track: { trackSettingsToggle("missed_call_nudge", enabled: $0, page: .general) }
            ),
            effectiveTranscriptionModelTitle: effectiveTranscriptionModel.title,
            dictationShortcutsEnabled: dictationShortcutsEnabled,
            privacyStatusLine: generalPrivacyStatusLine,
            customDictionaryStatusLine: customDictionaryStatusLine,
            showModelSettings: $showGeneralModelSettings,
            showShortcutSettings: $showGeneralShortcutSettings,
            showPrivacySettings: $showGeneralPrivacySettings,
            showCorrections: $showGeneralCorrections,
            nemotronModelEnabled: persistedSettingsBinding(
                $betaNemotronModelEnabled,
                persist: { SpeechModelBetaPreferences.setNemotronBetaEnabled($0) },
                track: { trackSettingsToggle("nemotron_streaming_model", enabled: $0, page: .general) }
            ),
            nemotronRemainsPreferred: preferredTranscriptionModel == .nemotronStreaming,
            fallbackTranscriptionModelTitle: TranscriptionModelPreferences.defaultModel.title,
            onTrackAction: { actionID in
                trackSettingsAction(actionID, page: .general)
            },
            onImportAudioFile: {
                trackSettingsAction("import_recording", page: .general)
                actions.importAudioFile()
            },
            modelSettingsEditor: { generalModelSettingsEditor },
            shortcutSettingsEditor: { generalShortcutSettingsEditor },
            privacySettingsEditor: { generalPrivacySettingsEditor },
            correctionsEditor: { generalCorrectionsEditor }
        )
    }

    private var generalPrivacyStatusLine: String {
        if !missingRequiredPermissions.isEmpty {
            return "\(missingRequiredPermissions.count) to review"
        }
        if !CrashReporter.isAvailable && !AnalyticsReporter.isAvailable {
            return "Local only"
        }
        return "Ready"
    }

    private var generalModelSettingsEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsStatusCard(
                title: "Active transcription engine",
                status: effectiveTranscriptionModel.title,
                detail: activeModelDetail,
                tone: .ready
            )

            let modelCard = FirstRunExperience.modelCard(
                for: sttRouter.modelDownloadState,
                model: effectiveTranscriptionModel
            )
            SettingsStatusCard(
                title: "Model files",
                status: modelCard.status,
                detail: modelCard.detail,
                tone: tone(for: modelCard.tone),
                progress: modelCard.progress,
                actionTitle: modelDownloadActionTitle,
                action: modelDownloadAction(page: .general)
            )

            DisclosureGroup("Change model", isExpanded: $showAdvancedModelControls) {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Preferred model", selection: Binding(
                        get: { preferredTranscriptionModel },
                        set: { newValue in
                            updatePreferredTranscriptionModel(newValue, page: .general)
                        }
                    )) {
                        ForEach(visibleTranscriptionModelChoices) { model in
                            Text(model.title).tag(model)
                        }
                    }
                    .pickerStyle(.menu)

                    ForEach(visibleTranscriptionModelChoices) { model in
                        ModelChoiceRow(
                            model: model,
                            isPreferred: preferredTranscriptionModel == model,
                            isEffective: effectiveTranscriptionModel == model
                        )
                    }

                    HStack {
                        SettingsInlineActionButton(title: "Use Parakeet", tone: .accent) {
                            updatePreferredTranscriptionModel(.parakeetTDTv3, page: .general)
                        }
                        .disabled(preferredTranscriptionModel == .parakeetTDTv3)
                        .help(preferredTranscriptionModel == .parakeetTDTv3
                            ? "Parakeet is already the selected transcription model."
                            : "")

                        Text("Changes apply to the next capture.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 8)
            }

            // Speaker matching engine. Outcome-framed (no model jargon); off by
            // default; gated on the model actually being available; switching on
            // is non-destructive and reversible, with a one-time confirmation.
            VStack(alignment: .leading, spacing: 8) {
                let modelAvailable = SpeakerEmbedderFactory.resolveModelURL() != nil
                let namedCount = speakerPeopleModel.profiles.filter { $0.displayName != nil }.count
                SettingsToggleRow(
                    title: "Better speaker matching on calls",
                    detail: "Tells people apart more reliably on Zoom, Meet, and phone audio. Your saved people stay safe — switch back anytime.",
                    isOn: Binding(
                        get: { preferredSpeakerEmbedder == .eRes2Net },
                        set: { wantOn in
                            if wantOn {
                                if namedCount > 0 {
                                    showSpeakerEmbedderSwitchConfirm = true
                                } else {
                                    applySpeakerEmbedder(.eRes2Net)
                                }
                            } else {
                                applySpeakerEmbedder(.weSpeaker)
                            }
                        }
                    )
                )
                .disabled(!modelAvailable)

                if !modelAvailable {
                    Text("Not available in this build.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if preferredSpeakerEmbedder == .eRes2Net {
                    Text("Restart Transcripted to start using it. Call matching keeps a separate memory; your original saved people return if you switch this off.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .alert("Switch to call-optimized matching?", isPresented: $showSpeakerEmbedderSwitchConfirm) {
                Button("Switch") { applySpeakerEmbedder(.eRes2Net) }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Your \(speakerPeopleModel.profiles.filter { $0.displayName != nil }.count) saved people stay safe. Call matching uses a separate memory, so for the first few meetings it may ask who's who again, then re-learns them. Nothing is deleted, and switching back instantly restores your current people.")
            }
        }
    }

    private func applySpeakerEmbedder(_ choice: SpeakerEmbedderChoice) {
        preferredSpeakerEmbedder = choice
        SpeakerEmbedderPreferences.setPreferredChoice(choice)
    }

    private var generalShortcutSettingsEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsToggleRow(
                title: "Enable dictation shortcuts",
                detail: dictationShortcutsEnabled
                    ? "Push-to-talk and hands-free keys can start dictation."
                    : "Off. You can still start dictation from the app, and meeting controls still work.",
                isOn: persistedSettingsBinding(
                    $dictationShortcutsEnabled,
                    persist: { HotkeyPreferences.setDictationShortcutsEnabled($0) },
                    track: { trackSettingsToggle("dictation_shortcuts", enabled: $0, page: .general) }
                )
            )

            HotkeyRecorderContainer(dictationShortcutsEnabled: dictationShortcutsEnabled)
                .frame(height: HotkeyRecorderContainer.preferredHeight)

            if dictationShortcutsEnabled, let dictationTriggerSystemWarning {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)

                    Text(dictationTriggerSystemWarning)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption)
            }

            Divider()

            SettingsToggleRow(
                title: "Faster Bluetooth dictation",
                detail: keepRecommendedMicrophoneActive
                    ? "Keeps the preferred microphone selected Mac-wide while Transcripted is open; it does not record while idle."
                    : "Allow macOS to switch microphone routes for each dictation.",
                isOn: persistedSettingsBinding(
                    $keepRecommendedMicrophoneActive,
                    persist: { DictationPersistentInputPreferences.setEnabled($0) },
                    track: { trackSettingsToggle("keep_recommended_microphone_active", enabled: $0, page: .general) }
                )
            )

            Picker("Preferred microphone", selection: persistedSettingsBinding(
                $preferredDictationInputUID,
                persist: { DictationPersistentInputPreferences.setPreferredDeviceUID($0) },
                track: { _ in trackSettingsAction("change_preferred_dictation_microphone", page: .general) }
            )) {
                Text("Automatic (recommended)").tag(String?.none)
                ForEach(preferredDictationInputCandidates, id: \.id) { device in
                    Text(device.name).tag(device.uid)
                }
            }
            .disabled(!keepRecommendedMicrophoneActive)

            SettingsInlineActionButton(title: "Refresh microphones", symbolName: "arrow.clockwise") {
                trackSettingsAction("refresh_dictation_microphones", page: .general)
                refreshDictationInputCandidates()
            }

            Divider()

            SettingsToggleRow(
                title: "Send after dictation",
                detail: autoEnterEnabled
                    ? "Transcripted sends \(autoEnterKey.title) after it pastes, only in selected apps."
                    : "Off. Dictation only pastes text.",
                isOn: persistedSettingsBinding(
                    $autoEnterEnabled,
                    persist: { DictationAutoSendPreferences.setEnabled($0) },
                    track: { trackSettingsToggle("auto_send", enabled: $0, page: .general) }
                )
            )

            Picker("Send key", selection: persistedSettingsBinding(
                $autoEnterKey,
                persist: { DictationAutoSendPreferences.setSendKey($0) },
                track: { _ in trackSettingsAction("change_auto_send_key", page: .general) }
            )) {
                ForEach(DictationAutoSendKey.allCases) { key in
                    Text(key.title).tag(key)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!autoEnterEnabled)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Allowed apps")
                        .font(.subheadline.weight(.semibold))

                    Spacer()

                    SettingsInlineActionButton(title: "Refresh") {
                        trackSettingsAction("refresh_auto_send_apps", page: .general)
                        refreshAutoEnterAppCandidates()
                    }

                    SettingsInlineActionButton(title: "Add App...", symbolName: "plus") {
                        trackSettingsAction("add_auto_send_app", page: .general)
                        chooseAutoEnterApp(page: .general)
                    }
                }

                if autoEnterAllowedBundleIDs.isEmpty {
                    Text("Add an app before Transcripted can send.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sortedAutoEnterAllowedBundleIDs, id: \.self) { bundleID in
                        AutoEnterAllowedAppRow(
                            title: autoEnterDisplayName(for: bundleID),
                            bundleID: bundleID
                        ) {
                            setAutoEnterApp(bundleID, isAllowed: false, page: .general)
                        }
                    }
                }
            }
            .disabled(!autoEnterEnabled)

            if !autoEnterAppCandidates.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Running apps")
                        .font(.subheadline.weight(.semibold))

                    ForEach(autoEnterAppCandidates) { app in
                        SettingsToggleRow(
                            title: app.name,
                            detail: app.bundleID,
                            isOn: Binding(
                                get: { autoEnterAllowedBundleIDs.contains(app.bundleID) },
                                set: { isAllowed in
                                    setAutoEnterApp(app.bundleID, isAllowed: isAllowed, page: .general)
                                }
                            ),
                            help: "Allow Transcripted to send \(autoEnterKey.title) after pasting into \(app.name)."
                        )
                    }
                }
                .disabled(!autoEnterEnabled)
            }
        }
    }

    private var generalPrivacySettingsEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Permissions")
                    .font(.subheadline.weight(.semibold))

                ForEach(TranscriptedPermissionKind.allCases) { kind in
                    PermissionStatusRow(kind: kind, granted: permissionStates[kind] ?? false) {
                        trackPermissionCTA(kind)
                        Task { @MainActor in
                            await TranscriptedPermissionAccess.requestAccessOrOpenSettings(for: kind)
                            refreshPermissions()
                        }
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Meeting audio")
                    .font(.subheadline.weight(.semibold))

                VStack(alignment: .leading, spacing: 6) {
                    Picker("Meeting mic processing", selection: persistedSettingsBinding(
                        $meetingMicProcessingMode,
                        persist: { MicrophoneProcessingPreferences.setMode($0) },
                        track: { trackSettingsToggle("meeting_mic_processing_\($0.rawValue)", enabled: true, page: .general) }
                    )) {
                        ForEach(MicrophoneProcessingMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("transcripted.settings.meeting-mic-processing")

                    Text(meetingMicProcessingMode.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SettingsToggleRow(
                    title: "Identify multiple people on this Mac",
                    detail: splitLocalSpeakersEnabled
                        ? "On. After shared-room meetings, Transcripted asks you to name people captured by your mic."
                        : "Off. The local mic stays as You, which is simpler when only you are near this Mac.",
                    isOn: persistedSettingsBinding(
                        $splitLocalSpeakersEnabled,
                        persist: { LocalSpeakerPreferences.setEnabled($0) },
                        track: { trackSettingsToggle("local_speaker_split", enabled: $0, page: .general) }
                    )
                )

                Text("Changes here apply from the next recording.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Reporting")
                    .font(.subheadline.weight(.semibold))

                SettingsToggleRow(
                    title: "Send crash and error reports",
                    detail: crashReportingFootnote,
                    isOn: persistedSettingsBinding(
                        $crashReportingEnabled,
                        persist: { CrashReportingPreferences.setEnabled($0) },
                        track: { trackSettingsToggle("crash_reporting", enabled: $0, page: .general) },
                        sideEffect: { _ in
                            CrashReporter.applySessionTrackingPreference()
                            sentryTestStatus = nil
                            diagnosticsActionStatus = nil
                        }
                    )
                )
                .disabled(!CrashReporter.isAvailable)

                SettingsToggleRow(
                    title: "Send anonymous usage stats",
                    detail: analyticsFootnote,
                    // Hand-written, not persistedSettingsBinding: AnalyticsReporter.trackEvent
                    // drops any event fired while AnalyticsPreferences reads disabled, so the
                    // "anonymous_analytics" transition event itself needs asymmetric ordering —
                    // opt-in must persist before tracking so the transition event isn't dropped;
                    // opt-out must track first (while still enabled) for the same reason.
                    isOn: Binding(
                        get: { anonymousAnalyticsEnabled },
                        set: { newValue in
                            anonymousAnalyticsEnabled = newValue
                            if newValue {
                                AnalyticsPreferences.setEnabled(true)
                                trackSettingsToggle("anonymous_analytics", enabled: true, page: .general)
                            } else {
                                trackSettingsToggle("anonymous_analytics", enabled: false, page: .general)
                                AnalyticsPreferences.setEnabled(false)
                            }
                            diagnosticsActionStatus = nil
                        }
                    )
                )
                .disabled(!AnalyticsReporter.isAvailable)

                HStack {
                SettingsInlineActionButton(
                    title: "Send Test Sentry Event",
                    tone: .warning,
                    automationIdentifier: "transcripted.settings.general.send-test-sentry-event"
                ) {
                    trackSettingsAction("send_test_sentry_event", page: .general)
                    sendTestSentryEvent()
                }
                    .disabled(!CrashReporter.isAvailable || !crashReportingEnabled)

                    if let sentryTestStatus {
                        Text(sentryTestStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Text("Never sent: transcript text, audio, names, emails, file paths, raw URLs, or meeting titles.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var generalCorrectionsEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add the mistake on the left and the fix on the right.")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text("Mistake")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text("Fix")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Color.clear
                        .frame(width: 28, height: 1)
                }

                ForEach(customDictionaryRows) { row in
                    CorrectionEditorRow(
                        spoken: Binding(
                            get: { row.spoken },
                            set: { updateCorrectionSpoken($0, for: row.id) }
                        ),
                        replacement: Binding(
                            get: { row.replacement },
                            set: { updateCorrectionReplacement($0, for: row.id) }
                        ),
                        onRemove: {
                            trackSettingsAction("remove_correction", page: .general)
                            removeCorrectionRow(row.id)
                        }
                    )
                }
            }

            HStack {
                Button {
                    trackSettingsAction("add_correction", page: .general)
                    addCorrectionRow()
                } label: {
                    Label("Add correction", systemImage: "plus")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
                .buttonStyle(SettingsHoverButtonStyle(
                    tone: .accent,
                    cornerRadius: 8,
                    normalFill: Color.accentColor.opacity(0.08),
                    normalStroke: Color.accentColor.opacity(0.16)
                ))
                .frame(minHeight: 40)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                Spacer()

                SettingsInlineActionButton(
                    title: "Clear all",
                    tone: .destructive,
                    automationIdentifier: "transcripted.settings.general.corrections.clear-all"
                ) {
                    trackSettingsAction("clear_corrections", page: .general)
                    clearCorrectionRows()
                }
                .disabled(!hasCustomDictionaryContent)
                .help(hasCustomDictionaryContent ? "" : "No saved corrections to clear yet.")
            }

            DisclosureGroup("Try a phrase", isExpanded: $showCorrectionPreview) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Type a sample phrase", text: $customDictionaryPreviewInput)
                        .textFieldStyle(.roundedBorder)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Result")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        Text(customDictionaryPreviewOutput)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.55))
                            )
                    }
                }
                .padding(.top, 8)
            }

            DisclosureGroup("Edit as text", isExpanded: $showAdvancedCorrectionsText) {
                VStack(alignment: .leading, spacing: 8) {
                    TextEditor(text: Binding(
                        get: { customDictionaryText },
                        set: { updateCustomDictionaryText($0) }
                    ))
                    .font(.body.monospaced())
                    .frame(minHeight: 100)
                    .padding(8)
                    .scrollContentBackground(.hidden)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor).opacity(0.72))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )

                    Text("Use one per line: wrong -> right.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 4)
        }
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
            meetingCapturesURL: MeetingStoragePaths.transcriptsFolder,
            dictationCapturesURL: DictationStoragePaths.transcriptsFolder,
            unavailableCaptureLibraryPath: unavailableCaptureLibraryPath,
            captureLibraryMigrationInProgress: captureLibraryMigrationInProgress,
            captureLibraryMigrationStatus: captureLibraryMigrationStatus,
            captureLibraryMigrationStatusDetails: captureLibraryMigrationStatusDetails,
            captureLibraryChoicePromptBinding: captureLibraryChoicePromptBinding,
            pendingCaptureLibraryChoice: pendingCaptureLibraryChoice,
            audioRetentionWindow: audioRetentionWindow,
            modelCacheSnapshot: modelCacheSnapshot,
            modelCacheLoading: modelCacheLoading,
            modelCacheCleanupInProgress: modelCacheCleanupInProgress,
            modelCacheCleanupStatus: modelCacheCleanupStatus,
            modelCacheCleanupStatusDetails: modelCacheCleanupStatusDetails,
            effectiveTranscriptionModelIsWhisper: effectiveTranscriptionModel.isWhisper,
            appStateFolder: appStateFolder,
            cacheFolder: cacheFolder,
            logsFolder: logsFolder,
            recordingsFolder: recordingsFolder,
            onChooseCaptureLibrary: {
                trackSettingsAction("choose_capture_library", page: .storage)
                chooseCaptureLibrary()
            },
            onResetCaptureLibrary: {
                trackSettingsAction("reset_capture_library", page: .storage)
                resetCaptureLibraryToDefault()
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
            onRemoveStaleModelCaches: {
                removeStaleModelCaches()
            },
            onRemoveWhisperModelCache: {
                removeWhisperModelCache()
            },
            onLoadModelCacheSnapshot: {
                refreshModelCacheSnapshot()
            },
            onRefreshModelCacheSnapshot: {
                trackSettingsAction("refresh_model_cache_storage", page: .storage)
                refreshModelCacheSnapshot()
            },
            onApplyAudioRetentionWindow: { window in
                applyAudioRetentionWindow(window)
            },
            failureDetailsButton: { details in
                settingsFailureDetailsButton(details)
            }
        )
    }

    private var connectAgentPage: some View {
        AgentConnectionSettingsPage()
    }

    private var aboutPage: some View {
        AboutSettingsPage(
            sparkleUpdater: sparkleUpdater,
            onTrackSettingsToggle: { settingID, enabled, page in
                trackSettingsToggle(settingID, enabled: enabled, page: page)
            },
            updateActionEnabled: { status in updateActionEnabled(for: status) },
            onPerformUpdateAction: {
                trackSettingsAction(settingsUpdateActionID, page: .about)
                sparkleUpdater.performUserUpdateAction(surface: "settings_about")
            },
            diagnosticsActionStatus: diagnosticsActionStatus,
            crashReportingEnabled: crashReportingEnabled,
            onSubmitFeedback: {
                trackSettingsAction("submit_feedback", page: .about)
                actions.sendFeedback()
            },
            onSendDiagnosticEvent: {
                trackSettingsAction("send_diagnostic_event", page: .about)
                sendDiagnosticEvent()
            }
        )
    }

    private var settingsFooterShowsUpdateBadge: Bool {
        sparkleUpdater.updateStatus.readyToInstallVersion != nil
    }

    private var settingsFooterActionEnabled: Bool {
        updateActionEnabled(for: sparkleUpdater.updateStatus)
    }

    private var appStateFolder: URL {
        FileManager.default.transcriptedStateDir
    }

    private var cacheFolder: URL {
        FileManager.default.transcriptedCacheDir
    }

    private var logsFolder: URL {
        FileManager.default.transcriptedLogsDir
    }

    private var recordingsFolder: URL {
        FileManager.default.transcriptedRecordingsDir
    }

    private var effectiveTranscriptionModel: TranscriptionModelChoice {
        TranscriptionModelPreferences.effectiveModel()
    }

    // Nemotron is beta-gated: it only shows up in the model picker while the
    // Beta-page toggle is on (or while it is still the saved preference, so
    // the picker never points at a hidden selection).
    private var visibleTranscriptionModelChoices: [TranscriptionModelChoice] {
        TranscriptionModelChoice.allCases.filter { model in
            guard model == .nemotronStreaming else { return true }
            return betaNemotronModelEnabled || preferredTranscriptionModel == .nemotronStreaming
        }
    }

    private var activeModelDetail: String {
        "\(effectiveTranscriptionModel.summary) Audio and transcripts stay local. Model files are stored outside app updates."
    }

    private var modelDownloadActionTitle: String? {
        switch sttRouter.modelDownloadState {
        case .notLoaded:
            return "Download Now"
        case .cached:
            return "Load Now"
        case .failed:
            return "Retry Download"
        case .downloading, .loading, .ready:
            return nil
        }
    }

    private func modelDownloadAction(page: TranscriptedSettingsPage) -> (() -> Void)? {
        guard modelDownloadActionTitle != nil else { return nil }
        return {
            trackSettingsAction("download_model", page: page)
            Task { @MainActor in
                await sttRouter.initializeSelectedModelInBackground()
            }
        }
    }

    private var missingRequiredPermissions: [TranscriptedPermissionKind] {
        TranscriptedPermissionKind.requiredForCurrentUse(
            dictationShortcutsEnabled: dictationShortcutsEnabled
        ).filter { kind in
            !(permissionStates[kind] ?? false)
        }
    }

    private var permissionsStatusLine: String {
        if missingRequiredPermissions.isEmpty {
            return "Ready"
        }
        return "\(missingRequiredPermissions.count) required item\(missingRequiredPermissions.count == 1 ? "" : "s") missing"
    }

    private var permissionsDetailLine: String {
        if missingRequiredPermissions.isEmpty {
            return dictationShortcutsEnabled
                ? "Dictation permissions are on. Meeting audio can be enabled when you need it."
                : "Meeting recording permissions are on. Dictation shortcuts can stay off."
        }
        let permissions = missingRequiredPermissions.map(\.title).joined(separator: " and ")
        return dictationShortcutsEnabled
            ? "Turn on \(permissions) to record and paste back."
            : "Turn on \(permissions) to record meetings."
    }

    private var isUsingDefaultCaptureLibrary: Bool {
        captureLibraryURL.standardizedFileURL == FileManager.default.transcriptedDefaultCaptureLibraryDir.standardizedFileURL
    }

    private var crashReportingFootnote: String {
        if CrashReporter.isAvailable {
            return crashReportingEnabled
                ? "On. Sends scrubbed crash and error data to Sentry."
                : "Off. Crash and error details stay on this Mac."
        }
        return "Sentry is not configured in this build. Reports stay local."
    }

    private var analyticsFootnote: String {
        if AnalyticsReporter.isAvailable {
            return anonymousAnalyticsEnabled
                ? "On. Sends only allowlisted anonymous product events."
                : "Off. No anonymous usage stats leave this Mac."
        }
        return "PostHog is not configured in this build. Usage stats stay off."
    }

    private func tone(for tone: FirstRunModelCardState.Tone) -> SettingsStatusCard.Tone {
        switch tone {
        case .ready:
            return .ready
        case .working:
            return .working
        case .failed:
            return .caution
        }
    }

    /// Whether the live transcription activity card represents in-flight work
    /// that the user can explicitly cancel (an imported-audio copy or a running
    /// transcription), as opposed to a finished/failed state.
    private var homeTranscriptionActivityIsCancellable: Bool {
        switch meetingSession.displayStatus {
        case .gettingReady, .transcribing, .finishing:
            return true
        case .idle, .transcriptSaved, .failed:
            return false
        }
    }

    private var homeTranscriptionActivity: HomeTranscriptionActivityPresentation? {
        return HomeTranscriptionActivityPresentation.make(
            sessionState: meetingSession.state,
            displayStatus: meetingSession.displayStatus,
            warmupStatus: meetingSession.warmupStatus,
            lastSavedTitle: meetingSession.lastSavedTitle,
            lastSavedTranscriptURL: meetingSession.lastSavedTranscriptURL
        )
    }

    private func refreshState() {
        refreshPermissions()
        refreshStoragePaths()
        refreshRecentCaptures(force: true)
        refreshShortcutState()
        refreshDockVisibility()
        refreshLaunchAtLoginState()
        if !speakerPeopleModel.hasLoadedProfiles {
            speakerPeopleModel.refresh()
        }
        customDictionaryText = CustomDictionaryPreferences.rawText()
        customDictionaryRows = CorrectionDraftRow.rows(from: customDictionaryText)
        preferredTranscriptionModel = TranscriptionModelPreferences.preferredModel()
        showAdvancedModelControls = preferredTranscriptionModel != TranscriptionModelPreferences.defaultModel
        uiSoundsEnabled = UISoundPreferences.isEnabled()
        meetingMicProcessingMode = MicrophoneProcessingPreferences.mode()
        splitLocalSpeakersEnabled = LocalSpeakerPreferences.isEnabled()
        missedCallNudgeEnabled = MissedCallNudgePreferences.isEnabled()
        dictationShortcutsEnabled = HotkeyPreferences.dictationShortcutsEnabled()
        refreshAutoEnterPreferences(includeCandidates: pageShowsAutoEnterSettings(navigation.selectedPage))
        crashReportingEnabled = CrashReportingPreferences.isEnabled()
        anonymousAnalyticsEnabled = AnalyticsPreferences.isEnabled()
        if case .unknown = sparkleUpdater.updateStatus.state {
            sparkleUpdater.refreshUpdateStatus()
        }
    }

    private func expandGeneralDisclosureForPresentedPage() {
        switch navigation.presentedPage {
        case .models:
            showGeneralModelSettings = true
        case .shortcuts:
            showGeneralShortcutSettings = true
        case .privacy:
            showGeneralPrivacySettings = true
        default:
            break
        }
    }

    private func trackSettingsPageViewed(
        _ page: TranscriptedSettingsPage,
        source: String,
        discoveredPage: TranscriptedSettingsPage? = nil,
        trackFeatureDiscovery: Bool = true
    ) {
        AnalyticsReporter.track(
            "settings_page_viewed",
            properties: [
                "page_id": page.analyticsValue,
                "source": source,
            ]
        )
        guard trackFeatureDiscovery else { return }
        trackSettingsFeatureDiscovery(for: discoveredPage ?? page, source: source)
    }

    private func trackSettingsAction(_ actionID: String, page: TranscriptedSettingsPage? = nil) {
        AnalyticsReporter.track(
            "settings_action_clicked",
            properties: [
                "action_id": actionID,
                "page_id": (page ?? navigation.selectedPage).analyticsValue,
            ]
        )
    }

    private func trackSettingsToggle(_ settingID: String, enabled: Bool, page: TranscriptedSettingsPage? = nil) {
        AnalyticsReporter.track(
            "settings_toggle_changed",
            properties: [
                "enabled": enabled ? "true" : "false",
                "page_id": (page ?? navigation.selectedPage).analyticsValue,
                "setting_id": settingID,
            ]
        )
    }

    private func trackPermissionCTA(_ kind: TranscriptedPermissionKind) {
        AnalyticsReporter.track(
            "settings_permission_cta_clicked",
            properties: [
                "page_id": navigation.selectedPage.analyticsValue,
                "permission_kind": kind.analyticsValue,
                "prior_status": permissionStates[kind] == true ? "ready" : "pending",
            ]
        )
    }

    private func trackSettingsFeatureDiscovery(for page: TranscriptedSettingsPage, source: String) {
        guard let featureArea = settingsDiscoveryFeatureArea(for: page) else { return }

        FeatureDiscoveryTelemetry.trackIfNeeded(
            featureArea: featureArea,
            pageID: page.analyticsValue,
            source: source
        )
    }

    private func settingsDiscoveryFeatureArea(for page: TranscriptedSettingsPage) -> FeatureDiscoveryTelemetry.FeatureArea? {
        switch page {
        case .home, .dictations:
            return .localArtifactActions
        case .people:
            return .speakerReview
        case .storage:
            return .captureLibrary
        case .connectAgent:
            return .agentSetup
        case .beta:
            return nil
        case .privacy:
            return .permissions
        case .support:
            return .support
        case .about:
            return .updateSettings
        case .general, .models, .shortcuts:
            return nil
        }
    }

    private func refreshPermissions() {
        permissionStates = PermissionSnapshot.current()
        revalidateSystemAudioPermissionForStatusSurfaces()
    }

    private func revalidateSystemAudioPermissionForStatusSurfaces() {
        SystemAudioPermissionRevalidator.revalidateForStatusSurfaces(
            task: $permissionRevalidationTask
        ) {
            permissionStates = PermissionSnapshot.current()
        }
    }

    private func refreshStoragePaths() {
        captureLibraryURL = FileManager.default.transcriptedCaptureLibraryDir
        unavailableCaptureLibraryPath = TranscriptedStoragePreferences.unavailableCustomCaptureLibraryPath()
    }

    private func refreshModelCacheSnapshot() {
        guard !modelCacheLoading else { return }
        modelCacheLoading = true

        Task.detached(priority: .utility) {
            let snapshot = ModelCacheInventory.snapshot()
            await MainActor.run {
                modelCacheSnapshot = snapshot
                modelCacheLoading = false
            }
        }
    }

    private func removeStaleModelCaches() {
        guard !modelCacheCleanupInProgress else { return }
        modelCacheCleanupInProgress = true
        modelCacheCleanupStatus = nil
        modelCacheCleanupStatusDetails = nil

        Task.detached(priority: .utility) {
            do {
                let result = try ModelCacheInventory.removeKnownStaleFluidAudioModels()
                let snapshot = ModelCacheInventory.snapshot()
                await MainActor.run {
                    modelCacheSnapshot = snapshot
                    modelCacheCleanupInProgress = false
                    if result.removedNames.isEmpty {
                        modelCacheCleanupStatus = "No stale model folders needed removal."
                    } else {
                        let size = ModelCacheInventory.formattedByteCount(result.removedBytes)
                        modelCacheCleanupStatus = "Removed \(size) from \(result.removedNames.joined(separator: ", "))."
                    }
                }
            } catch {
                await MainActor.run {
                    modelCacheCleanupInProgress = false
                    modelCacheCleanupStatus = SettingsActionFailureCopy.modelCacheRemoval
                    modelCacheCleanupStatusDetails = error.localizedDescription
                }
            }
        }
    }

    private func removeReclaimableModelCaches() {
        guard !modelCacheCleanupInProgress else { return }
        let includeWhisper = !effectiveTranscriptionModel.isWhisper
        modelCacheCleanupInProgress = true
        modelCacheCleanupStatus = nil
        modelCacheCleanupStatusDetails = nil

        Task.detached(priority: .utility) {
            do {
                let result = try ModelCacheInventory.removeReclaimableCaches(includeWhisper: includeWhisper)
                let snapshot = ModelCacheInventory.snapshot()
                await MainActor.run {
                    modelCacheSnapshot = snapshot
                    modelCacheCleanupInProgress = false
                    if result.removedNames.isEmpty {
                        modelCacheCleanupStatus = "No reclaimable model cache needed removal."
                    } else {
                        let size = ModelCacheInventory.formattedByteCount(result.removedBytes)
                        modelCacheCleanupStatus = "Removed \(size) from \(result.removedNames.joined(separator: ", "))."
                    }
                }
            } catch {
                await MainActor.run {
                    modelCacheCleanupInProgress = false
                    modelCacheCleanupStatus = SettingsActionFailureCopy.modelCacheRemoval
                    modelCacheCleanupStatusDetails = error.localizedDescription
                }
            }
        }
    }

    private func removeWhisperModelCache() {
        guard !modelCacheCleanupInProgress, !effectiveTranscriptionModel.isWhisper else { return }
        modelCacheCleanupInProgress = true
        modelCacheCleanupStatus = nil
        modelCacheCleanupStatusDetails = nil

        Task.detached(priority: .utility) {
            do {
                let result = try ModelCacheInventory.removeWhisperModels()
                let snapshot = ModelCacheInventory.snapshot()
                await MainActor.run {
                    modelCacheSnapshot = snapshot
                    modelCacheCleanupInProgress = false
                    if result.removedBytes > 0 {
                        let size = ModelCacheInventory.formattedByteCount(result.removedBytes)
                        modelCacheCleanupStatus = "Removed \(size) from the Whisper cache."
                    } else {
                        modelCacheCleanupStatus = "No Whisper model files needed removal."
                    }
                }
            } catch {
                await MainActor.run {
                    modelCacheCleanupInProgress = false
                    modelCacheCleanupStatus = SettingsActionFailureCopy.modelCacheRemoval
                    modelCacheCleanupStatusDetails = error.localizedDescription
                }
            }
        }
    }

    private func applyAudioRetentionWindow(_ window: AudioRetentionWindow) {
        audioRetentionWindow = window
        trackSettingsAction("audio_retention_changed", page: .storage)
        AudioStoragePreferences.setDeleteAudioAfter(window)
        Task.detached(priority: .utility) {
            let result = await MeetingAudioStorageManager.processExistingRetainedAudio(
                in: MeetingStoragePaths.transcriptsFolder,
                retentionWindow: window
            )
            // A retention change can create/recompress/prune retained audio across the
            // library; signal Home so cached audio URLs re-resolve from disk.
            if result.changedArtifacts {
                await MainActor.run {
                    CaptureLibraryChangeBroadcaster.shared.noteLibraryWideChange()
                }
            }
        }
    }

    private func refreshRecentCaptures(force: Bool = false) {
        switch SettingsRecentCaptureRefreshPolicy.mode(for: navigation.selectedPage) {
        case .homeDashboard:
            refreshHomeDashboard(force: force)
        case .none:
            break
        }
    }

    private func refreshHomeDashboard(force: Bool) {
        let now = Date()
        guard SettingsRecentCaptureRefreshPolicy.shouldStartDashboardRefresh(
            for: navigation.selectedPage,
            force: force,
            isInFlight: homeDashboardRefreshInFlight,
            lastStartedAt: lastHomeDashboardRefreshStartedAt,
            now: now
        ) else {
            return
        }

        homeDashboardRefreshTask?.cancel()
        let generation = homeDashboardRefreshGeneration.begin()
        lastHomeDashboardRefreshStartedAt = now
        homeDashboardRefreshInFlight = true
        homeViewModel.refresh()

        homeDashboardRefreshTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled, homeDashboardRefreshGeneration.finishIfCurrent(generation) else { return }
            homeDashboardRefreshInFlight = false
            homeDashboardRefreshTask = nil
        }
    }

    private func refreshShortcutState() {
        dictationShortcutsEnabled = HotkeyPreferences.dictationShortcutsEnabled()
        dictationTriggerSystemWarning = PhysicalDictationTriggerPreferences.functionKeyConflictWarning(
            for: PhysicalDictationTriggerPreferences.pushToTalkBinding()
        )
    }

    private func refreshDockVisibility() {
        showTranscriptedInDock = DockVisibilityPreferences.isVisible()
    }

    private func refreshLaunchAtLoginState() {
        launchAtLoginEnabled = LaunchAtLoginController.isEnabled
        launchAtLoginStatus = LaunchAtLoginController.statusDescription
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        let previousValue = launchAtLoginEnabled
        launchAtLoginEnabled = enabled
        trackSettingsToggle("launch_at_login", enabled: enabled, page: .general)

        do {
            try LaunchAtLoginController.setEnabled(enabled)
            refreshLaunchAtLoginState()
        } catch {
            launchAtLoginEnabled = previousValue
            // Tooltip copy only; the raw error is captured to telemetry below.
            launchAtLoginStatus = SettingsActionFailureCopy.launchAtLogin
            EventReporter.shared.capture(
                level: .warning,
                engine: "app",
                event: "launch_at_login_update_failed",
                message: error.localizedDescription
            )
        }
    }

    private var customDictionaryStatusLine: String {
        let count = CustomDictionaryPreferences.entries(from: customDictionaryText).count
        if count == 0 {
            return "No corrections yet."
        }
        return "\(count) correction\(count == 1 ? "" : "s") active."
    }

    private var hasCustomDictionaryContent: Bool {
        !customDictionaryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var customDictionaryPreviewOutput: String {
        let sample = customDictionaryPreviewInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sample.isEmpty else { return "Type a sample phrase above to check corrections." }

        let entries = CustomDictionaryPreferences.entries(from: customDictionaryText)
        let corrected = entries.isEmpty
            ? sample
            : CustomDictionaryTextProcessor.apply(to: sample, entries: entries)

        guard dictationCleanupEnabled else { return corrected }
        return DictationFillerCleanupPolicy.clean(corrected).text
    }

    private func updateCustomDictionaryText(_ text: String) {
        let clampedText = CustomDictionaryPreferences.clampedRawText(text)
        customDictionaryText = clampedText
        CustomDictionaryPreferences.setRawText(clampedText)
        customDictionaryRows = CorrectionDraftRow.rows(from: clampedText)
    }

    private func addCorrectionRow() {
        customDictionaryRows.append(CorrectionDraftRow())
    }

    private func clearCorrectionRows() {
        customDictionaryRows = CorrectionDraftRow.rows(from: "")
        updateCustomDictionaryText("")
    }

    private func removeCorrectionRow(_ id: UUID) {
        let nextRows = customDictionaryRows.filter { $0.id != id }
        persistCorrectionRows(nextRows)
    }

    private func updateCorrectionSpoken(_ spoken: String, for id: UUID) {
        let nextRows = customDictionaryRows.map { row in
            guard row.id == id else { return row }
            if row.replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return CorrectionDraftRow(id: row.id, spoken: spoken, replacement: spoken)
            }
            return CorrectionDraftRow(id: row.id, spoken: spoken, replacement: row.replacement)
        }
        persistCorrectionRows(nextRows)
    }

    private func updateCorrectionReplacement(_ replacement: String, for id: UUID) {
        let nextRows = customDictionaryRows.map { row in
            guard row.id == id else { return row }
            return CorrectionDraftRow(id: row.id, spoken: row.spoken, replacement: replacement)
        }
        persistCorrectionRows(nextRows)
    }

    private func persistCorrectionRows(_ rows: [CorrectionDraftRow]) {
        let normalizedRows = rows.isEmpty ? [CorrectionDraftRow()] : rows
        let rawText = CorrectionDraftRow.rawText(from: normalizedRows)
        let clampedText = CustomDictionaryPreferences.clampedRawText(rawText)
        customDictionaryRows = clampedText == rawText ? normalizedRows : CorrectionDraftRow.rows(from: clampedText)
        customDictionaryText = clampedText
        CustomDictionaryPreferences.setRawText(clampedText)
    }

    private func updatePreferredTranscriptionModel(
        _ model: TranscriptionModelChoice,
        page: TranscriptedSettingsPage = .general
    ) {
        preferredTranscriptionModel = model
        showAdvancedModelControls = true
        trackSettingsAction("switch_model", page: page)
        TranscriptionModelPreferences.setPreferredModel(model)
    }

    private func sendTestSentryEvent() {
        guard CrashReporter.isAvailable else {
            sentryTestStatus = "Sentry is not configured in this build yet."
            return
        }

        guard crashReportingEnabled else {
            sentryTestStatus = "Turn on crash and error reports first."
            return
        }

        guard let eventID = CrashReporter.shared.sendTestEvent() else {
            sentryTestStatus = "Sentry test event could not be queued."
            return
        }

        sentryTestStatus = "Queued test event \(eventID.prefix(8)). Check Sentry in a few seconds."
    }

    private func sendDiagnosticEvent() {
        guard CrashReporter.isAvailable else {
            diagnosticsActionStatus = "Sentry is not configured in this build yet."
            return
        }

        guard crashReportingEnabled else {
            diagnosticsActionStatus = "Turn on crash and error reports first."
            return
        }

        guard let eventID = actions.sendDiagnosticEvent() else {
            diagnosticsActionStatus = "Diagnostic event could not be queued."
            return
        }

        diagnosticsActionStatus = "Queued diagnostic event \(eventID.prefix(8))."
    }

    private var captureLibraryChoicePromptBinding: Binding<Bool> {
        Binding(
            get: { pendingCaptureLibraryChoice != nil },
            set: { isPresented in
                if !isPresented {
                    pendingCaptureLibraryChoice = nil
                }
            }
        )
    }

    private func chooseCaptureLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose where Transcripted saves meeting and dictation Markdown files."
        panel.directoryURL = captureLibraryURL

        guard panel.runModal() == .OK, let url = panel.url else { return }

        guard TranscriptedStoragePreferences.prepareCaptureLibraryURL(url) else {
            refreshStoragePaths()
            showCaptureLibrarySelectionError()
            return
        }

        let currentLibrary = FileManager.default.transcriptedCaptureLibraryDir
        let isSameFolder = url.standardizedFileURL.path == currentLibrary.standardizedFileURL.path
        if !isSameFolder, CaptureLibraryMigrationPlanner().libraryHasCaptures(at: currentLibrary) {
            pendingCaptureLibraryChoice = PendingCaptureLibraryChoice(
                currentLibrary: currentLibrary,
                newLibrary: url,
                preferenceURL: url,
                destinationKind: .custom
            )
            return
        }

        captureLibraryMigrationStatus = nil
        applyCaptureLibraryChoice(url)
    }

    private func resetCaptureLibraryToDefault() {
        let defaultLibrary = FileManager.default.transcriptedDefaultCaptureLibraryDir
        guard TranscriptedStoragePreferences.prepareCaptureLibraryURL(defaultLibrary) else {
            refreshStoragePaths()
            showCaptureLibrarySelectionError()
            return
        }

        let currentLibrary = FileManager.default.transcriptedCaptureLibraryDir
        let isSameFolder = defaultLibrary.standardizedFileURL.path == currentLibrary.standardizedFileURL.path
        if !isSameFolder, CaptureLibraryMigrationPlanner().libraryHasCaptures(at: currentLibrary) {
            pendingCaptureLibraryChoice = PendingCaptureLibraryChoice(
                currentLibrary: currentLibrary,
                newLibrary: defaultLibrary,
                preferenceURL: nil,
                destinationKind: .defaultLibrary
            )
            return
        }

        captureLibraryMigrationStatus = nil
        applyCaptureLibraryChoice(nil)
    }

    private func switchLibraryWithoutCopying(_ choice: PendingCaptureLibraryChoice) {
        captureLibraryMigrationStatus = "Existing captures stayed in \(choice.currentLibrary.path)."
        applyCaptureLibraryChoice(choice.preferenceURL)
    }

    private func copyCapturesThenSwitchLibrary(_ choice: PendingCaptureLibraryChoice) {
        guard !captureLibraryMigrationInProgress else { return }
        captureLibraryMigrationInProgress = true
        captureLibraryMigrationStatus = "Copying captures..."
        captureLibraryMigrationStatusDetails = nil

        Task.detached(priority: .utility) {
            let planner = CaptureLibraryMigrationPlanner()
            let plan = planner.makePlan(from: choice.currentLibrary, to: choice.newLibrary)
            do {
                let result = try planner.copy(plan) { copied, total in
                    Task { @MainActor in
                        captureLibraryMigrationStatus = "Copying captures... \(copied) of \(total)"
                    }
                }
                await MainActor.run {
                    captureLibraryMigrationInProgress = false
                    captureLibraryMigrationStatus = captureLibraryCopySummary(result)
                    applyCaptureLibraryChoice(choice.preferenceURL)
                }
            } catch {
                await MainActor.run {
                    captureLibraryMigrationInProgress = false
                    captureLibraryMigrationStatus = SettingsActionFailureCopy.captureLibraryMigration(
                        currentLibraryPath: choice.currentLibrary.path
                    )
                    captureLibraryMigrationStatusDetails = error.localizedDescription
                }
            }
        }
    }

    private func captureLibraryCopySummary(_ result: CaptureLibraryMigrationResult) -> String {
        var summary = "Copied \(result.copiedCount) item\(result.copiedCount == 1 ? "" : "s") to the new folder. Originals stay in the old folder."
        if result.skippedExistingCount > 0 {
            summary += " Skipped \(result.skippedExistingCount) that already existed at the destination."
        }
        return summary
    }

    private func applyCaptureLibraryChoice(_ url: URL?) {
        guard TranscriptedStoragePreferences.setCaptureLibraryURL(url) else {
            refreshStoragePaths()
            showCaptureLibrarySelectionError()
            return
        }
        refreshStoragePaths()
        CaptureLibraryChangeBroadcaster.shared.noteLibraryWideChange()
        AnalyticsReporter.track(
            "settings_capture_library_changed",
            properties: [
                "location_type": isUsingDefaultCaptureLibrary ? "default" : "custom",
                "page_id": TranscriptedSettingsPage.storage.analyticsValue,
            ]
        )
    }

    private func showCaptureLibrarySelectionError() {
        let alert = NSAlert()
        alert.messageText = "Transcripted can't use that folder."
        alert.informativeText = "Choose a folder where Transcripted can create meeting and dictation files, or reset to the default capture library."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private var sortedAutoEnterAllowedBundleIDs: [String] {
        autoEnterAllowedBundleIDs.sorted { lhs, rhs in
            autoEnterDisplayName(for: lhs).localizedCaseInsensitiveCompare(autoEnterDisplayName(for: rhs)) == .orderedAscending
        }
    }

    private var preferredDictationInputCandidates: [DictationAudioDevice] {
        availableDictationInputs
            .filter { $0.uid != nil }
            .filter { DictationInputDeviceSelectionPolicy.deviceClass(for: $0) != "bluetooth" }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func refreshDictationInputCandidates() {
        availableDictationInputs = (try? CoreAudioInputDeviceLookup.availableInputDevices()) ?? []
    }

    private func setAutoEnterApp(
        _ bundleID: String,
        isAllowed: Bool,
        page: TranscriptedSettingsPage = .general
    ) {
        if isAllowed {
            autoEnterAllowedBundleIDs.insert(bundleID)
        } else {
            autoEnterAllowedBundleIDs.remove(bundleID)
        }
        trackSettingsToggle("auto_send_app_allowed", enabled: isAllowed, page: page)
        DictationAutoSendPreferences.setAllowedBundleIDs(autoEnterAllowedBundleIDs)
    }

    private func pageShowsAutoEnterSettings(_ page: TranscriptedSettingsPage) -> Bool {
        page == .general
    }

    private func refreshAutoEnterAppCandidates() {
        autoEnterAppCandidates = AutoEnterAppCandidate.runningApps()
    }

    private func refreshAutoEnterPreferences(includeCandidates: Bool) {
        autoEnterEnabled = DictationAutoSendPreferences.isEnabled()
        autoEnterKey = DictationAutoSendPreferences.sendKey()
        autoEnterAllowedBundleIDs = DictationAutoSendPreferences.allowedBundleIDs()
        if includeCandidates {
            refreshAutoEnterAppCandidates()
        }
    }

    private func chooseAutoEnterApp(page: TranscriptedSettingsPage = .general) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.prompt = "Add"
        panel.message = "Choose an app where Transcripted may send after dictation."
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)

        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundle = Bundle(url: url),
              let bundleID = bundle.bundleIdentifier else {
            return
        }

        setAutoEnterApp(bundleID, isAllowed: true, page: page)
        refreshAutoEnterAppCandidates()
    }

    private func autoEnterDisplayName(for bundleID: String) -> String {
        AutoEnterDisplayNameResolver.resolve(
            bundleID: bundleID,
            candidateNames: autoEnterAppCandidates.map { ($0.bundleID, $0.name) },
            workspaceLookup: { id in
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
                    return nil
                }
                return url.deletingPathExtension().lastPathComponent
            }
        )
    }

    private var settingsUpdateActionID: String {
        switch sparkleUpdater.updateStatus.state {
        case .updateAvailable:
            return "install_update"
        case .readyToInstall:
            return "restart_to_update"
        case .checking, .downloading:
            return "view_update_progress"
        case .unknown, .readyToCheck, .noUpdateAvailable:
            return "check_updates"
        }
    }

    private var isCaptureActiveForUpdateSafety: Bool {
        sttRouter.isRecording
            || sttRouter.isTranscribing
            || meetingSession.isRecording
            || meetingSession.hasRuntimeDiagnosticsWork
            || meetingSession.isSpeakerReviewPending
    }

    private func updateActionEnabled(for status: SparkleUpdaterController.UpdateStatus) -> Bool {
        UpdateActionSafetyPolicy.canRunUserAction(
            state: updateActionSafetyState(for: status.state),
            sparkleCanRunUserAction: status.canRunUserUpdateAction,
            automaticDownloadsEnabled: sparkleUpdater.automaticUpdateSettings.automaticDownloadsEnabled,
            isCaptureActive: isCaptureActiveForUpdateSafety
        )
    }

    private func updateCaptureSafetyHelp(for status: SparkleUpdaterController.UpdateStatus) -> String? {
        UpdateActionSafetyPolicy.captureSafetyHelp(
            state: updateActionSafetyState(for: status.state),
            isCaptureActive: isCaptureActiveForUpdateSafety
        )
    }

    private func updateActionSafetyState(
        for state: SparkleUpdaterController.UpdateStatus.State
    ) -> UpdateActionSafetyState {
        switch state {
        case .unknown:
            return .unknown
        case .readyToCheck:
            return .readyToCheck
        case .checking:
            return .checking
        case .noUpdateAvailable:
            return .noUpdateAvailable
        case .updateAvailable:
            return .updateAvailable
        case .downloading:
            return .downloading
        case .readyToInstall:
            return .readyToInstall
        }
    }
}

// User-facing copy for the "we can't find this artifact on disk" failures that
// several Settings actions surface. Centralized so the identical strings are
// not re-typed at each call site and can't drift apart.
private enum SettingsArtifactMessage {
    static let meetingTranscriptNotFound =
        "Transcripted couldn't find this meeting's transcript on disk. It may have been moved, renamed, or deleted outside the app."
    static let dictationFileNotFound =
        "Transcripted couldn't find this dictation's file on disk. It may have been moved, renamed, or deleted outside the app."
    static let meetingRetainedAudioNotFound =
        "Transcripted couldn't find this meeting's retained audio on disk. It may have been moved, recompressed, or removed by the audio-retention setting."
}
