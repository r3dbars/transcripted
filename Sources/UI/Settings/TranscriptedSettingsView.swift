import AppKit
import Observation
import SwiftUI
import TranscriptedCore
import UniformTypeIdentifiers

struct TranscriptedSettingsView: View {
    @Bindable var navigation: TranscriptedSettingsNavigationModel
    @ObservedObject var speakerPeopleModel: SpeakerPeopleSettingsViewModel
    @ObservedObject private var sttRouter: STTRouter
    @ObservedObject private var meetingSession: MeetingSessionController
    @ObservedObject private var sparkleUpdater: SparkleUpdaterController
    @ObservedObject private var statsService: StatsService = .shared

    private let actions: TranscriptedSettingsActions
    private let appLogger: AppLogger
    private let sidebarSections = SettingsSidebarSection.defaultSections

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
    @State private var uiSoundsEnabled = UISoundPreferences.isEnabled()
    @State private var autoEnterEnabled = DictationAutoSendPreferences.isEnabled()
    @State private var autoEnterKey = DictationAutoSendPreferences.sendKey()
    @State private var autoEnterAllowedBundleIDs = DictationAutoSendPreferences.allowedBundleIDs()
    @State private var autoEnterAppCandidates: [AutoEnterAppCandidate] = []
    @State private var crashReportingEnabled = CrashReportingPreferences.isEnabled()
    @State private var anonymousAnalyticsEnabled = AnalyticsPreferences.isEnabled()
    @State private var sentryTestStatus: String?
    @State private var diagnosticsActionStatus: String?
    @State private var permissionStates = PermissionSnapshot.current()
    @State private var captureLibraryURL = FileManager.default.transcriptedCaptureLibraryDir
    @State private var homeDashboardRefreshTask: Task<Void, Never>?
    @State private var homeDashboardRefreshInFlight = false
    @State private var homeDashboardRefreshGeneration = 0
    @State private var lastHomeDashboardRefreshStartedAt: Date?
    @State private var showSupportFolders = false
    @State private var modelCacheSnapshot: ModelCacheSnapshot?
    @State private var modelCacheLoading = false
    @State private var modelCacheCleanupInProgress = false
    @State private var modelCacheCleanupStatus: String?
    @State private var showModelCacheCleanupConfirmation = false
    @State private var showWhisperCacheCleanupConfirmation = false
    @State private var showReclaimableCacheCleanupConfirmation = false
    @State private var meetingVoiceProcessingEnabled = MicrophoneProcessingPreferences.isVoiceProcessingEnabled()
    @State private var splitLocalSpeakersEnabled = LocalSpeakerPreferences.isEnabled()
    @State private var confirmQuitDuringMeetingEnabled = QuitConfirmationPreferences.confirmQuitDuringActiveMeetingRecording()
    @State private var audioRetentionWindow = AudioStoragePreferences.deleteAudioAfter()
    @State private var pendingAudioRetentionWindow: AudioRetentionWindow?
    @StateObject private var homeViewModel = HomeViewModel()
    @State private var homeActivityTab: HomeActivityTab = .meetings
    @State private var homeHeroMode: HomeHeroMode = .meeting
    @State private var homeCopiedRowID: String?
    @State private var homeDeleteConfirmation: HomeDeleteConfirmation?
    @State private var homeDeleteFailure: HomeDeleteFailure?
    @State private var homeFeedbackTarget: HomeFeedbackTarget?
    @State private var homeShowsAllFailedMeetings = false
    @State private var homeShowsStatsDetails = false
    @State private var homeMeetingPreview: HomeMeetingPreview?
    @State private var homeMeetingPreviewLoadTask: Task<Void, Never>?
    @State private var homeLocalSummaryJobIDs: Set<String> = []
    @State private var homeLocalSummaryTasks: [String: Task<LocalMeetingSummaryResult, Error>] = [:]
    @State private var homeLocalSummaryTaskTokens: [String: UUID] = [:]
    @State private var homeLocalSummaryNotice: HomeLocalSummaryNotice?
    @State private var homeLocalSummaryNoticeDismissTask: Task<Void, Never>?
    @AppStorage(LocalMeetingSummaryPreferences.enabledKey) private var localMeetingSummariesEnabled = LocalMeetingSummaryPreferences.defaultEnabled
    @AppStorage(LiveMeetingCodexPreferences.enabledKey) private var betaLiveMeetingCodexEnabled = LiveMeetingCodexPreferences.defaultEnabled
    @State private var betaFeatureStatus: String?
    @State private var localSummarySetupStatus = LocalMeetingSummarySetupStatus.current()
    @State private var showLocalSummarySetupDetails = false
    @State private var localSummaryModelPreparationStatus: String?
    @State private var localSummaryModelPreparationTask: Task<String, Error>?
    @State private var localSummaryModelPreparationToken: UUID?
    @State private var isLocalSummaryModelPreparing = false
    @State private var settingsColumnVisibility: NavigationSplitViewVisibility = .all
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
        NavigationSplitView(columnVisibility: $settingsColumnVisibility) {
            List(selection: $navigation.selectedPage) {
                ForEach(sidebarSections) { section in
                    if let title = section.title {
                        Section {
                            sidebarRows(for: section.pages)
                        } header: {
                            Text(title)
                        }
                    } else {
                        sidebarRows(for: section.pages)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    Divider()
                    settingsSidebarFooter
                        .background(.thinMaterial)
                }
            }
        } detail: {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(nsColor: .windowBackgroundColor),
                        Color(nsColor: .controlBackgroundColor).opacity(0.4)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 28) {
                            pageBody
                        }
                        .padding(.horizontal, 28)
                        .padding(.top, settingsContentTopPadding)
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
        .frame(minWidth: 880, minHeight: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $homeShowsStatsDetails) {
            HomeStatsDetailSheet(
                stats: homeStatItems,
                streak: homeStreak,
                onDone: {
                    homeShowsStatsDetails = false
                }
            )
        }
        .task(id: navigation.presentationID) {
            refreshState()
            expandGeneralDisclosureForPresentedPage()
            trackSettingsPageViewed(navigation.selectedPage, source: "presentation")
        }
        .onChange(of: navigation.selectedPage) { _, page in
            refreshRecentCaptures()
            if pageShowsAutoEnterSettings(page) {
                refreshAutoEnterPreferences(includeCandidates: true)
            }
            trackSettingsPageViewed(page, source: "navigation")
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
            localSummaryModelPreparationTask?.cancel()
            localSummaryModelPreparationTask = nil
            homeViewModel.cancel()
        }
    }

    @ViewBuilder
    private func sidebarRows(for pages: [TranscriptedSettingsPage]) -> some View {
        ForEach(pages) { page in
            SettingsSidebarRow(
                page: page,
                isSelected: navigation.selectedPage == page
            )
                .tag(page)
        }
    }

    private var settingsSidebarFooter: some View {
        Button {
            trackSettingsAction(settingsUpdateActionID, page: .about)
            sparkleUpdater.performUserUpdateAction(surface: "settings_footer")
        } label: {
            HStack(spacing: 8) {
                if settingsFooterShowsUpdateBadge {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 7, height: 7)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(settingsFooterTitle)
                        .font(.caption.weight(settingsFooterShowsUpdateBadge ? .semibold : .regular))
                        .foregroundStyle(settingsFooterShowsUpdateBadge ? Color.primary : Color.secondary)
                        .lineLimit(1)

                    if let detail = settingsFooterDetail {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 6)

                Image(systemName: settingsFooterShowsUpdateBadge ? "arrow.clockwise.circle.fill" : "arrow.triangle.2.circlepath")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(settingsFooterShowsUpdateBadge ? Color.accentColor : Color.secondary)
                    .opacity(settingsFooterActionEnabled ? 1 : 0.45)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, settingsFooterShowsUpdateBadge ? 8 : 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsHoverButtonStyle(
            tone: settingsFooterShowsUpdateBadge ? .accent : .neutral,
            cornerRadius: 10
        ))
        .disabled(!settingsFooterActionEnabled)
        .help(settingsFooterHelp)
        .accessibilityIdentifier("transcripted.settings.footer.check-updates")
    }

    @ViewBuilder
    private var pageBody: some View {
        switch navigation.selectedPage {
        case .home:
            homePage
        case .general:
            generalPage
        case .models:
            modelsPage
        case .shortcuts:
            shortcutsPage
        case .people:
            peoplePage
        case .storage:
            storagePage
        case .connectAgent:
            connectAgentPage
        case .beta:
            betaPage
        case .privacy:
            privacyPage
        case .support:
            supportPage
        case .about:
            aboutPage
        }
    }

    private var homePage: some View {
        let stats = homeStatItems
        let needsAttention = homeNeedsAttentionIssues
        let allFailedMeetings = meetingSession.failedMeetings
        let failedMeetings = homeShowsAllFailedMeetings
            ? allFailedMeetings
            : Array(allFailedMeetings.prefix(3))
        let hiddenFailedMeetingCount = max(0, allFailedMeetings.count - failedMeetings.count)
        let meetingSections = homeMeetingDaySections

        return VStack(alignment: .leading, spacing: 14) {
            if !failedMeetings.isEmpty {
                HomeFailedMeetingsCard(
                    items: failedMeetings,
                    hiddenCount: hiddenFailedMeetingCount,
                    canRetry: canRetryFailedMeetings,
                    retryUnavailableReason: failedMeetingRetryUnavailableReason,
                    audioAttachment: { failedMeetingAudioAttachment(for: $0) },
                    onRetry: { item in
                        trackSettingsAction("home_retry_failed_meeting", page: .home)
                        retryFailedMeeting(item)
                    },
                    onRevealAudio: { item in
                        trackSettingsAction("home_reveal_failed_meeting_audio", page: .home)
                        revealFailedMeetingAudio(item)
                    },
                    onClear: { item in
                        requestClearFailedMeeting(item)
                    },
                    onShowAll: {
                        trackSettingsAction("home_show_all_failed_meetings", page: .home)
                        homeShowsAllFailedMeetings = true
                    }
                )
            }

            HStack(alignment: .top, spacing: 20) {
                HomeWelcomeHeader(
                    name: homeViewModel.welcomeName,
                    summary: homeWelcomeSummary
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

                HomeStatsBadge(
                    stats: stats,
                    streak: homeStreak,
                    onViewStats: {
                        homeShowsStatsDetails = true
                    }
                )
                    .layoutPriority(0)
            }

            if !needsAttention.isEmpty {
                HomeNeedsAttentionCard(
                    issues: needsAttention,
                    onReview: { issue in
                        reviewHomeNeedsAttention(issue)
                    }
                )
            }

            if let activity = homeTranscriptionActivity {
                SettingsActivityCard(
                    symbolName: activity.symbolName,
                    title: activity.title,
                    status: activity.status,
                    detail: activity.detail,
                    tone: activity.tone,
                    progress: activity.progress,
                    actionTitle: activity.transcriptURL == nil ? nil : "Open Markdown",
                    action: activity.transcriptURL.map { transcriptURL in
                        {
                            trackSettingsAction("open_current_activity", page: .home)
                            ActivationTelemetry.trackArtifactAction(
                                artifactKind: .meeting,
                                actionKind: .openMarkdown,
                                surface: .homeCurrentActivity
                            )
                            NSWorkspace.shared.open(transcriptURL)
                        }
                    }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if let notice = homeLocalSummaryNotice {
                SettingsActivityCard(
                    symbolName: "sparkles",
                    title: notice.title,
                    status: notice.status,
                    detail: notice.detail,
                    tone: .success,
                    progress: nil,
                    actionTitle: "Open enhanced transcript",
                    action: {
                        trackSettingsAction("open_local_meeting_summary_notice", page: .home)
                        clearHomeLocalSummaryNotice(id: notice.id)
                        NSWorkspace.shared.open(notice.transcriptURL)
                    }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            HomeHeroCard(
                selectedMode: homeHeroModeSelection
            ) {
                HomeActivityTabsCard(
                    selectedTab: homeActivityTab,
                    speakerPeopleModel: speakerPeopleModel,
                    dictationSections: homeViewModel.dictationDaySections,
                    meetingSections: meetingSections,
                    isLoading: homeViewModel.isLoading,
                    isLoadingMore: homeViewModel.isLoadingMore,
                    canLoadMoreDictations: homeViewModel.canLoadMoreDictations,
                    canLoadMoreMeetings: homeViewModel.canLoadMoreMeetings,
                    copiedRowID: homeCopiedRowID,
                    summarizingMeetingIDs: homeLocalSummaryJobIDs,
                    localMeetingSummariesEnabled: localMeetingSummariesEnabled,
                    canRetryFailedMeetings: canRetryFailedMeetings,
                    failedMeetingRetryUnavailableReason: failedMeetingRetryUnavailableReason,
                    canRetranscribeSavedMeetings: canRetranscribeSavedMeetings,
                    savedMeetingRetranscriptionUnavailableReason: savedMeetingRetranscriptionUnavailableReason,
                    onOpenDictation: { entry in
                        trackSettingsAction("open_recent_dictation", page: .home)
                        ActivationTelemetry.trackArtifactAction(
                            artifactKind: .dictation,
                            actionKind: .openMarkdown,
                            surface: .homeRow,
                            artifactDate: entry.createdAt
                        )
                        NSWorkspace.shared.open(entry.url)
                    },
                    onCopyDictation: { entry in
                        handleCopyDictation(entry)
                    },
                    onFlagDictation: { entry in
                        trackSettingsAction("flag_dictation", page: .home)
                        homeFeedbackTarget = HomeFeedbackTarget.dictation(entry)
                    },
                    dictationMenuItems: { entry in
                        dictationRowMenuItems(for: entry)
                    },
                    onOpenMeeting: { item in
                        presentHomeMeetingPreview(item)
                    },
                    onCopyMeeting: { item in
                        handleCopyMeeting(item)
                    },
                    onFlagMeeting: { item in
                        trackSettingsAction("flag_meeting", page: .home)
                        homeFeedbackTarget = HomeFeedbackTarget.meeting(item)
                    },
                    onReviewMeetingSpeakers: { _ in
                        openHomeSpeakerReview(actionName: "review_meeting_speakers_row")
                    },
                    onRetranscribeMeeting: { item in
                        handleRetranscribeMeeting(item)
                    },
                    meetingMenuItems: { item in
                        meetingRowMenuItems(for: item)
                    },
                    onRetryFailedMeeting: { item in
                        trackSettingsAction("home_retry_failed_meeting", page: .home)
                        retryFailedMeeting(item)
                    },
                    onRevealFailedMeetingAudio: { item in
                        trackSettingsAction("home_reveal_failed_meeting_audio", page: .home)
                        revealFailedMeetingAudio(item)
                    },
                    onClearFailedMeeting: { item in
                        requestClearFailedMeeting(item)
                    },
                    onLoadMoreDictations: {
                        trackSettingsAction("load_more_dictations", page: .home)
                        homeViewModel.loadMoreDictations()
                    },
                    onLoadMoreMeetings: {
                        trackSettingsAction("load_more_meetings", page: .home)
                        homeViewModel.loadMoreMeetings()
                    }
                )
            }
            .padding(.top, 14)
        }
        .animation(.snappy(duration: 0.22), value: homeTranscriptionActivity)
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
        .sheet(item: $homeMeetingPreview) { preview in
            HomeMeetingPreviewSheet(
                preview: preview,
                onOpenMarkdown: {
                    trackSettingsAction("open_recent_meeting_markdown", page: .home)
                    ActivationTelemetry.trackArtifactAction(
                        artifactKind: .meeting,
                        actionKind: .openMarkdown,
                        surface: .homePreview,
                        artifactDate: preview.date
                    )
                    NSWorkspace.shared.open(preview.transcriptURL)
                },
                onCopyForAgent: {
                    handleCopyMeetingPreview(preview)
                },
                onReportIssue: {
                    homeMeetingPreview = nil
                    Task { @MainActor in
                        await Task.yield()
                        homeFeedbackTarget = preview.feedbackTarget
                    }
                },
                onDone: {
                    homeMeetingPreview = nil
                }
            )
        }
        .onChange(of: homeActivityTab) { _, newValue in
            trackSettingsAction("home_tab_\(newValue.rawValue)", page: .home)
            if newValue == .meetings {
                refreshRecentCaptures(force: true)
            } else if newValue == .speakers {
                speakerPeopleModel.refresh()
            }
        }
        .alert(item: $homeDeleteConfirmation) { confirmation in
            Alert(
                title: Text(confirmation.title),
                message: Text(confirmation.message),
                primaryButton: .destructive(Text(confirmation.confirmTitle)) {
                    confirmation.perform()
                },
                secondaryButton: .cancel()
            )
        }
        .alert(item: $homeDeleteFailure) { failure in
            Alert(
                title: Text(failure.title),
                message: Text(failure.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .alert(item: $pendingAudioRetentionWindow) { window in
            Alert(
                title: Text("Delete old replay audio?"),
                message: Text("Transcripted will keep your Markdown transcripts, but retained replay audio older than \(window.title) will be permanently removed now and cleaned up automatically later."),
                primaryButton: .destructive(Text("Delete Old Audio")) {
                    applyAudioRetentionWindow(window)
                },
                secondaryButton: .cancel()
            )
        }
    }

    private var settingsContentTopPadding: CGFloat {
        SettingsContentLayoutPolicy.topPadding(
            for: navigation.selectedPage,
            sidebarPresentation: settingsSidebarPresentation
        )
    }

    private var settingsSidebarPresentation: SettingsSidebarPresentation {
        settingsColumnVisibility == .detailOnly ? .hidden : .visible
    }

    private var homeHeroModeSelection: Binding<HomeHeroMode> {
        Binding(
            get: { homeHeroMode },
            set: { newMode in
                homeHeroMode = newMode
                homeActivityTab = newMode.activityTab
            }
        )
    }

    private func reviewHomeNeedsAttention(_ issue: HomeNeedsAttentionCard.Issue) {
        switch issue.destination {
        case .failedMeetings:
            trackSettingsAction("open_needs_attention_failed_meetings", page: .home)
            homeActivityTab = .meetings
            homeHeroMode = .meeting
        case .speakers:
            openHomeSpeakerReview(actionName: "open_needs_attention_speakers")
        case .activity:
            trackSettingsAction("open_needs_attention_activity", page: .home)
            homeActivityTab = .meetings
            homeHeroMode = .meeting
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
        trackSettingsAction(actionName, page: .home)
        speakerPeopleModel.refresh()
        speakerPeopleModel.searchText = ""
        navigation.selectedPage = .home
        homeActivityTab = .speakers
        homeHeroMode = .speakers
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
        ActivationTelemetry.trackAgentPromptAction(
            promptKind: .meetingBundle,
            actionKind: .copied,
            agentTarget: .localAgent,
            surface: .homeRow,
            artifactKind: .meeting
        )
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let bundle = AgentConnectionGuide.portableMeetingBundle(
            title: item.title,
            date: item.date,
            transcriptURL: item.transcriptURL
        ) {
            pasteboard.setString(bundle, forType: .string)
        } else if let raw = try? String(contentsOf: item.transcriptURL, encoding: .utf8) {
            pasteboard.setString(raw, forType: .string)
        } else {
            NSSound.beep()
            return
        }
        flashCopied(rowID: item.id)
    }

    private func handleCopyMeetingPreview(_ preview: HomeMeetingPreview) {
        trackSettingsAction("copy_meeting_preview", page: .home)
        let bundle = AgentConnectionGuide.portableMeetingBundle(
            title: preview.title,
            date: preview.date,
            transcriptURL: preview.transcriptURL
        )
        let fallbackMarkdown = preview.markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text = bundle ?? (fallbackMarkdown.isEmpty ? nil : preview.markdown) else {
            ActivationTelemetry.trackAgentPromptAction(
                promptKind: .meetingBundle,
                actionKind: .copied,
                agentTarget: .localAgent,
                surface: .homePreview,
                result: .failed,
                artifactKind: .meeting
            )
            NSSound.beep()
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        ActivationTelemetry.trackAgentPromptAction(
            promptKind: bundle == nil ? .meetingMarkdown : .meetingBundle,
            actionKind: .copied,
            agentTarget: .localAgent,
            surface: .homePreview,
            result: bundle == nil ? .fallbackCopied : .success,
            artifactKind: .meeting
        )
    }

    private func handleRetranscribeMeeting(_ item: RecentMeetingItem) {
        guard !hasSpeakerReviewWork(for: item) else {
            openHomeSpeakerReview(actionName: "open_speaker_review_before_retranscribe")
            return
        }

        guard let input = item.audio?.retranscriptionInput else {
            NSSound.beep()
            return
        }

        trackSettingsAction("retranscribe_saved_meeting", page: .home)
        Task { @MainActor in
            let didStart = await meetingSession.retranscribeSavedMeeting(
                micAudioURL: input.micURL,
                systemAudioURL: input.systemURL,
                title: item.title,
                transcriptURL: item.transcriptURL,
                recordingDate: item.startDate ?? item.date
            )
            if !didStart {
                NSSound.beep()
            }
        }
    }

    private func handleOpenOrGenerateLocalSummary(_ item: RecentMeetingItem) {
        guard localMeetingSummariesEnabled else { return }

        if item.summaryPreview != nil {
            trackSettingsAction("open_local_meeting_summary", page: .home)
            NSWorkspace.shared.open(item.transcriptURL)
            return
        }

        generateLocalSummary(for: item)
    }

    private func generateLocalSummary(for item: RecentMeetingItem) {
        guard localMeetingSummariesEnabled else { return }
        guard homeLocalSummaryTasks[item.id] == nil else { return }
        if let unavailableReason = localMeetingSummaryUnavailableReason {
            homeDeleteFailure = HomeDeleteFailure(
                title: "Could not summarize meeting",
                message: unavailableReason
            )
            return
        }
        trackSettingsAction("generate_local_meeting_summary", page: .home)
        recordLocalSummaryEvent(
            event: "local_meeting_summary_started",
            message: "Local Gemma meeting summary started",
            context: [
                "has_existing_summary": item.summaryPreview == nil ? "false" : "true",
                "setup_ready": localSummarySetupStatus.isReady ? "true" : "false",
                "setup_profile": localSummarySetupStatus.profileName,
                "has_runtime": localSummarySetupStatus.hasRuntime ? "true" : "false",
            ]
        )
        clearHomeLocalSummaryNotice()
        homeLocalSummaryJobIDs.insert(item.id)

        let task = Task.detached(priority: .utility) {
            try await LocalMeetingSummarizer().summarize(
                transcriptURL: item.transcriptURL,
                title: item.title
            )
        }
        let taskToken = UUID()
        homeLocalSummaryTasks[item.id] = task
        homeLocalSummaryTaskTokens[item.id] = taskToken

        Task { @MainActor in
            defer {
                if homeLocalSummaryTaskTokens[item.id] == taskToken {
                    homeLocalSummaryJobIDs.remove(item.id)
                    homeLocalSummaryTasks[item.id] = nil
                    homeLocalSummaryTaskTokens[item.id] = nil
                }
            }

            do {
                let result = try await task.value
                guard localMeetingSummariesEnabled else { return }
                presentHomeLocalSummaryNotice(HomeLocalSummaryNotice(
                    transcriptURL: result.transcriptURL,
                    chunkCount: result.chunkCount
                ))
                recordLocalSummaryEvent(
                    event: "local_meeting_summary_completed",
                    message: "Local Gemma meeting summary saved",
                    context: [
                        "chunk_count": "\(result.chunkCount)",
                        "profile": result.profileName,
                    ]
                )
                refreshRecentCapturesAfterLocalSummary()
            } catch is CancellationError {
                recordLocalSummaryEvent(
                    event: "local_meeting_summary_cancelled",
                    message: "Local Gemma meeting summary cancelled"
                )
                return
            } catch {
                guard localMeetingSummariesEnabled else { return }
                recordLocalSummaryEvent(
                    level: .error,
                    event: "local_meeting_summary_failed",
                    message: "Local Gemma meeting summary failed",
                    context: [
                        "error": error.localizedDescription,
                    ]
                )
                homeDeleteFailure = HomeDeleteFailure(
                    title: "Could not summarize meeting",
                    message: error.localizedDescription
                )
            }
        }
    }

    private func presentHomeMeetingPreview(_ item: RecentMeetingItem) {
        trackSettingsAction("preview_recent_meeting", page: .home)
        ActivationTelemetry.trackArtifactAction(
            artifactKind: .meeting,
            actionKind: .preview,
            surface: .homeRow,
            artifactDate: item.date
        )
        homeMeetingPreviewLoadTask?.cancel()
        homeMeetingPreviewLoadTask = Task { @MainActor in
            let readResult = await Self.readMeetingMarkdown(at: item.transcriptURL)
            guard !Task.isCancelled else { return }

            switch readResult {
            case .success(let markdown):
                homeMeetingPreview = HomeMeetingPreview(item: item, markdown: markdown)
            case .failure(let message):
                homeMeetingPreview = HomeMeetingPreview(
                    item: item,
                    markdown: "",
                    readError: message
                )
            }

            homeMeetingPreviewLoadTask = nil
        }
    }

    private static func readMeetingMarkdown(at url: URL) async -> HomeMeetingMarkdownReadResult {
        await Task.detached(priority: .userInitiated) {
            do {
                return .success(try String(contentsOf: url, encoding: .utf8))
            } catch {
                return .failure(error.localizedDescription)
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
                ActivationTelemetry.trackArtifactAction(
                    artifactKind: .dictation,
                    actionKind: .openMarkdown,
                    surface: .homeMenu,
                    artifactDate: entry.createdAt
                )
                NSWorkspace.shared.open(entry.url)
            },
            HomeRowMenuItem(title: "Report issue", symbolName: "flag") {
                trackSettingsAction("flag_dictation", page: .home)
                homeFeedbackTarget = HomeFeedbackTarget.dictation(entry)
            },
            HomeRowMenuItem(title: "Reveal in Finder", symbolName: "folder") {
                trackSettingsAction("reveal_dictation_in_finder", page: .home)
                ActivationTelemetry.trackArtifactAction(
                    artifactKind: .dictation,
                    actionKind: .revealFolder,
                    surface: .homeMenu,
                    artifactDate: entry.createdAt
                )
                NSWorkspace.shared.activateFileViewerSelecting([entry.url])
            },
            HomeRowMenuItem(title: "Delete dictation", symbolName: "trash", isDestructive: true) {
                trackSettingsAction("delete_dictation_request", page: .home)
                homeDeleteConfirmation = HomeDeleteConfirmation(
                    title: "Delete this dictation?",
                    message: "This removes the entry from \(entry.url.lastPathComponent). This cannot be undone."
                ) {
                    trackSettingsAction("delete_dictation_confirm", page: .home)
                    do {
                        try DictationTranscriptStore.deleteEntry(entry)
                        refreshRecentCaptures(force: true)
                    } catch {
                        presentHomeDeleteFailure(
                            title: "Could not delete dictation",
                            error: error
                        )
                    }
                }
            }
        ]
    }

    private func meetingRowMenuItems(for item: RecentMeetingItem) -> [HomeRowMenuItem] {
        var items: [HomeRowMenuItem] = []
        let hasSummary = item.summaryPreview != nil
        let isSummarizing = homeLocalSummaryJobIDs.contains(item.id)
        let isPreparingLocalGemma = isLocalSummaryModelPreparing
        let canGenerateSummary = localMeetingSummaryUnavailableReason == nil
        let hasPendingSpeakerReview = hasSpeakerReviewWork(for: item)
        let summaryActionTitle: String
        if isSummarizing {
            summaryActionTitle = "Running AI summary..."
        } else if hasSummary {
            summaryActionTitle = "Open enhanced transcript"
        } else if isPreparingLocalGemma {
            summaryActionTitle = "Preparing Gemma..."
        } else {
            summaryActionTitle = "Run AI summary"
        }

        if HomeMeetingSummaryBetaPresentationPolicy.shouldShowSummaryMenuActions(isEnabled: localMeetingSummariesEnabled) {
            items.append(
                HomeRowMenuItem(
                    title: summaryActionTitle,
                    symbolName: hasSummary ? "doc.text" : "sparkles",
                    isEnabled: !isSummarizing && (hasSummary || canGenerateSummary)
                ) {
                    handleOpenOrGenerateLocalSummary(item)
                }
            )
        }

        items.append(contentsOf: [
            HomeRowMenuItem(title: "Report issue", symbolName: "flag") {
                trackSettingsAction("flag_meeting", page: .home)
                homeFeedbackTarget = HomeFeedbackTarget.meeting(item)
            },
            HomeRowMenuItem(title: "Show transcript in Finder", symbolName: "doc.text") {
                trackSettingsAction("reveal_meeting_in_finder", page: .home)
                ActivationTelemetry.trackArtifactAction(
                    artifactKind: .meeting,
                    actionKind: .revealFolder,
                    surface: .homeMenu,
                    artifactDate: item.date
                )
                NSWorkspace.shared.activateFileViewerSelecting([item.transcriptURL])
            }
        ])

        if HomeMeetingSummaryBetaPresentationPolicy.shouldShowSummaryMenuActions(isEnabled: localMeetingSummariesEnabled),
           hasSummary {
            items.append(
                HomeRowMenuItem(
                    title: isSummarizing
                        ? "Regenerating AI summary..."
                        : (isPreparingLocalGemma ? "Preparing Gemma..." : "Regenerate AI summary"),
                    symbolName: "arrow.clockwise",
                    isEnabled: !isSummarizing && canGenerateSummary
                ) {
                    generateLocalSummary(for: item)
                }
            )
        }

        if let audio = item.audio, let firstAudio = audio.urls.first {
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
                    NSWorkspace.shared.activateFileViewerSelecting([firstAudio])
                }
            )
        }

        items.append(
            HomeRowMenuItem(title: "Delete meeting", symbolName: "trash", isDestructive: true) {
                trackSettingsAction("delete_meeting_request", page: .home)
                let presentation = HomeDeleteConfirmationPolicy.meeting
                homeDeleteConfirmation = HomeDeleteConfirmation(
                    title: presentation.title,
                    message: presentation.message,
                    confirmTitle: presentation.confirmTitle
                ) {
                    trackSettingsAction("delete_meeting_confirm", page: .home)
                    deleteMeeting(item)
                }
            }
        )

        return items
    }

    private func deleteMeeting(_ item: RecentMeetingItem) {
        let deletionTask = Task.detached(priority: .userInitiated) {
            let plan = HomeMeetingDeletion.plan(for: item)
            await MainActor.run {
                MeetingAudioPlayback.shared.stopIfActive(attachmentIDs: Set(plan.audioAttachmentIDs))
            }
            return try HomeMeetingDeletion.delete(plan)
        }

        Task { @MainActor in
            do {
                _ = try await deletionTask.value
                refreshRecentCaptures(force: true)
            } catch {
                presentHomeDeleteFailure(
                    title: "Could not delete meeting",
                    error: error
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
        guard let firstAudioURL = item.audioURLs.first else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([firstAudioURL])
    }

    private func requestClearFailedMeeting(_ item: MeetingSessionController.FailedMeetingItem) {
        if !item.audioURLs.isEmpty {
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
            return
        }

        trackSettingsAction("home_dismiss_failed_meeting", page: .home)
        clearFailedMeeting(item)
    }

    private func clearFailedMeeting(_ item: MeetingSessionController.FailedMeetingItem) {
        if let audio = failedMeetingAudioAttachment(for: item),
           MeetingAudioPlayback.shared.isActive(audio) {
            MeetingAudioPlayback.shared.stop()
        }

        let didClear: Bool
        let failureTitle: String
        if !item.audioURLs.isEmpty {
            didClear = meetingSession.deleteFailedMeeting(id: item.id)
            failureTitle = "Could not delete failed meeting"
        } else {
            didClear = meetingSession.dismissFailedMeeting(id: item.id)
            failureTitle = "Could not dismiss failed meeting"
        }

        if !didClear {
            presentHomeActionFailure(
                title: failureTitle,
                message: "Transcripted could not update the failed-meeting queue. Check the capture folder, then try again."
            )
        }
    }

    private func presentHomeDeleteFailure(title: String, error: Error) {
        presentHomeActionFailure(title: title, message: error.localizedDescription)
    }

    private func presentHomeActionFailure(title: String, message: String) {
        NSSound.beep()
        homeDeleteFailure = HomeDeleteFailure(
            title: title,
            message: message
        )
    }

    private func retryFailedMeeting(_ item: MeetingSessionController.FailedMeetingItem) {
        let didStart = meetingSession.retryFailedMeeting(id: item.id)
        if !didStart {
            presentHomeActionFailure(
                title: "Could not retry meeting",
                message: failedMeetingRetryUnavailableReason
                    ?? "Transcripted could not start that retry. The saved audio may already be cleared."
            )
        }
    }

    private var homeWelcomeSummary: String {
        let dictations = homeViewModel.todayDictationCount
        let meetings = statsService.todayRecordings
        let dictationLabel = dictations == 1 ? "dictation" : "dictations"
        let meetingLabel = meetings == 1 ? "meeting" : "meetings"
        return "\(formattedInteger(dictations)) \(dictationLabel) · \(formattedInteger(meetings)) \(meetingLabel) today"
    }

    private var homeStatItems: [HomeStatItem] {
        [
            HomeStatItem(
                id: "dictations",
                symbolName: "text.bubble.fill",
                value: formattedInteger(homeViewModel.totalDictationCount),
                label: homeViewModel.totalDictationCount == 1 ? "dictation" : "dictations"
            ),
            HomeStatItem(
                id: "dictation-words",
                symbolName: "text.alignleft",
                value: formattedInteger(homeViewModel.totalDictationWordCount),
                label: "dictated words"
            ),
            HomeStatItem(
                id: "typing-time-saved",
                symbolName: "keyboard",
                value: formattedTypingTimeSaved(forDictatedWords: homeViewModel.totalDictationWordCount),
                label: "saved"
            ),
            HomeStatItem(
                id: "meetings",
                symbolName: "person.2.wave.2.fill",
                value: formattedInteger(statsService.totalRecordings),
                label: statsService.totalRecordings == 1 ? "meeting" : "meetings"
            ),
            HomeStatItem(
                id: "meeting-hours",
                symbolName: "clock.fill",
                value: statsService.formattedTotalHours,
                label: "hours"
            )
        ]
    }

    private func formattedInteger(_ value: Int) -> String {
        Self.homeIntegerFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func formattedTypingTimeSaved(forDictatedWords wordCount: Int) -> String {
        guard wordCount > 0 else { return "0h" }

        let hours = Double(wordCount) / 40.0 / 60.0
        guard hours >= 1 else { return "<1h" }

        if hours < 10 {
            let roundedTenths = (hours * 10).rounded() / 10
            if roundedTenths >= 10 {
                return "\(Int(roundedTenths.rounded()))h"
            }
            return String(format: "%.1fh", roundedTenths)
        }

        return "\(Int(hours.rounded()))h"
    }

    private static let homeIntegerFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    private var homeStreak: Int? {
        let streak = statsService.currentStreak
        return streak > 0 ? streak : nil
    }

    private var homeNeedsAttentionIssues: [HomeNeedsAttentionCard.Issue] {
        var issues: [HomeNeedsAttentionCard.Issue] = []

        if !missingRequiredPermissions.isEmpty {
            issues.append(
                HomeNeedsAttentionCard.Issue(
                    id: "permissions",
                    symbolName: "lock.trianglebadge.exclamationmark",
                    title: "Permissions",
                    detail: permissionsDetailLine,
                    destination: .privacy,
                    actionTitle: "Fix"
                )
            )
        }

        if !meetingSession.failedMeetings.isEmpty {
            let count = meetingSession.failedMeetings.count
            issues.append(
                HomeNeedsAttentionCard.Issue(
                    id: "failed-meetings",
                    symbolName: "waveform.badge.exclamationmark",
                    title: count == 1 ? "Meeting needs attention" : "Meetings need attention",
                    detail: count == 1
                        ? "Saved audio is waiting for review or retry."
                        : "\(count) saved recordings are waiting for review or retry.",
                    destination: .failedMeetings,
                    actionTitle: "Review"
                )
            )
        }

        let modelCard = FirstRunExperience.modelCard(
            for: FirstRunLocalModelState(sttRouter.modelDownloadState),
            model: effectiveTranscriptionModel
        )
        if modelCard.tone == .failed {
            issues.append(
                HomeNeedsAttentionCard.Issue(
                    id: "voice-model-failed",
                    symbolName: "tray.and.arrow.down.fill",
                    title: "Voice model",
                    detail: modelCard.detail,
                    destination: .models,
                    actionTitle: "Fix"
                )
            )
        } else if preferredTranscriptionModel != effectiveTranscriptionModel {
            issues.append(
                HomeNeedsAttentionCard.Issue(
                    id: "voice-model-mismatch",
                    symbolName: "tray.and.arrow.down.fill",
                    title: "Voice model",
                    detail: "\(preferredTranscriptionModel.title) is selected but \(effectiveTranscriptionModel.title) is being used.",
                    destination: .models,
                    actionTitle: "Review"
                )
            )
        }

        return issues
    }

    private var homeMeetingDaySections: [HomeDaySection<HomeMeetingListItem>] {
        let savedMeetings = homeViewModel.meetingDaySections.flatMap { section in
            section.items.map(HomeMeetingListItem.saved)
        }
        let failedMeetings = meetingSession.failedMeetings.map(HomeMeetingListItem.failed)
        let items = (savedMeetings + failedMeetings)
            .sorted { $0.date > $1.date }

        return HomeViewModel.groupByDay(items, dateForItem: \.date)
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

    private var localMeetingSummaryUnavailableReason: String? {
        LocalMeetingSummaryAvailabilityPolicy.unavailableReason(
            isDictationActive: sttRouter.isRecording || sttRouter.isTranscribing,
            isMeetingRecording: meetingSession.isRecording,
            isPreparingModels: meetingSession.state == .loadingModels,
            isPreparingLocalSummaryModel: isLocalSummaryModelPreparing,
            hasMeetingWork: meetingSession.hasRuntimeDiagnosticsWork,
            isSpeakerReviewPending: meetingSession.isSpeakerReviewPending
        )
    }

    private var shortcutsPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsPageIntro(
                title: "Shortcuts",
                summary: "Keyboard triggers and send-after-paste rules."
            )

            SettingsSection(
                title: "Keys",
                detail: "Set push-to-talk, hands-free, and meeting shortcuts."
            ) {
                SettingsToggleRow(
                    title: "Enable dictation shortcuts",
                    detail: dictationShortcutsEnabled
                        ? "Push-to-talk and hands-free keys can start dictation."
                        : "Off. You can still start dictation from the app, and meeting controls still work.",
                    isOn: Binding(
                        get: { dictationShortcutsEnabled },
                        set: { newValue in
                            dictationShortcutsEnabled = newValue
                            trackSettingsToggle("dictation_shortcuts", enabled: newValue, page: .shortcuts)
                            HotkeyPreferences.setDictationShortcutsEnabled(newValue)
                        }
                    )
                )

                HotkeyRecorderContainer(dictationShortcutsEnabled: dictationShortcutsEnabled)
                    .frame(height: 108)

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
            }

            SettingsSection(
                title: "Send After Paste",
                detail: "Press Enter only in the apps you choose."
            ) {
                SettingsToggleRow(
                    title: "Send after dictation",
                    detail: autoEnterEnabled
                        ? "Transcripted sends \(autoEnterKey.title) after it pastes, only in selected apps."
                        : "Off. Dictation only pastes text.",
                    isOn: Binding(
                        get: { autoEnterEnabled },
                        set: { newValue in
                            autoEnterEnabled = newValue
                            trackSettingsToggle("auto_send", enabled: newValue, page: .shortcuts)
                            DictationAutoSendPreferences.setEnabled(newValue)
                        }
                    )
                )

                Picker("Send key", selection: Binding(
                    get: { autoEnterKey },
                    set: { newValue in
                        autoEnterKey = newValue
                        trackSettingsAction("change_auto_send_key", page: .shortcuts)
                        DictationAutoSendPreferences.setSendKey(newValue)
                    }
                )) {
                    ForEach(DictationAutoSendKey.allCases) { key in
                        Text(key.title).tag(key)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!autoEnterEnabled)

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Allowed Apps")
                            .font(.subheadline.weight(.semibold))

                        Spacer()

                        SettingsInlineActionButton(title: "Refresh") {
                            trackSettingsAction("refresh_auto_send_apps", page: .shortcuts)
                            refreshAutoEnterAppCandidates()
                        }

                        SettingsInlineActionButton(title: "Add App...", symbolName: "plus") {
                            trackSettingsAction("add_auto_send_app", page: .shortcuts)
                            chooseAutoEnterApp()
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
                                setAutoEnterApp(bundleID, isAllowed: false)
                            }
                        }
                    }
                }
                .disabled(!autoEnterEnabled)

                if !autoEnterAppCandidates.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Running Apps")
                            .font(.subheadline.weight(.semibold))

                        ForEach(autoEnterAppCandidates) { app in
                            SettingsToggleRow(
                                title: app.name,
                                detail: app.bundleID,
                                isOn: Binding(
                                    get: { autoEnterAllowedBundleIDs.contains(app.bundleID) },
                                    set: { isAllowed in
                                        setAutoEnterApp(app.bundleID, isAllowed: isAllowed)
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
    }

    private var generalPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            GeneralSettingsHeader()

            GeneralSettingsGroup {
                GeneralToggleRow(
                    title: "Launch at login",
                    isOn: Binding(
                        get: { launchAtLoginEnabled },
                        set: { newValue in
                            updateLaunchAtLogin(newValue)
                        }
                    ),
                    help: launchAtLoginStatus,
                    info: GeneralInfo(
                        title: "Launch at login",
                        message: "When this is on, macOS opens Transcripted after you sign in, so the menu bar app and shortcuts are ready without opening it yourself."
                    ),
                    automationIdentifier: "transcripted.settings.general.launch-at-login"
                )

                GeneralToggleRow(
                    title: "Show in Dock",
                    isOn: Binding(
                        get: { showTranscriptedInDock },
                        set: { newValue in
                            showTranscriptedInDock = newValue
                            trackSettingsToggle("show_in_dock", enabled: newValue, page: .general)
                            DockVisibilityPreferences.setVisible(newValue)
                        }
                    ),
                    help: showTranscriptedInDock
                        ? "Transcripted is visible in the Dock."
                        : "Transcripted only appears in the menu bar.",
                    info: GeneralInfo(
                        title: "Show in Dock",
                        message: "Turn this off if you want Transcripted to stay out of the Dock while idle. Settings and active recordings can still bring the app forward when needed."
                    ),
                    automationIdentifier: "transcripted.settings.general.show-in-dock"
                )

                GeneralToggleRow(
                    title: "Dictation sounds",
                    isOn: Binding(
                        get: { uiSoundsEnabled },
                        set: { newValue in
                            uiSoundsEnabled = newValue
                            trackSettingsToggle("dictation_sounds", enabled: newValue, page: .general)
                            UISoundPreferences.setEnabled(newValue)
                        }
                    ),
                    help: uiSoundsEnabled
                        ? "Play sounds when dictation starts and finishes."
                        : "No dictation sounds.",
                    info: GeneralInfo(
                        title: "Dictation sounds",
                        message: "These short sounds tell you when dictation starts, finishes, or hears no speech. Turn them off if you want Transcripted to stay quiet."
                    ),
                    automationIdentifier: "transcripted.settings.general.dictation-sounds"
                )

                GeneralToggleRow(
                    title: "Clean up pasted text",
                    isOn: Binding(
                        get: { dictationCleanupEnabled },
                        set: { newValue in
                            dictationCleanupEnabled = newValue
                            DictationCleanupPreferences.setEnabled(newValue)
                            trackSettingsToggle("dictation_cleanup", enabled: newValue, page: .general)
                        }
                    ),
                    help: dictationCleanupEnabled
                        ? "Remove filler words, repeats, and spacing mistakes before pasting."
                        : "Paste the raw local transcript.",
                    info: GeneralInfo(
                        title: "Clean up pasted text",
                        message: "Transcripted lightly fixes filler words, repeated words, and spacing before it pastes your dictation. Turn this off when you want the raw transcript."
                    ),
                    automationIdentifier: "transcripted.settings.general.cleanup-pasted-text"
                )

                DictationOverlayModeRow(
                    selection: Binding(
                        get: { dictationOverlayMode },
                        set: { newValue in
                            dictationOverlayMode = newValue
                            DictationOverlayPresentationPreferences.setMode(newValue)
                            trackSettingsAction("change_dictation_overlay_mode", page: .general)
                        }
                    )
                )

                GeneralToggleRow(
                    title: "Confirm meeting quits",
                    isOn: Binding(
                        get: { confirmQuitDuringMeetingEnabled },
                        set: { newValue in
                            confirmQuitDuringMeetingEnabled = newValue
                            trackSettingsToggle("meeting_quit_confirmation", enabled: newValue, page: .general)
                            QuitConfirmationPreferences.setConfirmQuitDuringActiveMeetingRecording(newValue)
                        }
                    ),
                    help: confirmQuitDuringMeetingEnabled
                        ? "Ask before stopping a live meeting."
                        : "Quit immediately and save recoverable audio.",
                    info: GeneralInfo(
                        title: "Confirm meeting quits",
                        message: "When this is on, Transcripted asks before quitting during a live meeting so you do not stop a recording by accident."
                    ),
                    automationIdentifier: "transcripted.settings.general.confirm-meeting-quits"
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                GeneralSectionHeading(
                    title: "System",
                    info: GeneralInfo(
                        title: "System",
                        message: "Model, shortcut, and privacy settings now live here so the sidebar stays simpler."
                    )
                )

                GeneralSettingsGroup {
                    GeneralDisclosureRow(
                        title: "Transcription model",
                        value: effectiveTranscriptionModel.title,
                        isExpanded: $showGeneralModelSettings,
                        help: showGeneralModelSettings ? "Hide transcription model settings." : "Show transcription model settings.",
                        automationIdentifier: "transcripted.settings.general.disclosure.transcription-model"
                    ) {
                        trackSettingsAction("toggle_model_settings", page: .general)
                    }

                    if showGeneralModelSettings {
                        GeneralExpandedContent {
                            generalModelSettingsEditor
                        }
                    }

                    GeneralDisclosureRow(
                        title: "Keyboard shortcuts",
                        value: dictationShortcutsEnabled ? "On" : "Off",
                        isExpanded: $showGeneralShortcutSettings,
                        help: showGeneralShortcutSettings ? "Hide keyboard shortcut settings." : "Show keyboard shortcut settings.",
                        automationIdentifier: "transcripted.settings.general.disclosure.keyboard-shortcuts"
                    ) {
                        trackSettingsAction("toggle_shortcut_settings", page: .general)
                    }

                    if showGeneralShortcutSettings {
                        GeneralExpandedContent {
                            generalShortcutSettingsEditor
                        }
                    }

                    GeneralDisclosureRow(
                        title: "Privacy",
                        value: generalPrivacyStatusLine,
                        isExpanded: $showGeneralPrivacySettings,
                        help: showGeneralPrivacySettings ? "Hide privacy settings." : "Show privacy settings.",
                        automationIdentifier: "transcripted.settings.general.disclosure.privacy"
                    ) {
                        trackSettingsAction("toggle_privacy_settings", page: .general)
                    }

                    if showGeneralPrivacySettings {
                        GeneralExpandedContent {
                            generalPrivacySettingsEditor
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                GeneralSectionHeading(
                    title: "Tools",
                    info: GeneralInfo(
                        title: "Tools",
                        message: "These are occasional actions: transcribe an existing audio file, or teach Transcripted corrections for words it hears wrong."
                    )
                )

                GeneralSettingsGroup {
                    GeneralActionRow(
                        title: "Transcribe audio file",
                        value: "Choose",
                        systemImage: "waveform",
                        help: "Choose an audio file to transcribe.",
                        automationIdentifier: "transcripted.settings.general.transcribe-audio-file"
                    ) {
                        trackSettingsAction("import_recording", page: .general)
                        actions.importAudioFile()
                    }

                    GeneralDisclosureRow(
                        title: "Corrections",
                        value: customDictionaryStatusLine,
                        isExpanded: $showGeneralCorrections,
                        help: showGeneralCorrections ? "Hide correction settings." : "Show correction settings.",
                        automationIdentifier: "transcripted.settings.general.disclosure.corrections"
                    ) {
                        trackSettingsAction("toggle_corrections", page: .general)
                    }

                    if showGeneralCorrections {
                        GeneralExpandedContent {
                            generalCorrectionsEditor
                        }
                    }
                }
            }
        }
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
                for: FirstRunLocalModelState(sttRouter.modelDownloadState),
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
                        ForEach(TranscriptionModelChoice.allCases) { model in
                            Text(model.title).tag(model)
                        }
                    }
                    .pickerStyle(.menu)

                    ForEach(TranscriptionModelChoice.allCases) { model in
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

                        Text("Changes apply to the next capture.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    private var generalShortcutSettingsEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsToggleRow(
                title: "Enable dictation shortcuts",
                detail: dictationShortcutsEnabled
                    ? "Push-to-talk and hands-free keys can start dictation."
                    : "Off. You can still start dictation from the app, and meeting controls still work.",
                isOn: Binding(
                    get: { dictationShortcutsEnabled },
                    set: { newValue in
                        dictationShortcutsEnabled = newValue
                        trackSettingsToggle("dictation_shortcuts", enabled: newValue, page: .general)
                        HotkeyPreferences.setDictationShortcutsEnabled(newValue)
                    }
                )
            )

            HotkeyRecorderContainer(dictationShortcutsEnabled: dictationShortcutsEnabled)
                .frame(height: 108)

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
                title: "Send after dictation",
                detail: autoEnterEnabled
                    ? "Transcripted sends \(autoEnterKey.title) after it pastes, only in selected apps."
                    : "Off. Dictation only pastes text.",
                isOn: Binding(
                    get: { autoEnterEnabled },
                    set: { newValue in
                        autoEnterEnabled = newValue
                        trackSettingsToggle("auto_send", enabled: newValue, page: .general)
                        DictationAutoSendPreferences.setEnabled(newValue)
                    }
                )
            )

            Picker("Send key", selection: Binding(
                get: { autoEnterKey },
                set: { newValue in
                    autoEnterKey = newValue
                    trackSettingsAction("change_auto_send_key", page: .general)
                    DictationAutoSendPreferences.setSendKey(newValue)
                }
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

                SettingsToggleRow(
                    title: "Use Apple voice processing",
                    detail: meetingVoiceProcessingEnabled
                        ? "May lower other app audio in Zoom/Meet."
                        : "Off. Transcripted boosts the saved mic and live transcript without changing system audio.",
                    isOn: Binding(
                        get: { meetingVoiceProcessingEnabled },
                        set: { newValue in
                            meetingVoiceProcessingEnabled = newValue
                            trackSettingsToggle("meeting_voice_processing", enabled: newValue, page: .general)
                            MicrophoneProcessingPreferences.setVoiceProcessingEnabled(newValue)
                        }
                    )
                )

                SettingsToggleRow(
                    title: "Identify multiple people on this Mac",
                    detail: splitLocalSpeakersEnabled
                        ? "On. After shared-room meetings, Transcripted asks you to name people captured by your mic."
                        : "Off. The local mic stays as You, which is simpler when only you are near this Mac.",
                    isOn: Binding(
                        get: { splitLocalSpeakersEnabled },
                        set: { newValue in
                            splitLocalSpeakersEnabled = newValue
                            trackSettingsToggle("local_speaker_split", enabled: newValue, page: .general)
                            LocalSpeakerPreferences.setEnabled(newValue)
                        }
                    )
                )

                Text("Meeting audio changes apply to the next recording.")
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
                    isOn: Binding(
                        get: { crashReportingEnabled },
                        set: { newValue in
                            crashReportingEnabled = newValue
                            trackSettingsToggle("crash_reporting", enabled: newValue, page: .general)
                            CrashReportingPreferences.setEnabled(newValue)
                            sentryTestStatus = nil
                            diagnosticsActionStatus = nil
                        }
                    )
                )
                .disabled(!CrashReporter.isAvailable)

                SettingsToggleRow(
                    title: "Send anonymous usage stats",
                    detail: analyticsFootnote,
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

    private var modelsPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsPageIntro(
                title: "Models",
                summary: "Choose the local engine used for transcription."
            )

            SettingsSection(
                title: "Active Model",
                detail: "Used for dictation, meetings, and audio imports."
            ) {
                SettingsStatusCard(
                    title: "Active transcription engine",
                    status: effectiveTranscriptionModel.title,
                    detail: activeModelDetail,
                    tone: .ready
                )

                let modelCard = FirstRunExperience.modelCard(
                    for: FirstRunLocalModelState(sttRouter.modelDownloadState),
                    model: effectiveTranscriptionModel
                )
                SettingsStatusCard(
                    title: "Model files",
                    status: modelCard.status,
                    detail: modelCard.detail,
                    tone: tone(for: modelCard.tone),
                    progress: modelCard.progress,
                    actionTitle: modelDownloadActionTitle,
                    action: modelDownloadAction
                )
            }

            SettingsSection(
                title: "Switch Model",
                detail: "Parakeet is the default. Whisper is optional."
            ) {
                DisclosureGroup("Change model", isExpanded: $showAdvancedModelControls) {
                    VStack(alignment: .leading, spacing: 14) {
                        Picker("Preferred model", selection: Binding(
                            get: { preferredTranscriptionModel },
                            set: { newValue in
                                updatePreferredTranscriptionModel(newValue)
                            }
                        )) {
                            ForEach(TranscriptionModelChoice.allCases) { model in
                                Text(model.title).tag(model)
                            }
                        }
                        .pickerStyle(.menu)

                        ForEach(TranscriptionModelChoice.allCases) { model in
                            ModelChoiceRow(
                                model: model,
                                isPreferred: preferredTranscriptionModel == model,
                                isEffective: effectiveTranscriptionModel == model
                            )
                        }

                        HStack {
                            SettingsInlineActionButton(title: "Use Parakeet", tone: .accent) {
                                updatePreferredTranscriptionModel(.parakeetTDTv3)
                            }
                            .disabled(preferredTranscriptionModel == .parakeetTDTv3)

                            Text("Changes apply to the next capture.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, 8)
                }
            }
        }
    }

    private var peoplePage: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsPageIntro(
                title: "Speakers",
                summary: "Name new voices and manage the people in your meetings."
            )

            SpeakerPeopleSettingsSection(model: speakerPeopleModel)
        }
    }

    private var storagePage: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsPageIntro(
                title: "Storage",
                summary: "Choose where saved Markdown files live."
            )

            SettingsSection(
                title: "Capture Library",
                detail: "Your meeting and dictation Markdown files."
            ) {
                StorageRow(title: "Capture library", url: captureLibraryURL)
                StorageRow(title: "Meeting captures", url: MeetingStoragePaths.transcriptsFolder)
                StorageRow(title: "Dictation captures", url: DictationStoragePaths.transcriptsFolder)

                HStack {
                    SettingsInlineActionButton(title: "Choose Folder", symbolName: "folder") {
                        trackSettingsAction("choose_capture_library", page: .storage)
                        chooseCaptureLibrary()
                    }

                    SettingsInlineActionButton(title: "Reset to Default") {
                        trackSettingsAction("reset_capture_library", page: .storage)
                        TranscriptedStoragePreferences.setCaptureLibraryURL(nil)
                        refreshStoragePaths()
                        AnalyticsReporter.track(
                            "settings_capture_library_changed",
                            properties: [
                                "location_type": "default",
                                "page_id": TranscriptedSettingsPage.storage.analyticsValue,
                            ]
                        )
                    }
                }

                Text("Pick an Obsidian vault or any folder you want agents to read.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SettingsSection(
                title: "Audio Storage",
                detail: "Transcripted keeps transcripts and shrinks retained meeting audio."
            ) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "waveform.badge.magnifyingglass")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Compress WAV to M4A automatically")
                            .font(.subheadline.weight(.medium))
                        Text("After a transcript is saved, Transcripted keeps replay audio in a smaller format and removes the original WAV only after conversion succeeds.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Picker("Delete audio after", selection: Binding(
                    get: { audioRetentionWindow },
                    set: { updateAudioRetentionWindow($0) }
                )) {
                    ForEach(AudioRetentionWindow.allCases) { window in
                        Text(window.title).tag(window)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)

                Text(audioRetentionWindow.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Choosing 7 or 30 days asks before deleting old replay audio.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SettingsSection(
                title: "Local Model Storage",
                detail: "On-device models and optional transcription caches."
            ) {
                if modelCacheLoading, modelCacheSnapshot == nil {
                    ProgressView("Scanning model storage...")
                        .controlSize(.small)
                }

                if let snapshot = modelCacheSnapshot {
                    let includeWhisperInReclaimableCleanup = !effectiveTranscriptionModel.isWhisper
                    let reclaimableBytes = snapshot.reclaimableBytes(includeWhisper: includeWhisperInReclaimableCleanup)
                    ModelCacheMetricRow(
                        title: "Known model and cache footprint",
                        value: snapshot.formattedTotalKnownSize,
                        detail: "FluidAudio models plus Transcripted's app cache."
                    )
                    ModelCacheMetricRow(
                        title: "Reclaimable cache",
                        value: snapshot.formattedReclaimableSize(includeWhisper: includeWhisperInReclaimableCleanup),
                        detail: includeWhisperInReclaimableCleanup
                            ? "Known stale models plus optional Whisper files."
                            : "Known stale models. Whisper is preserved while selected."
                    )
                    if reclaimableBytes > 0 {
                        SettingsInlineActionButton(
                            title: modelCacheCleanupInProgress ? "Removing..." : "Remove Reclaimable Cache",
                            tone: .destructive
                        ) {
                            showReclaimableCacheCleanupConfirmation = true
                        }
                        .disabled(modelCacheCleanupInProgress || modelCacheLoading)
                    }
                    ModelCacheMetricRow(
                        title: "FluidAudio models",
                        value: snapshot.formattedFluidAudioModelsSize,
                        detail: "Parakeet, diarization, and related local model files."
                    )
                    ModelCacheMetricRow(
                        title: "Whisper cache",
                        value: snapshot.formattedWhisperModelsSize,
                        detail: "Optional Whisper models stored by Transcripted."
                    )
                    if snapshot.whisperModelsBytes > 0 {
                        SettingsInlineActionButton(
                            title: modelCacheCleanupInProgress ? "Removing..." : "Remove Whisper Cache",
                            tone: .destructive
                        ) {
                            showWhisperCacheCleanupConfirmation = true
                        }
                        .disabled(effectiveTranscriptionModel.isWhisper || modelCacheCleanupInProgress || modelCacheLoading)

                        if effectiveTranscriptionModel.isWhisper {
                            Text("Switch back to Parakeet before removing the Whisper cache.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if snapshot.staleFluidAudioModelBytes > 0 {
                        ModelCacheMetricRow(
                            title: "Known stale candidates",
                            value: snapshot.formattedStaleFluidAudioModelSize,
                            detail: snapshot.staleModelSummary
                        )

                        SettingsInlineActionButton(
                            title: modelCacheCleanupInProgress ? "Removing..." : "Remove Known Stale Models",
                            tone: .destructive
                        ) {
                            showModelCacheCleanupConfirmation = true
                        }
                        .disabled(modelCacheCleanupInProgress || modelCacheLoading)
                    } else {
                        Text("No known stale Parakeet model folders found.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let modelCacheCleanupStatus {
                        Text(modelCacheCleanupStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if !modelCacheLoading {
                    Text("Model storage has not been scanned yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                SettingsInlineActionButton(title: modelCacheLoading ? "Scanning..." : "Refresh Storage Sizes") {
                    trackSettingsAction("refresh_model_cache_storage", page: .storage)
                    refreshModelCacheSnapshot()
                }
                .disabled(modelCacheLoading)
            }
            .onAppear {
                if modelCacheSnapshot == nil, !modelCacheLoading {
                    refreshModelCacheSnapshot()
                }
            }
            .alert("Remove reclaimable cache?", isPresented: $showReclaimableCacheCleanupConfirmation) {
                Button("Remove", role: .destructive) {
                    removeReclaimableModelCaches()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                let includeWhisper = !effectiveTranscriptionModel.isWhisper
                Text(includeWhisper
                    ? "Transcripted will remove known old Parakeet folders and downloaded Whisper model files. Active Parakeet CoreML stays."
                    : "Transcripted will remove known old Parakeet folders. Whisper stays because it is selected.")
            }
            .alert("Remove stale local models?", isPresented: $showModelCacheCleanupConfirmation) {
                Button("Remove", role: .destructive) {
                    removeStaleModelCaches()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Transcripted will remove only known old Parakeet folders: \(modelCacheSnapshot?.staleModelSummary ?? "none"). Active Parakeet CoreML and Whisper caches stay.")
            }
            .alert("Remove Whisper cache?", isPresented: $showWhisperCacheCleanupConfirmation) {
                Button("Remove", role: .destructive) {
                    removeWhisperModelCache()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Transcripted will remove downloaded Whisper model files. Parakeet stays available, and Whisper can download again later if you choose it.")
            }

            SettingsSection(
                title: "Support Folders",
                detail: "Logs, cache, app state, and temporary audio."
            ) {
                DisclosureGroup("Show support folders", isExpanded: $showSupportFolders) {
                    VStack(alignment: .leading, spacing: 12) {
                        StorageRow(title: "App state", url: appStateFolder)
                        StorageRow(title: "App cache", url: cacheFolder)
                        StorageRow(title: "App logs", url: logsFolder)
                        StorageRow(title: "Temporary recordings", url: recordingsFolder)
                    }
                    .padding(.top, 12)
                }
            }
        }
    }

    private var connectAgentPage: some View {
        AgentConnectionSettingsPage(meetingSession: meetingSession)
    }

    private var betaPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsPageIntro(
                title: "Beta",
                summary: "Turn on experimental local features when you want to test them."
            )

            SettingsSection(
                title: "Experimental Features",
                detail: "These are off by default. Nothing runs automatically unless you turn it on here."
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsToggleRow(
                        title: "AI meeting summaries",
                        detail: localMeetingSummariesEnabled
                            ? "On. Transcripted may prepare Gemma now; meeting summaries still run only when you choose Run AI summary."
                            : "Create private meeting summaries on this Mac. Turning this on may download or warm Gemma before your first summary.",
                        isOn: Binding(
                            get: { localMeetingSummariesEnabled },
                            set: { enabled in
                                localMeetingSummariesEnabled = enabled
                                LocalMeetingSummaryPreferences.setEnabled(enabled)
                                trackSettingsToggle("local_ai_meeting_summaries", enabled: enabled, page: .beta)
                                handleLocalMeetingSummaryToggle(enabled)
                            }
                        ),
                        help: "Opt in to local meeting summaries on Home.",
                        automationIdentifier: "transcripted.settings.beta.ai-meeting-summaries"
                    )

                    betaLocalSummarySetupStatus
                }

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    SettingsToggleRow(
                        title: "Live meeting sidecar",
                        detail: betaLiveMeetingCodexEnabled
                            ? "On. Transcripted prepares a local folder that Codex or Claude Cowork can watch during active meetings."
                            : "Let Codex or Claude Cowork follow an active meeting through a local sidecar folder.",
                        isOn: Binding(
                            get: { betaLiveMeetingCodexEnabled },
                            set: { enabled in
                                betaLiveMeetingCodexEnabled = enabled
                                LiveMeetingCodexPreferences.setEnabled(enabled)
                                trackSettingsToggle("live_meeting_sidecar", enabled: enabled, page: .beta)
                                handleBetaLiveMeetingSidecarToggle(enabled)
                            }
                        ),
                        help: "Opt in to the live meeting sidecar workspace.",
                        automationIdentifier: "transcripted.settings.beta.live-meeting-sidecar"
                    )

                    betaLiveSidecarSetupStatus
                }
            }
        }
    }

    private var betaLocalSummarySetupStatus: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: localSummarySetupStatusSymbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(localSummarySetupStatusColor)
                    .frame(width: 22)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    Text(localSummarySetupStatusTitle)
                        .font(.subheadline.weight(.semibold))
                    Text(localSummarySetupStatusDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                SettingsInlineActionButton(
                    title: "Check setup",
                    symbolName: "arrow.clockwise",
                    automationIdentifier: "transcripted.settings.beta.local-summary.check-setup"
                ) {
                    trackSettingsAction("check_local_summary_setup", page: .beta)
                    refreshLocalSummarySetupStatus()
                }

                if localMeetingSummariesEnabled, localSummarySetupStatus.isReady {
                    SettingsInlineActionButton(
                        title: isLocalSummaryModelPreparing ? "Cancel setup" : "Prepare Gemma",
                        symbolName: isLocalSummaryModelPreparing ? "xmark.circle" : "tray.and.arrow.down",
                        tone: isLocalSummaryModelPreparing ? .warning : .neutral,
                        automationIdentifier: "transcripted.settings.beta.local-summary.prepare-model"
                    ) {
                        if isLocalSummaryModelPreparing {
                            trackSettingsAction("cancel_local_summary_model_prepare", page: .beta)
                            cancelLocalSummaryModelPreparation()
                            localSummaryModelPreparationStatus = "Gemma setup cancelled. You can try Prepare Gemma again when this Mac is idle."
                        } else {
                            trackSettingsAction("prepare_local_summary_model", page: .beta)
                            prepareLocalSummaryModelFromBeta()
                        }
                    }
                }
            }

            if !localSummarySetupStatus.hasRuntime {
                SettingsInlineActionButton(
                    title: "Install uv",
                    symbolName: "arrow.down.circle",
                    tone: .warning,
                    automationIdentifier: "transcripted.settings.beta.local-summary.install-uv"
                ) {
                    trackSettingsAction("open_uv_install_guide", page: .beta)
                    openUVInstallGuide()
                }
            }

            if let localSummaryModelPreparationStatus {
                Text(localSummaryModelPreparationStatus)
                    .font(.caption)
                    .foregroundStyle(isLocalSummaryModelPreparing ? Color.accentColor : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DisclosureGroup("Setup details", isExpanded: $showLocalSummarySetupDetails) {
                VStack(alignment: .leading, spacing: 8) {
                    betaSetupDetailLine(
                        title: "Model",
                        value: "Gemma 4 12B 4-bit MLX"
                    )
                    betaSetupDetailLine(
                        title: "Download",
                        value: "First summary may download several GB into your local Hugging Face cache."
                    )
                    betaSetupDetailLine(
                        title: "Runtime",
                        value: localSummarySetupStatus.hasRuntime
                            ? "uv found at \(localSummarySetupStatus.uvPath ?? "")"
                            : "Install uv so Transcripted can run the local MLX package."
                    )
                    betaSetupDetailLine(
                        title: "Hardware",
                        value: "Recommended: Apple Silicon with 16 GB memory. 8 GB Macs are not supported yet."
                    )
                    betaSetupDetailLine(
                        title: "Privacy",
                        value: "Transcript text stays on this Mac. The model download comes from Hugging Face if it is not cached."
                    )
                }
                .padding(.top, 6)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.top, 2)
    }

    private var betaLiveSidecarSetupStatus: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: betaLiveMeetingCodexEnabled ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(betaLiveMeetingCodexEnabled ? Color.green : Color.secondary)
                    .frame(width: 22)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    Text(betaLiveMeetingCodexEnabled ? "Sidecar workspace is on" : "Sidecar workspace is off")
                        .font(.subheadline.weight(.semibold))
                    Text(betaLiveSidecarDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 10) {
                SettingsInlineActionButton(
                    title: "Open Agent setup",
                    symbolName: "sparkles",
                    tone: .accent,
                    automationIdentifier: "transcripted.settings.beta.open-agent-setup"
                ) {
                    trackSettingsAction("open_agent_setup_from_beta", page: .beta)
                    navigation.selectedPage = .connectAgent
                }

                if let betaFeatureStatus {
                    Label(
                        betaFeatureStatus,
                        systemImage: betaFeatureStatus.hasPrefix("Could not") ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(betaFeatureStatus.hasPrefix("Could not") ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.top, 2)
    }

    private func betaSetupDetailLine(title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func handleBetaLiveMeetingSidecarToggle(_ enabled: Bool) {
        betaFeatureStatus = nil

        if enabled {
            do {
                _ = try prepareBetaLiveMeetingSidecarWorkspaceForUse()
                betaFeatureStatus = "Live meeting sidecar is ready."
            } catch {
                betaLiveMeetingCodexEnabled = false
                LiveMeetingCodexPreferences.setEnabled(false)
                meetingSession.stopLiveCodexSessionFromSettings()
                stopBetaLiveMeetingSidecarPreview()
                betaFeatureStatus = "Could not prepare live meeting sidecar: \(error.localizedDescription)"
            }
        } else {
            meetingSession.stopLiveCodexSessionFromSettings()
            stopBetaLiveMeetingSidecarPreview()
        }
    }

    private func handleLocalMeetingSummaryToggle(_ enabled: Bool) {
        refreshLocalSummarySetupStatus()
        if enabled {
            prepareLocalSummaryModelFromBeta()
        } else {
            cancelLocalSummaryJobs()
            clearHomeLocalSummaryNotice()
            cancelLocalSummaryModelPreparation()
            localSummaryModelPreparationStatus = nil
        }
    }

    private func prepareLocalSummaryModelFromBeta() {
        refreshLocalSummarySetupStatus()
        localSummaryModelPreparationTask?.cancel()

        guard localSummarySetupStatus.hasEnoughMemory else {
            localSummaryModelPreparationStatus = "Gemma needs more memory than this Mac reports."
            return
        }

        guard localSummarySetupStatus.hasRuntime else {
            localSummaryModelPreparationStatus = "Install uv first, then Transcripted can download Gemma here."
            return
        }

        isLocalSummaryModelPreparing = true
        localSummaryModelPreparationStatus = "Preparing Gemma 4 12B locally. Transcripted is warming the local runner and may download several GB from Hugging Face; detailed download progress is not available yet."
        recordLocalSummaryEvent(
            event: "local_meeting_summary_model_prepare_started",
            message: "Local Gemma model preparation started",
            context: [
                "setup_profile": localSummarySetupStatus.profileName,
                "has_runtime": "true",
            ]
        )

        let taskToken = UUID()
        let task = Task.detached(priority: .utility) {
            try await LocalMeetingSummarizer().prepareModelForFirstSummary()
        }
        localSummaryModelPreparationTask = task
        localSummaryModelPreparationToken = taskToken

        Task { @MainActor in
            do {
                let profile = try await task.value
                guard !Task.isCancelled, localSummaryModelPreparationToken == taskToken else { return }
                isLocalSummaryModelPreparing = false
                localSummaryModelPreparationTask = nil
                localSummaryModelPreparationToken = nil
                localSummaryModelPreparationStatus = "Gemma cache is prepared. The first real summary should load from the local cache instead of starting with a surprise setup step."
                recordLocalSummaryEvent(
                    event: "local_meeting_summary_model_prepare_completed",
                    message: "Local Gemma model preparation completed",
                    context: [
                        "profile": profile,
                    ]
                )
            } catch is CancellationError {
                guard localSummaryModelPreparationToken == taskToken else { return }
                isLocalSummaryModelPreparing = false
                localSummaryModelPreparationTask = nil
                localSummaryModelPreparationToken = nil
                localSummaryModelPreparationStatus = nil
                recordLocalSummaryEvent(
                    event: "local_meeting_summary_model_prepare_cancelled",
                    message: "Local Gemma model preparation cancelled"
                )
            } catch {
                guard localSummaryModelPreparationToken == taskToken else { return }
                isLocalSummaryModelPreparing = false
                localSummaryModelPreparationTask = nil
                localSummaryModelPreparationToken = nil
                localSummaryModelPreparationStatus = "Gemma setup failed: \(error.localizedDescription)"
                recordLocalSummaryEvent(
                    level: .error,
                    event: "local_meeting_summary_model_prepare_failed",
                    message: "Local Gemma model preparation failed",
                    context: [
                        "error": error.localizedDescription,
                    ]
                )
            }
        }
    }

    private func cancelLocalSummaryModelPreparation() {
        localSummaryModelPreparationTask?.cancel()
        localSummaryModelPreparationTask = nil
        localSummaryModelPreparationToken = nil
        isLocalSummaryModelPreparing = false
    }

    private func prepareBetaLiveMeetingSidecarWorkspaceForUse() throws -> URL {
        let workspaceURL = try AgentConnectionGuide.ensureLiveMeetingCodexWorkspace()
        if #available(macOS 14.0, *) {
            _ = try LiveMeetingPreviewServer.shared.start(workspaceURL: workspaceURL)
        }
        return workspaceURL
    }

    private func stopBetaLiveMeetingSidecarPreview() {
        if #available(macOS 14.0, *) {
            LiveMeetingPreviewServer.shared.stop()
        }
    }

    private func refreshLocalSummarySetupStatus() {
        localSummarySetupStatus = LocalMeetingSummarySetupStatus.current()
    }

    private func cancelLocalSummaryJobs() {
        for task in homeLocalSummaryTasks.values {
            task.cancel()
        }
        homeLocalSummaryTasks.removeAll()
        homeLocalSummaryTaskTokens.removeAll()
        homeLocalSummaryJobIDs.removeAll()
    }

    private func presentHomeLocalSummaryNotice(_ notice: HomeLocalSummaryNotice) {
        homeLocalSummaryNotice = notice
        homeLocalSummaryNoticeDismissTask?.cancel()
        homeLocalSummaryNoticeDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: HomeLocalSummaryNoticeDismissalPolicy.autoDismissDelayNanoseconds)
            guard !Task.isCancelled,
                  HomeLocalSummaryNoticeDismissalPolicy.shouldDismiss(
                    current: homeLocalSummaryNotice,
                    scheduledNoticeID: notice.id
                  ) else { return }
            homeLocalSummaryNotice = nil
            homeLocalSummaryNoticeDismissTask = nil
        }
    }

    private func clearHomeLocalSummaryNotice(id: UUID? = nil) {
        if let id, homeLocalSummaryNotice?.id != id { return }
        homeLocalSummaryNoticeDismissTask?.cancel()
        homeLocalSummaryNoticeDismissTask = nil
        homeLocalSummaryNotice = nil
    }

    private func refreshRecentCapturesAfterLocalSummary() {
        guard navigation.selectedPage == .home else {
            refreshRecentCaptures(force: true)
            return
        }
        homeViewModel.reloadVisibleContent()
        Task { @MainActor in
            await statsService.refreshStats()
        }
    }

    private func recordLocalSummaryEvent(
        level: EventLevel = .info,
        event: String,
        message: String,
        context: [String: String] = [:]
    ) {
        DiagnosticsTrail.record(
            logger: appLogger,
            level: level,
            engine: "meeting",
            event: event,
            message: message,
            context: context
        )
    }

    private func openUVInstallGuide() {
        guard let url = URL(string: "https://docs.astral.sh/uv/getting-started/installation/") else { return }
        NSWorkspace.shared.open(url)
    }

    private var localSummarySetupStatusTitle: String {
        if isLocalSummaryModelPreparing {
            return "Preparing Gemma locally"
        }
        if !localSummarySetupStatus.hasEnoughMemory {
            return "Not supported on this Mac"
        }
        if !localSummarySetupStatus.hasRuntime {
            return "Setup needed"
        }
        return "Runtime ready"
    }

    private var localSummarySetupStatusDetail: String {
        if isLocalSummaryModelPreparing {
            return "Transcripted is downloading or warming the local Gemma runner. Home summaries stay paused so this Mac only runs one Gemma job at a time; detailed download progress is not available yet."
        }
        if !localSummarySetupStatus.hasEnoughMemory {
            return "This Mac reports \(localSummarySetupStatus.physicalMemoryGB) GB memory. Local Gemma summaries need at least \(localSummarySetupStatus.minimumMemoryGB) GB to avoid heavy swapping."
        }
        if !localSummarySetupStatus.hasRuntime {
            return "Install uv first. The first summary may download a large local Gemma model, then future summaries reuse the local cache."
        }
        return "uv is installed. Use Prepare Gemma to download or warm the local model before running a meeting summary."
    }

    private var localSummarySetupStatusSymbol: String {
        if isLocalSummaryModelPreparing {
            return "arrow.triangle.2.circlepath"
        }
        if localSummarySetupStatus.isReady {
            return "checkmark.circle.fill"
        }
        return "exclamationmark.circle.fill"
    }

    private var localSummarySetupStatusColor: Color {
        if isLocalSummaryModelPreparing {
            return Color.accentColor
        }
        if localSummarySetupStatus.isReady {
            return .green
        }
        return .orange
    }

    private var betaLiveSidecarDetail: String {
        if betaLiveMeetingCodexEnabled {
            return "Transcripted prepares the local workspace. Use Agent setup to open Codex, copy Cowork setup, or open the live preview."
        }
        return "Normal meeting transcripts still save as usual. Turn this on only when you want a local agent to watch active meetings."
    }

    private var privacyPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsPageIntro(
                title: "Privacy",
                summary: "Permissions and optional reporting."
            )

            SettingsSection(
                title: "Permissions",
                detail: "Needed for capture, paste-back, and meeting prompts."
            ) {
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

            SettingsSection(
                title: "Meeting Audio",
                detail: "How Transcripted handles your microphone during meetings."
            ) {
                SettingsToggleRow(
                    title: "Use Apple voice processing for Safari/Firefox mic attenuation",
                    detail: meetingVoiceProcessingEnabled
                        ? "May lower other app audio in Zoom/Meet."
                        : "Off. Transcripted boosts the saved mic and live transcript in software without changing system audio.",
                    isOn: Binding(
                        get: { meetingVoiceProcessingEnabled },
                        set: { newValue in
                            meetingVoiceProcessingEnabled = newValue
                            trackSettingsToggle("meeting_voice_processing", enabled: newValue, page: .privacy)
                            MicrophoneProcessingPreferences.setVoiceProcessingEnabled(newValue)
                        }
                    )
                )

                SettingsToggleRow(
                    title: "Identify multiple people on this Mac",
                    detail: splitLocalSpeakersEnabled
                        ? "On. After shared-room meetings, Transcripted asks you to name the people captured by your mic."
                        : "Off. The local mic stays as You, which is simpler when you are the only person near this Mac.",
                    isOn: Binding(
                        get: { splitLocalSpeakersEnabled },
                        set: { newValue in
                            splitLocalSpeakersEnabled = newValue
                            trackSettingsToggle("local_speaker_split", enabled: newValue, page: .privacy)
                            LocalSpeakerPreferences.setEnabled(newValue)
                        }
                    )
                )

                Text("Meeting audio changes apply to the next recording.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            SettingsSection(
                title: "Reporting",
                detail: "Optional. Scrubbed before anything leaves this Mac."
            ) {
                SettingsToggleRow(
                    title: "Send crash and error reports",
                    detail: crashReportingFootnote,
                    isOn: Binding(
                        get: { crashReportingEnabled },
                        set: { newValue in
                            crashReportingEnabled = newValue
                            trackSettingsToggle("crash_reporting", enabled: newValue, page: .privacy)
                            CrashReportingPreferences.setEnabled(newValue)
                            sentryTestStatus = nil
                            diagnosticsActionStatus = nil
                        }
                    )
                )
                    .disabled(!CrashReporter.isAvailable)

                SettingsToggleRow(
                    title: "Send anonymous usage stats",
                    detail: analyticsFootnote,
                    isOn: Binding(
                        get: { anonymousAnalyticsEnabled },
                        set: { newValue in
                            anonymousAnalyticsEnabled = newValue
                            if newValue {
                                AnalyticsPreferences.setEnabled(true)
                                trackSettingsToggle("anonymous_analytics", enabled: true, page: .privacy)
                            } else {
                                trackSettingsToggle("anonymous_analytics", enabled: false, page: .privacy)
                                AnalyticsPreferences.setEnabled(false)
                            }
                            diagnosticsActionStatus = nil
                        }
                    )
                )
                    .disabled(!AnalyticsReporter.isAvailable)

                HStack {
                    SettingsInlineActionButton(title: "Send Test Sentry Event", tone: .warning) {
                        trackSettingsAction("send_test_sentry_event", page: .privacy)
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

    private var aboutPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsPageIntro(
                title: "About",
                summary: "Version and updates."
            )

            SettingsSection(
                title: "Version",
                detail: "Build info and update controls."
            ) {
                SettingsStatusCard(
                    title: "Transcripted",
                    status: TranscriptedSupportActions.appVersionDescription,
                    detail: "Local-first dictation and meeting notes.",
                    tone: .ready
                )

                SettingsStatusCard(
                    title: "Updates",
                    status: aboutUpdateStatusTitle,
                    detail: aboutUpdateStatusDetail,
                    tone: aboutUpdateStatusTone
                )

                VStack(alignment: .leading, spacing: 8) {
                    SettingsToggleRow(
                        title: "Check automatically",
                        detail: sparkleUpdater.automaticUpdateSettings.automaticChecksEnabled
                            ? "Transcripted checks for updates in the background."
                            : "Transcripted only checks when you ask.",
                        isOn: Binding(
                            get: { sparkleUpdater.automaticUpdateSettings.automaticChecksEnabled },
                            set: { newValue in
                                trackSettingsToggle("automatic_update_checks", enabled: newValue, page: .about)
                                sparkleUpdater.setAutomaticallyChecksForUpdates(newValue)
                            }
                        )
                    )

                    SettingsToggleRow(
                        title: "Download automatically",
                        detail: sparkleUpdater.automaticUpdateSettings.automaticDownloadsEnabled
                            ? "Transcripted downloads available updates in the background."
                            : "Transcripted waits before downloading updates.",
                        isOn: Binding(
                            get: { sparkleUpdater.automaticUpdateSettings.automaticDownloadsEnabled },
                            set: { newValue in
                                trackSettingsToggle("automatic_update_downloads", enabled: newValue, page: .about)
                                sparkleUpdater.setAutomaticallyDownloadsUpdates(newValue)
                            }
                        )
                    )
                        .disabled(!sparkleUpdater.automaticUpdateSettings.automaticDownloadsAllowed)

                    Text(automaticUpdatesDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    SettingsInlineActionButton(
                        title: aboutUpdateButtonTitle,
                        tone: .accent
                    ) {
                        trackSettingsAction(settingsUpdateActionID, page: .about)
                        sparkleUpdater.performUserUpdateAction(surface: "settings_about")
                    }
                    .disabled(!aboutUpdateButtonEnabled)
                }
            }
        }
    }

    private var supportPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsPageIntro(
                title: "Support",
                summary: "Need help, found a bug, or want to send feedback? Email is the best way to reach the team building Transcripted."
            )

            SupportActionCard(
                symbolName: "envelope.fill",
                title: "Email support",
                detail: "Send feedback, ask for help, or tell us what felt broken. This opens a prefilled email to help@transcripted.app.",
                buttonTitle: "Email support",
                buttonSymbolName: "paperplane.fill",
                tone: .primary,
                status: nil,
                isEnabled: true
            ) {
                trackSettingsAction("submit_feedback", page: .support)
                actions.sendFeedback()
            }

            SupportActionCard(
                symbolName: "waveform.path.ecg",
                title: "Send diagnostics",
                detail: "Had an error or something felt broken? Send a privacy-safe diagnostic event so we can investigate and try to fix it.",
                buttonTitle: "One-click send diagnostics",
                buttonSymbolName: "bolt.fill",
                tone: .secondary,
                status: diagnosticsActionStatus,
                isEnabled: CrashReporter.isAvailable && crashReportingEnabled
            ) {
                trackSettingsAction("send_diagnostic_event", page: .support)
                sendDiagnosticEvent()
            }

            SupportPrivacyNote()
        }
    }

    private struct SupportActionCard: View {
        enum Tone {
            case primary
            case secondary
        }

        let symbolName: String
        let title: String
        let detail: String
        let buttonTitle: String
        let buttonSymbolName: String
        let tone: Tone
        let status: String?
        let isEnabled: Bool
        let action: () -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: symbolName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(iconForeground)
                        .frame(width: 34, height: 34)
                        .background(iconBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                    VStack(alignment: .leading, spacing: 5) {
                        Text(title)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Color.primary)

                        Text(detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
                }

                Button(action: action) {
                    Label(buttonTitle, systemImage: buttonSymbolName)
                        .font(.callout.weight(.semibold))
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .foregroundStyle(buttonForeground)
                }
                .buttonStyle(SettingsHoverButtonStyle(
                    tone: buttonInteractionTone,
                    cornerRadius: 8,
                    normalFill: buttonBackground,
                    normalStroke: buttonStroke,
                    hoverFill: buttonHoverBackground,
                    pressedFill: buttonPressedBackground,
                    hoverStroke: buttonHoverStroke
                ))
                .disabled(!isEnabled)

                if let status, !status.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color(nsColor: .systemGreen))

                        Text(status)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(cardStroke, lineWidth: 1)
            )
        }

        private var iconForeground: Color {
            switch tone {
            case .primary:
                return Color(nsColor: .systemGreen)
            case .secondary:
                return Color.accentColor
            }
        }

        private var iconBackground: Color {
            switch tone {
            case .primary:
                return Color(nsColor: .systemGreen).opacity(0.16)
            case .secondary:
                return Color.accentColor.opacity(0.14)
            }
        }

        private var cardBackground: Color {
            switch tone {
            case .primary:
                return Color(nsColor: .controlBackgroundColor).opacity(0.9)
            case .secondary:
                return Color(nsColor: .controlBackgroundColor).opacity(0.72)
            }
        }

        private var cardStroke: Color {
            switch tone {
            case .primary:
                return Color(nsColor: .systemGreen).opacity(0.25)
            case .secondary:
                return Color.primary.opacity(0.08)
            }
        }

        private var buttonBackground: Color {
            switch tone {
            case .primary:
                return Color(nsColor: .systemGreen)
            case .secondary:
                return Color.secondary.opacity(0.16)
            }
        }

        private var buttonInteractionTone: SettingsInteractionTone {
            switch tone {
            case .primary:
                return .accent
            case .secondary:
                return .neutral
            }
        }

        private var buttonHoverBackground: Color {
            switch tone {
            case .primary:
                return Color(nsColor: .systemGreen).opacity(0.86)
            case .secondary:
                return SettingsInteractionPalette.hoverFill(for: .neutral)
            }
        }

        private var buttonPressedBackground: Color {
            switch tone {
            case .primary:
                return Color(nsColor: .systemGreen).opacity(0.76)
            case .secondary:
                return SettingsInteractionPalette.pressedFill(for: .neutral)
            }
        }

        private var buttonStroke: Color {
            switch tone {
            case .primary:
                return Color(nsColor: .systemGreen).opacity(0.24)
            case .secondary:
                return Color.primary.opacity(0.08)
            }
        }

        private var buttonHoverStroke: Color {
            switch tone {
            case .primary:
                return Color(nsColor: .systemGreen).opacity(0.34)
            case .secondary:
                return SettingsInteractionPalette.hoverStroke(for: .neutral)
            }
        }

        private var buttonForeground: Color {
            switch tone {
            case .primary:
                return .white
            case .secondary:
                return .primary
            }
        }
    }

    private struct SupportPrivacyNote: View {
        var body: some View {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)

                Text("Never sent: transcript text, audio, names, emails, file paths, raw URLs, or meeting titles.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2)
        }
    }

    private var settingsFooterShowsUpdateBadge: Bool {
        sparkleUpdater.updateStatus.readyToInstallVersion != nil
    }

    private var settingsFooterActionEnabled: Bool {
        switch sparkleUpdater.updateStatus.state {
        case .updateAvailable where sparkleUpdater.automaticUpdateSettings.automaticDownloadsEnabled:
            return false
        default:
            return sparkleUpdater.updateStatus.canRunUserUpdateAction
        }
    }

    private var settingsFooterTitle: String {
        if let version = sparkleUpdater.updateStatus.readyToInstallVersion {
            return "Restart to update \(version)"
        }

        switch sparkleUpdater.updateStatus.state {
        case .checking:
            return "Checking for updates"
        case .updateAvailable(let version) where sparkleUpdater.automaticUpdateSettings.automaticDownloadsEnabled:
            return "Preparing update \(version)"
        case .downloading(let version):
            return "Preparing update \(version)"
        case .readyToInstall:
            return TranscriptedSupportActions.appVersionDescription
        case .noUpdateAvailable, .unknown, .readyToCheck:
            return TranscriptedSupportActions.appVersionDescription
        case .updateAvailable:
            return TranscriptedSupportActions.appVersionDescription
        }
    }

    private var settingsFooterDetail: String? {
        if sparkleUpdater.updateStatus.readyToInstallVersion != nil {
            return TranscriptedSupportActions.appVersionDescription
        }
        return nil
    }

    private var settingsFooterHelp: String {
        if let version = sparkleUpdater.updateStatus.availableUpdateVersion {
            if case .readyToInstall = sparkleUpdater.updateStatus.state {
                return "Restart to install update \(version)."
            }
            if sparkleUpdater.automaticUpdateSettings.automaticDownloadsEnabled {
                return "Transcripted will ask you to restart after update \(version) is downloaded and verified."
            }
            return "Install update \(version)."
        }
        return "Check for updates."
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

    private var activeModelDetail: String {
        "\(effectiveTranscriptionModel.summary) Audio and transcripts stay local. Model files are stored outside app updates."
    }

    private var modelDownloadActionTitle: String? {
        switch FirstRunLocalModelState(sttRouter.modelDownloadState) {
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

    private var modelDownloadAction: (() -> Void)? {
        modelDownloadAction(page: .models)
    }

    private func modelDownloadAction(page: TranscriptedSettingsPage) -> (() -> Void)? {
        guard modelDownloadActionTitle != nil else { return nil }
        return {
            trackSettingsAction("download_model", page: page)
            Task { @MainActor in
                await sttRouter.initializeSelectedModel()
            }
        }
    }

    private var missingRequiredPermissions: [TranscriptedPermissionKind] {
        TranscriptedPermissionKind.allCases.filter { kind in
            kind.isRequiredOnFirstLaunch && !(permissionStates[kind] ?? false)
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
            return "Required permissions are on. Meeting permissions are optional."
        }
        return "Turn on \(missingRequiredPermissions.map(\.title).joined(separator: " and ")) to record and paste back."
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

    private func homeModelDetail(from modelCard: FirstRunModelCardState) -> String {
        switch modelCard.tone {
        case .ready:
            return "\(effectiveTranscriptionModel.title) is ready on this Mac."
        case .working:
            return modelCard.title
        case .failed:
            return modelCard.detail
        }
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
        customDictionaryText = CustomDictionaryPreferences.rawText()
        customDictionaryRows = CorrectionDraftRow.rows(from: customDictionaryText)
        preferredTranscriptionModel = TranscriptionModelPreferences.preferredModel()
        showAdvancedModelControls = preferredTranscriptionModel != TranscriptionModelPreferences.defaultModel
        uiSoundsEnabled = UISoundPreferences.isEnabled()
        meetingVoiceProcessingEnabled = MicrophoneProcessingPreferences.isVoiceProcessingEnabled()
        splitLocalSpeakersEnabled = LocalSpeakerPreferences.isEnabled()
        refreshLocalSummarySetupStatus()
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

    private func trackSettingsPageViewed(_ page: TranscriptedSettingsPage, source: String) {
        AnalyticsReporter.track(
            "settings_page_viewed",
            properties: [
                "page_id": page.analyticsValue,
                "source": source,
            ]
        )
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

    private func refreshPermissions() {
        permissionStates = PermissionSnapshot.current()
    }

    private func refreshStoragePaths() {
        captureLibraryURL = FileManager.default.transcriptedCaptureLibraryDir
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
                    modelCacheCleanupStatus = "Could not remove stale models: \(error.localizedDescription)"
                }
            }
        }
    }

    private func removeReclaimableModelCaches() {
        guard !modelCacheCleanupInProgress else { return }
        let includeWhisper = !effectiveTranscriptionModel.isWhisper
        modelCacheCleanupInProgress = true
        modelCacheCleanupStatus = nil

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
                    modelCacheCleanupStatus = "Could not remove reclaimable cache: \(error.localizedDescription)"
                }
            }
        }
    }

    private func removeWhisperModelCache() {
        guard !modelCacheCleanupInProgress, !effectiveTranscriptionModel.isWhisper else { return }
        modelCacheCleanupInProgress = true
        modelCacheCleanupStatus = nil

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
                    modelCacheCleanupStatus = "Could not remove Whisper cache: \(error.localizedDescription)"
                }
            }
        }
    }

    private func updateAudioRetentionWindow(_ window: AudioRetentionWindow) {
        guard window != audioRetentionWindow else { return }
        guard window.days == nil else {
            pendingAudioRetentionWindow = window
            return
        }

        applyAudioRetentionWindow(window)
    }

    private func applyAudioRetentionWindow(_ window: AudioRetentionWindow) {
        audioRetentionWindow = window
        trackSettingsAction("audio_retention_changed", page: .storage)
        AudioStoragePreferences.setDeleteAudioAfter(window)
        Task.detached(priority: .utility) {
            await MeetingAudioStorageManager.processExistingRetainedAudio(
                in: MeetingStoragePaths.transcriptsFolder,
                retentionWindow: window
            )
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
        homeDashboardRefreshGeneration += 1
        let generation = homeDashboardRefreshGeneration
        lastHomeDashboardRefreshStartedAt = now
        homeDashboardRefreshInFlight = true
        homeViewModel.refresh()

        homeDashboardRefreshTask = Task { @MainActor in
            await statsService.refreshStats()
            guard !Task.isCancelled, generation == homeDashboardRefreshGeneration else { return }
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
            launchAtLoginStatus = "Could not update launch at login: \(error.localizedDescription)"
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
        page: TranscriptedSettingsPage = .models
    ) {
        preferredTranscriptionModel = model
        showAdvancedModelControls = true
        trackSettingsAction("switch_model", page: page)
        TranscriptionModelPreferences.setPreferredModel(model)
        Task { @MainActor in
            await sttRouter.initializeSelectedModel()
        }
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
        TranscriptedStoragePreferences.setCaptureLibraryURL(url)
        refreshStoragePaths()
        AnalyticsReporter.track(
            "settings_capture_library_changed",
            properties: [
                "location_type": isUsingDefaultCaptureLibrary ? "default" : "custom",
                "page_id": TranscriptedSettingsPage.storage.analyticsValue,
            ]
        )
    }

    private var sortedAutoEnterAllowedBundleIDs: [String] {
        autoEnterAllowedBundleIDs.sorted { lhs, rhs in
            autoEnterDisplayName(for: lhs).localizedCaseInsensitiveCompare(autoEnterDisplayName(for: rhs)) == .orderedAscending
        }
    }

    private func setAutoEnterApp(
        _ bundleID: String,
        isAllowed: Bool,
        page: TranscriptedSettingsPage = .shortcuts
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
        page == .general || page == .shortcuts
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

    private func chooseAutoEnterApp(page: TranscriptedSettingsPage = .shortcuts) {
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
        if let candidate = autoEnterAppCandidates.first(where: { $0.bundleID == bundleID }) {
            return candidate.name
        }

        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url.deletingPathExtension().lastPathComponent
        }

        return bundleID
    }

    private var aboutUpdateStatusTitle: String {
        switch sparkleUpdater.updateStatus.state {
        case .unknown, .readyToCheck:
            return "Ready to check"
        case .checking:
            return "Checking for updates"
        case .noUpdateAvailable:
            return "Up to date"
        case .updateAvailable(let version):
            if sparkleUpdater.automaticUpdateSettings.automaticDownloadsEnabled {
                return "Preparing update (\(version))"
            }
            return "Update available (\(version))"
        case .downloading(let version):
            return "Downloading update (\(version))"
        case .readyToInstall(let version):
            return "Ready to restart (\(version))"
        }
    }

    private var aboutUpdateStatusDetail: String {
        switch sparkleUpdater.updateStatus.state {
        case .unknown, .readyToCheck:
            return "Check for a newer release."
        case .checking:
            return "Looking for updates now."
        case .noUpdateAvailable:
            return "This Mac is on the newest visible version."
        case .updateAvailable(let version):
            if sparkleUpdater.automaticUpdateSettings.automaticDownloadsEnabled {
                return "Transcripted is preparing version \(version). You only need to restart when it is ready."
            }
            return "Version \(version) is ready to install."
        case .downloading(let version):
            return "Version \(version) is downloading."
        case .readyToInstall(let version):
            return "Version \(version) is downloaded."
        }
    }

    private var aboutUpdateStatusTone: SettingsStatusCard.Tone {
        switch sparkleUpdater.updateStatus.state {
        case .unknown, .readyToCheck:
            return .working
        case .checking:
            return .working
        case .noUpdateAvailable:
            return .ready
        case .updateAvailable where sparkleUpdater.automaticUpdateSettings.automaticDownloadsEnabled:
            return .working
        case .downloading:
            return .working
        case .updateAvailable, .readyToInstall:
            return .caution
        }
    }

    private var aboutUpdateButtonTitle: String {
        switch sparkleUpdater.updateStatus.state {
        case .updateAvailable(let version):
            if sparkleUpdater.automaticUpdateSettings.automaticDownloadsEnabled {
                return "Preparing Update…"
            }
            return "Install \(version)"
        case .downloading:
            return "Downloading…"
        case .readyToInstall:
            return "Restart to Update"
        case .checking:
            return "Checking for Updates…"
        case .unknown, .readyToCheck, .noUpdateAvailable:
            return "Check for Updates"
        }
    }

    private var aboutUpdateButtonEnabled: Bool {
        switch sparkleUpdater.updateStatus.state {
        case .updateAvailable where sparkleUpdater.automaticUpdateSettings.automaticDownloadsEnabled:
            return false
        default:
            return sparkleUpdater.updateStatus.canRunUserUpdateAction
        }
    }

    private var automaticUpdatesDetail: String {
        let settings = sparkleUpdater.automaticUpdateSettings
        if settings.automaticDownloadsEnabled {
            return "Transcripted will download updates in the background. When one is ready, you only need to restart."
        }
        if settings.automaticChecksEnabled {
            return "Transcripted will check in the background and show an update badge when one is ready."
        }
        return "Turn on automatic checks to see updates sooner."
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

    private func formattedRecentDate(_ date: Date) -> String {
        Self.recentCaptureDateFormatter.string(from: date)
    }

    private static let recentCaptureDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
