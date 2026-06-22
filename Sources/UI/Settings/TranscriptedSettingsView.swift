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
    @ObservedObject private var statsService: StatsService = .shared

    private let actions: TranscriptedSettingsActions
    private let appLogger: AppLogger

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
    @State private var meetingMicProcessingMode = MicrophoneProcessingPreferences.mode()
    @State private var splitLocalSpeakersEnabled = LocalSpeakerPreferences.isEnabled()
    @State private var confirmQuitDuringMeetingEnabled = QuitConfirmationPreferences.confirmQuitDuringActiveMeetingRecording()
    @State private var autoDetectCallsEnabled = AutoCallDetectionPreferences.isEnabled()
    @State private var audioRetentionWindow = AudioStoragePreferences.deleteAudioAfter()
    @State private var pendingAudioRetentionWindow: AudioRetentionWindow?
    @StateObject private var homeViewModel = HomeViewModel()
    @State private var homeCopiedRowID: String?
    @State private var homeDeleteConfirmation: HomeDeleteConfirmation?
    @State private var homeDeleteFailure: HomeDeleteFailure?
    @State private var homeFeedbackTarget: HomeFeedbackTarget?
    @State private var homeShowsAllFailedMeetings = false
    @State private var homeShowsStatsDetails = false
    @State private var homeMeetingSearchQuery = ""
    @State private var homeMeetingPreview: HomeMeetingPreview?
    @State private var homeMeetingPreviewLoadTask: Task<Void, Never>?
    @State private var homeLocalSummaryJobIDs: Set<String> = []
    @State private var homeLocalSummaryTasks: [String: Task<LocalMeetingSummaryResult, Error>] = [:]
    @State private var homeLocalSummaryTaskTokens: [String: UUID] = [:]
    @State private var homeLocalSummaryNotice: HomeLocalSummaryNotice?
    @State private var homeLocalSummaryNoticeDismissTask: Task<Void, Never>?
    @AppStorage(LocalMeetingSummaryPreferences.enabledKey) private var localMeetingSummariesEnabled = LocalMeetingSummaryPreferences.defaultEnabled
    @AppStorage(LocalMeetingSummaryPreferences.providerKey) private var localMeetingSummaryProviderRawValue = LocalMeetingSummaryProvider.defaultProvider.rawValue
    @AppStorage(LiveMeetingCodexPreferences.enabledKey) private var betaLiveMeetingCodexEnabled = LiveMeetingCodexPreferences.defaultEnabled
    @State private var betaFeatureStatus: String?
    @State private var localSummarySetupStatus = LocalMeetingSummarySetupStatus.current()
    @State private var appleSummarySetupStatus = AppleFoundationSummarySetupStatus.current()
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
                sidebarRows(for: SettingsSidebarSection.primarySection.pages)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    Divider()
                    settingsPagesToggle
                    settingsSidebarFooter
                }
                .background {
                    // Solid backdrop when the user opts into Reduce Transparency.
                    if reduceTransparency {
                        Color(nsColor: .windowBackgroundColor)
                    } else {
                        Rectangle().fill(.thinMaterial)
                    }
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
                        VStack(alignment: .leading, spacing: 24) {
                            if SettingsSidebarSection.isSettingsPage(navigation.selectedPage) {
                                settingsTabStrip
                            }
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
                longestStreak: statsService.longestStreak > 0 ? statsService.longestStreak : nil,
                onDone: {
                    homeShowsStatsDetails = false
                }
            )
        }
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
                    openOwnFile(
                        candidateURLs: [preview.transcriptURL],
                        failureTitle: "Could not open transcript",
                        failureMessage: "Transcripted couldn't find this meeting's transcript on disk. It may have been moved, renamed, or deleted outside the app."
                    )
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
                onRenameTitle: { newTitle in
                    renameMeetingPreview(preview, to: newTitle)
                },
                onDone: {
                    homeMeetingPreview = nil
                }
            )
        }
        // One alert modifier, not three. Stacking multiple legacy `.alert(item:)`
        // on the same view shadows all but the last — which silently killed the
        // meeting-delete confirmation (first of three). `rootAlertBinding` routes
        // the three independent states through a single presenter so the active
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
                    dismissButton: .default(Text("OK"))
                )
            case .audioRetention(let window):
                return Alert(
                    title: Text("Delete old replay audio?"),
                    message: Text("Transcripted will keep your Markdown transcripts, but retained replay audio older than \(window.title) will be permanently removed now and cleaned up automatically later."),
                    primaryButton: .cancel(),
                    secondaryButton: .destructive(Text("Delete Old Audio")) {
                        applyAudioRetentionWindow(window)
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
            cancelLocalSummaryModelPreparation()
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

    private var settingsPagesToggle: some View {
        let isInSettings = SettingsSidebarSection.isSettingsPage(navigation.selectedPage)
        return Button {
            trackSettingsAction("open_settings_area", page: navigation.selectedPage)
            navigation.selectedPage = .general
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isInSettings ? Color.accentColor : Color.secondary)
                Text("Settings")
                    .font(.caption.weight(isInSettings ? .semibold : .regular))
                    .foregroundStyle(isInSettings ? Color.primary : Color.secondary)

                Spacer(minLength: 6)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsHoverButtonStyle(tone: isInSettings ? .accent : .neutral, cornerRadius: 10))
        .help("Open settings")
        .accessibilityIdentifier("transcripted.settings.sidebar.settings-toggle")
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

    private var settingsSidebarFooter: some View {
        Button {
            guard settingsFooterActionEnabled else { return }
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
        case .dictations:
            dictationsPage
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
        VStack(alignment: .leading, spacing: 20) {
            HomeCanvasHeader(
                greeting: homeGreeting,
                streakText: homeStreak.map { "\($0)d" },
                hoursText: statsService.formattedTotalHours,
                wordsText: formattedInteger(homeViewModel.totalDictationWordCount),
                onViewStats: {
                    trackSettingsAction("open_home_stats", page: .home)
                    homeShowsStatsDetails = true
                }
            )
            .padding(.top, 8)

            if !homeAttentionIssues.isEmpty {
                HomeAttentionPillsRow(issues: homeAttentionIssues) { issue in
                    reviewHomeAttentionIssue(issue)
                }
            }

            homeFailedMeetingsCard

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
                            openOwnFile(
                                candidateURLs: [transcriptURL],
                                failureTitle: "Could not open transcript",
                                failureMessage: "Transcripted couldn't find this meeting's transcript on disk yet. If the recording is still finishing, try again in a moment."
                            )
                        }
                    }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if let notice = homeLocalSummaryNotice {
                SettingsActivityCard(
                    symbolName: notice.isFailure ? "exclamationmark.circle.fill" : "sparkles",
                    title: notice.title,
                    status: notice.status,
                    detail: notice.detail,
                    tone: notice.isFailure ? .caution : .success,
                    progress: nil,
                    actionTitle: notice.actionTitle,
                    action: {
                        if notice.isFailure {
                            trackSettingsAction("retry_local_meeting_summary_notice", page: .home)
                            clearHomeLocalSummaryNotice(id: notice.id)
                            generateLocalSummary(
                                transcriptURL: notice.transcriptURL,
                                title: notice.meetingTitle,
                                hasExistingSummary: false
                            )
                        } else {
                            trackSettingsAction("open_local_meeting_summary_notice", page: .home)
                            clearHomeLocalSummaryNotice(id: notice.id)
                            openOwnFile(
                                candidateURLs: [notice.transcriptURL],
                                failureTitle: "Could not open transcript",
                                failureMessage: "Transcripted couldn't find this meeting's transcript on disk. It may have been moved, renamed, or deleted outside the app."
                            )
                        }
                    },
                    dismissAction: notice.allowsManualDismiss
                        ? {
                            trackSettingsAction("dismiss_local_meeting_summary_notice", page: .home)
                            clearHomeLocalSummaryNotice(id: notice.id)
                        }
                        : nil
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if homeMeetingSearchIsAvailable {
                HomeMeetingSearchField(query: $homeMeetingSearchQuery)
                    .padding(.top, 6)
            }

            homeMeetingsListSection
                .padding(.top, homeMeetingSearchIsAvailable ? 0 : 6)
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

    @ViewBuilder
    private var homeFailedMeetingsCard: some View {
        let allFailedMeetings = meetingSession.failedMeetings
        if !allFailedMeetings.isEmpty {
            let failedMeetings = homeShowsAllFailedMeetings
                ? allFailedMeetings
                : Array(allFailedMeetings.prefix(3))
            HomeFailedMeetingsCard(
                items: failedMeetings,
                hiddenCount: max(0, allFailedMeetings.count - failedMeetings.count),
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
    }

    private var dictationsPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsPageIntro(
                title: "Dictations",
                summary: "Recent dictations saved to daily Markdown files."
            )

            homeDictationsListSection
        }
        .accessibilityIdentifier("transcripted.settings.page.dictations")
    }

    private var homeMeetingsListSection: some View {
        let isSearchingMeetings = !homeMeetingSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HomeCaptureListSection(
            sections: homeMeetingDaySections,
            emptyMessage: isSearchingMeetings ? HomeCaptureListCopy.noMeetingMatches : HomeCaptureListCopy.emptyMeetings,
            emptyState: isSearchingMeetings ? nil : HomeListEmptyState(
                symbolName: "waveform",
                title: "No meetings yet",
                message: "Record a meeting and Transcripted transcribes it, labels each speaker, and saves the transcript here. You can also transcribe an existing audio file from General.",
                actionTitle: "Start a meeting",
                automationIdentifier: "transcripted.home.meetings.empty.start",
                action: {
                    trackSettingsAction("empty_start_meeting", page: .home)
                    actions.startMeeting()
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
            HomeMeetingRow(
                item: meeting,
                isCopied: homeCopiedRowID == meeting.id,
                isSummarizingSummary: homeLocalSummaryJobIDs.contains(meeting.id),
                localMeetingSummariesEnabled: localMeetingSummariesEnabled,
                onOpen: { presentHomeMeetingPreview(meeting) },
                onCopy: { handleCopyMeeting(meeting) },
                onFlag: {
                    trackSettingsAction("flag_meeting", page: navigation.selectedPage)
                    homeFeedbackTarget = HomeFeedbackTarget.meeting(meeting)
                },
                menuItems: meetingRowMenuItems(for: meeting),
                showsMicBoostHint: RecentMeetingMicBoostHintPolicy.shouldOfferEnableAction(
                    audioHealth: meeting.audioHealth,
                    voiceProcessingPreferenceEnabled: meetingMicProcessingMode.usesAppleVoiceProcessing
                )
            )
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
                onClear: { requestClearFailedMeeting(failedMeeting) }
            )
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
                action: {
                    trackSettingsAction("empty_start_dictation", page: .dictations)
                    actions.startDictation()
                }
            ),
            isLoading: homeViewModel.isLoading,
            isLoadingMore: homeViewModel.isLoadingMore,
            canLoadMore: homeViewModel.canLoadMoreDictations,
            getID: { AnyHashable($0.id) },
            onLoadMore: {
                trackSettingsAction("load_more_dictations", page: navigation.selectedPage)
                homeViewModel.loadMoreDictations()
            }
        ) { entry in
            HomeDictationRow(
                entry: entry,
                isCopied: homeCopiedRowID == entry.id,
                onOpen: {
                    trackSettingsAction("open_recent_dictation", page: navigation.selectedPage)
                    ActivationTelemetry.trackArtifactAction(
                        artifactKind: .dictation,
                        actionKind: .openMarkdown,
                        surface: .homeRow,
                        artifactDate: entry.createdAt
                    )
                    openOwnFile(
                        candidateURLs: [entry.url],
                        failureTitle: "Could not open dictation",
                        failureMessage: "Transcripted couldn't find this dictation's file on disk. It may have been moved, renamed, or deleted outside the app."
                    )
                },
                onCopy: { handleCopyDictation(entry) },
                onFlag: {
                    trackSettingsAction("flag_dictation", page: navigation.selectedPage)
                    homeFeedbackTarget = HomeFeedbackTarget.dictation(entry)
                },
                menuItems: dictationRowMenuItems(for: entry)
            )
        }
    }

    private var homeGreeting: String {
        HomeCanvasGreeting.text(
            hour: Calendar.current.component(.hour, from: Date()),
            firstName: homeViewModel.welcomeName
        )
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

    private func reviewHomeAttentionIssue(_ issue: HomeAttentionIssue) {
        switch issue.destination {
        case .failedMeetings:
            trackSettingsAction("open_needs_attention_failed_meetings", page: .home)
            navigation.selectedPage = .home
            homeShowsAllFailedMeetings = true
        case .speakers:
            openHomeSpeakerReview(actionName: "open_needs_attention_speakers")
        case .summaries:
            trackSettingsAction("open_needs_attention_summaries", page: .home)
            navigation.selectedPage = .home
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
        ActivationTelemetry.trackAgentPromptAction(
            promptKind: .meetingBundle,
            actionKind: .copied,
            agentTarget: .localAgent,
            surface: .homeRow,
            artifactKind: .meeting
        )
        // Resolve the transcript first so a row whose path drifted (restyle/
        // rename after scanning) still copies, and a genuinely missing file
        // surfaces an error instead of silently no-op'ing on the empty clipboard.
        guard let transcriptURL = OwnFileResolver.resolveExistingFile(candidateURLs: [item.transcriptURL]) else {
            presentHomeActionFailure(
                title: "Could not copy meeting",
                message: "Transcripted couldn't find this meeting's transcript on disk. It may have been moved, renamed, or deleted outside the app."
            )
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let bundle = AgentConnectionGuide.portableMeetingBundle(
            title: item.title,
            date: item.date,
            transcriptURL: transcriptURL
        ) {
            pasteboard.setString(bundle, forType: .string)
        } else if let raw = try? String(contentsOf: transcriptURL, encoding: .utf8) {
            pasteboard.setString(raw, forType: .string)
        } else {
            presentHomeActionFailure(
                title: "Could not copy meeting",
                message: "Transcripted found this meeting's transcript but couldn't read it. The file may be open exclusively elsewhere or corrupted."
            )
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
            presentHomeActionFailure(
                title: "Could not re-transcribe meeting",
                message: "Transcripted couldn't find the retained audio for this meeting. It may have been recompressed or removed by the audio-retention setting."
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
                message: "Transcripted couldn't find this meeting's retained audio on disk. It may have been moved, recompressed, or removed by the audio-retention setting."
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
                    message: "Transcripted couldn't start re-transcription from the retained audio. The saved files may be incomplete or already in use."
                )
            }
        }
    }

    private func handleOpenOrGenerateLocalSummary(_ item: RecentMeetingItem) {
        guard localMeetingSummariesEnabled else { return }

        if item.summaryPreview != nil {
            trackSettingsAction("open_local_meeting_summary", page: .home)
            openOwnFile(
                candidateURLs: [item.transcriptURL],
                failureTitle: "Could not open transcript",
                failureMessage: "Transcripted couldn't find this meeting's enhanced transcript on disk. It may have been moved, renamed, or deleted outside the app."
            )
            return
        }

        generateLocalSummary(for: item)
    }

    private func generateLocalSummary(for item: RecentMeetingItem) {
        generateLocalSummary(
            transcriptURL: item.transcriptURL,
            title: item.title,
            hasExistingSummary: item.summaryPreview != nil
        )
    }

    private func generateLocalSummary(
        transcriptURL: URL,
        title: String,
        hasExistingSummary: Bool
    ) {
        guard localMeetingSummariesEnabled else { return }
        let summaryID = transcriptURL.path
        guard homeLocalSummaryTasks[summaryID] == nil else { return }
        if let unavailableReason = localMeetingSummaryUnavailableReason {
            trackLocalSummaryAbandoned(reason: .blocked, stage: "start", priorReadyState: "not_ready")
            homeDeleteFailure = HomeDeleteFailure(
                title: "Could not summarize meeting",
                message: unavailableReason
            )
            return
        }
        trackSettingsAction("generate_local_meeting_summary", page: .home)
        let provider = localMeetingSummaryProvider
        let summaryAction = hasExistingSummary ? "regenerate" : "generate"
        let summaryStartedAt = CFAbsoluteTimeGetCurrent()
        trackLocalSummaryAnalytics(
            event: "local_meeting_summary_started",
            properties: [
                "provider": provider.rawValue,
                "summary_action": summaryAction,
                "setup_ready": selectedLocalSummaryProviderIsReady ? "true" : "false",
                "runtime": selectedLocalSummaryProviderProfileName,
                "queue_depth_bucket": AnalyticsReporter.queueDepthBucket(homeLocalSummaryTasks.count),
            ]
        )
        recordLocalSummaryEvent(
            event: "local_meeting_summary_started",
            message: "\(provider.title) meeting summary started",
            context: [
                "provider": provider.rawValue,
                "has_existing_summary": hasExistingSummary ? "true" : "false",
                "setup_ready": selectedLocalSummaryProviderIsReady ? "true" : "false",
                "setup_profile": selectedLocalSummaryProviderProfileName,
            ]
        )
        clearHomeLocalSummaryNotice()
        homeLocalSummaryJobIDs.insert(summaryID)

        let task = Task.detached(priority: .utility) {
            switch provider {
            case .gemmaMLX:
                return try await LocalMeetingSummarizer().summarize(
                    transcriptURL: transcriptURL,
                    title: title
                )
            case .appleFoundation:
                return try await AppleFoundationMeetingSummarizer().summarize(
                    transcriptURL: transcriptURL,
                    title: title
                )
            }
        }
        let taskToken = UUID()
        homeLocalSummaryTasks[summaryID] = task
        homeLocalSummaryTaskTokens[summaryID] = taskToken

        Task { @MainActor in
            defer {
                if homeLocalSummaryTaskTokens[summaryID] == taskToken {
                    homeLocalSummaryJobIDs.remove(summaryID)
                    homeLocalSummaryTasks[summaryID] = nil
                    homeLocalSummaryTaskTokens[summaryID] = nil
                }
            }

            do {
                let result = try await task.value
                guard localMeetingSummariesEnabled else { return }
                presentHomeLocalSummaryNotice(HomeLocalSummaryNotice(
                    transcriptURL: result.transcriptURL,
                    meetingTitle: title,
                    chunkCount: result.chunkCount
                ))
                recordLocalSummaryEvent(
                    event: "local_meeting_summary_completed",
                    message: "\(result.provider.title) meeting summary saved",
                    context: [
                        "provider": result.provider.rawValue,
                        "chunk_count": "\(result.chunkCount)",
                        "profile": result.profileName,
                    ]
                )
                trackLocalSummaryAnalytics(
                    event: "local_meeting_summary_completed",
                    properties: [
                        "provider": result.provider.rawValue,
                        "summary_action": summaryAction,
                        "chunk_count_bucket": AnalyticsReporter.countBucket(result.chunkCount),
                        "runtime": result.profileName,
                        "duration_bucket": localSummaryRunDurationBucket(since: summaryStartedAt),
                    ]
                )
                refreshRecentCapturesAfterLocalSummary()
            } catch is CancellationError {
                if homeLocalSummaryTaskTokens[summaryID] == taskToken {
                    trackLocalSummaryAbandoned(reason: .cancelled, stage: "generate", priorReadyState: "running")
                }
                recordLocalSummaryEvent(
                    event: "local_meeting_summary_cancelled",
                    message: "\(provider.title) meeting summary cancelled",
                    context: [
                        "provider": provider.rawValue,
                    ]
                )
                return
            } catch {
                guard localMeetingSummariesEnabled else { return }
                let failureKind = localSummaryFailureKind(error)
                trackLocalSummaryAbandoned(reason: .failed, stage: "generate", priorReadyState: "ready")
                recordLocalSummaryEvent(
                    level: .error,
                    event: "local_meeting_summary_failed",
                    message: "\(provider.title) meeting summary failed",
                    context: [
                        "provider": provider.rawValue,
                        "failure_kind": failureKind,
                    ]
                )
                trackLocalSummaryAnalytics(
                    event: "local_meeting_summary_failed",
                    properties: [
                        "provider": provider.rawValue,
                        "summary_action": summaryAction,
                        "failure_kind": failureKind,
                        "stage": "generate",
                        "duration_bucket": localSummaryRunDurationBucket(since: summaryStartedAt),
                    ]
                )
                NSSound.beep()
                presentHomeLocalSummaryNotice(
                    HomeLocalSummaryNotice(
                        transcriptURL: transcriptURL,
                        meetingTitle: title,
                        failureMessage: error.localizedDescription
                    )
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
                homeMeetingPreview = HomeMeetingPreview(
                    item: item,
                    markdown: markdown,
                    summary: HomeMeetingSummaryBetaPresentationPolicy.visibleSummaryPreview(
                        for: item,
                        isEnabled: localMeetingSummariesEnabled
                    )
                )
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
                openOwnFile(
                    candidateURLs: [entry.url],
                    failureTitle: "Could not open dictation",
                    failureMessage: "Transcripted couldn't find this dictation's file on disk. It may have been moved, renamed, or deleted outside the app."
                )
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
                revealOwnFile(
                    candidateURLs: [entry.url],
                    failureTitle: "Could not show dictation",
                    failureMessage: "Transcripted couldn't find this dictation's file on disk. It may have been moved, renamed, or deleted outside the app."
                )
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
        let isPreparingLocalSummaryModel = isLocalSummaryModelPreparing
        let canGenerateSummary = localMeetingSummaryUnavailableReason == nil
        let hasPendingSpeakerReview = hasSpeakerReviewWork(for: item)
        let summaryActionTitle: String
        if isSummarizing {
            summaryActionTitle = "Running AI summary..."
        } else if hasSummary {
            summaryActionTitle = "Open enhanced transcript"
        } else if isPreparingLocalSummaryModel {
            summaryActionTitle = "Preparing \(localMeetingSummaryProvider.title)..."
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
                revealOwnFile(
                    candidateURLs: HomeMeetingRowActionTargets.transcriptRevealURLs(for: item),
                    failureTitle: "Could not show transcript",
                    failureMessage: "Transcripted couldn't find this meeting's transcript on disk. It may have been moved, renamed, or deleted outside the app."
                )
            }
        ])

        if HomeMeetingSummaryBetaPresentationPolicy.shouldShowSummaryMenuActions(isEnabled: localMeetingSummariesEnabled),
           hasSummary {
            items.append(
                HomeRowMenuItem(
                    title: isSummarizing
                        ? "Regenerating AI summary..."
                        : (isPreparingLocalSummaryModel ? "Preparing \(localMeetingSummaryProvider.title)..." : "Regenerate AI summary"),
                    symbolName: "arrow.clockwise",
                    isEnabled: !isSummarizing && canGenerateSummary
                ) {
                    generateLocalSummary(for: item)
                }
            )
        }

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
                            failureMessage: "Transcripted couldn't find this meeting's retained audio on disk. It may have been moved, recompressed, or removed by the audio-retention setting."
                        )
                    }
                )
            }
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

    // MARK: - Home root alert

    /// The Home surface drives three independent confirmation/failure alerts
    /// (`homeDeleteConfirmation`, `homeDeleteFailure`, `pendingAudioRetentionWindow`).
    /// They are presented through a *single* `.alert(item:)` because SwiftUI
    /// shadows all but the last when several legacy `.alert(item:)` are stacked
    /// on one view — that is what silently broke the meeting-delete confirmation.
    private enum RootAlert: Identifiable {
        case deleteConfirmation(HomeDeleteConfirmation)
        case deleteFailure(HomeDeleteFailure)
        case audioRetention(AudioRetentionWindow)

        var id: String {
            switch self {
            case .deleteConfirmation(let confirmation): return "delete-confirmation-\(confirmation.id)"
            case .deleteFailure(let failure): return "delete-failure-\(failure.id)"
            case .audioRetention(let window): return "audio-retention-\(window.id)"
            }
        }
    }

    /// Snapshot of which Home alert states are currently set, fed to
    /// `HomeRootAlertPolicy` so presentation priority and dismissal stay in sync.
    private var rootAlertStates: HomeRootAlertStates {
        HomeRootAlertStates(
            hasDeleteConfirmation: homeDeleteConfirmation != nil,
            hasDeleteFailure: homeDeleteFailure != nil,
            hasAudioRetention: pendingAudioRetentionWindow != nil
        )
    }

    /// Whichever Home alert should present, in `HomeRootAlertPolicy` priority order.
    private var activeRootAlert: RootAlert? {
        switch HomeRootAlertPolicy.activeSlot(rootAlertStates) {
        case .deleteConfirmation: return homeDeleteConfirmation.map(RootAlert.deleteConfirmation)
        case .deleteFailure: return homeDeleteFailure.map(RootAlert.deleteFailure)
        case .audioRetention: return pendingAudioRetentionWindow.map(RootAlert.audioRetention)
        case .none: return nil
        }
    }

    /// Binds the single alert presenter to the three underlying states. On
    /// dismissal it clears only the alert being dismissed, not all three: a
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
                case .audioRetention: pendingAudioRetentionWindow = nil
                case .none: break
                }
            }
        )
    }

    private func deleteMeeting(_ item: RecentMeetingItem) {
        if homeMeetingPreview?.transcriptURL == item.transcriptURL {
            homeMeetingPreview = nil
        }
        homeViewModel.removeVisibleMeeting(id: item.id)

        let deletionTask = Task.detached(priority: .userInitiated) {
            let plan = HomeMeetingDeletion.plan(for: item)
            await MainActor.run {
                MeetingAudioPlayback.shared.stopIfActive(attachmentIDs: Set(plan.audioAttachmentIDs))
            }
            return try HomeMeetingDeletion.delete(plan)
        }

        Task { @MainActor in
            do {
                let result = try await deletionTask.value
                refreshRecentCaptures(force: true)
                // The delete can succeed yet remove nothing when the row's
                // recorded path went stale (a restyle/rename moved the file
                // after the dashboard was scanned). Deletion deliberately does
                // NOT route through OwnFileResolver — stem-rematch / enclosing-
                // folder fallback could remove the wrong file. Instead, detect
                // the no-op and surface it so the row does not silently reappear
                // on refresh with no explanation.
                if result.removedTranscriptURLs.isEmpty,
                   FileManager.default.fileExists(atPath: item.transcriptURL.path) {
                    presentHomeActionFailure(
                        title: "Could not delete meeting",
                        message: "Transcripted couldn't remove this meeting's files. They may have been moved or renamed outside the app — reopen Settings and try again."
                    )
                }
            } catch {
                refreshRecentCaptures(force: true)
                presentHomeDeleteFailure(
                    title: "Could not delete meeting",
                    error: error
                )
            }
        }
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
                if homeMeetingPreview?.id == preview.id {
                    homeMeetingPreview = preview.updatingAfterRename(
                        transcriptURL: result.transcriptURL,
                        title: result.title,
                        audio: audio
                    )
                }
                refreshRecentCaptures(force: true)
            } catch HomeMeetingRenameError.emptyTitle {
                // Empty title is treated as a cancelled edit — leave everything untouched.
            } catch {
                refreshRecentCaptures(force: true)
                presentHomeDeleteFailure(
                    title: "Could not rename meeting",
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
        revealOwnFile(
            candidateURLs: HomeMeetingRowActionTargets.audioRevealURLs(audioURLs: item.audioURLs),
            failureTitle: "Could not show audio",
            failureMessage: "Transcripted couldn't find this meeting's retained audio on disk. It may have been moved, recompressed, or already cleared."
        )
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
                message: "Transcripted couldn't remove this meeting. Check that your capture folder is available, then try again."
            )
        } else {
            ActivationTelemetry.trackWorkflowAbandoned(
                workflowKind: .failedMeetingRetry,
                stage: "retry_available",
                reasonKind: item.audioURLs.isEmpty ? .dismissed : .deleted,
                surface: .home,
                priorReadyState: canRetryFailedMeetings ? "retry_ready" : "retry_blocked"
            )
        }
    }

    /// Reveals an app-owned capture artifact in Finder, tolerant to the file
    /// having moved since the row was scanned (transcript restyle/rename,
    /// WAV→M4A audio recompression). Never silently no-ops: if nothing on disk
    /// can be revealed it surfaces a failure alert instead of a dead click.
    private func revealOwnFile(
        candidateURLs: [URL],
        failureTitle: String,
        failureMessage: String
    ) {
        switch OwnFileResolver.resolveForReveal(candidateURLs: candidateURLs) {
        case .reveal(let urls):
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        case .unavailable:
            presentHomeActionFailure(title: failureTitle, message: failureMessage)
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
            presentHomeActionFailure(title: failureTitle, message: failureMessage)
            return false
        }
        NSWorkspace.shared.open(url)
        return true
    }

    private func presentHomeDeleteFailure(title: String, error: Error) {
        presentHomeActionFailure(title: title, message: error.localizedDescription)
    }

    private func presentHomeActionFailure(title: String, message: String) {
        NSSound.beep()
        // Defer to the next runloop turn so a failure raised synchronously inside
        // an alert's confirm action lands after that alert finishes dismissing.
        // SwiftUI won't present a second alert during the first one's dismissal,
        // and the shared binding clears the dismissed alert on the same turn.
        DispatchQueue.main.async {
            homeDeleteFailure = HomeDeleteFailure(title: title, message: message)
        }
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

    private var homeStatItems: [HomeStatItem] {
        [
            HomeStatItem(
                id: "dictations",
                symbolName: "text.bubble.fill",
                value: formattedInteger(homeViewModel.totalDictationCount),
                label: homeViewModel.totalDictationCount == 1 ? "dictation" : "dictations",
                detail: "Spoken notes saved to your daily Markdown files"
            ),
            HomeStatItem(
                id: "dictation-words",
                symbolName: "text.alignleft",
                value: formattedInteger(homeViewModel.totalDictationWordCount),
                label: "words dictated",
                detail: "Words you spoke instead of typed"
            ),
            HomeStatItem(
                id: "typing-time-saved",
                symbolName: "keyboard",
                value: formattedTypingTimeSaved(forDictatedWords: homeViewModel.totalDictationWordCount),
                label: "typing time saved",
                detail: "Estimated from your dictated words at a 40 words-per-minute typing pace"
            ),
            HomeStatItem(
                id: "meetings",
                symbolName: "person.2.wave.2.fill",
                value: formattedInteger(statsService.totalRecordings),
                label: statsService.totalRecordings == 1 ? "meeting" : "meetings",
                detail: "Transcribed and saved on this Mac"
            ),
            HomeStatItem(
                id: "meeting-hours",
                symbolName: "clock.fill",
                value: statsService.formattedTotalHours,
                label: "meeting hours recorded",
                detail: "Total length of everything you've captured"
            ),
            HomeStatItem(
                id: "meetings-30d",
                symbolName: "calendar",
                value: formattedInteger(statsService.last30DaysRecordings),
                label: "meetings, last 30 days",
                detail: "Your recent capture momentum"
            )
        ]
    }

    private func formattedInteger(_ value: Int) -> String {
        Self.homeIntegerFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func formattedTypingTimeSaved(forDictatedWords wordCount: Int) -> String {
        TypingTimeSavedFormatter.format(dictatedWords: wordCount)
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

        if !homeLocalSummaryJobIDs.isEmpty {
            let count = homeLocalSummaryJobIDs.count
            issues.append(
                HomeAttentionIssue(
                    id: "summaries",
                    title: count == 1 ? "1 summary running" : "\(count) summaries running",
                    detail: "Local AI summaries are still being written.",
                    tone: .progress,
                    destination: .summaries
                )
            )
        }

        let modelCard = FirstRunExperience.modelCard(
            for: FirstRunLocalModelState(sttRouter.modelDownloadState),
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
    /// metadata (title, generated title, summary, date) so filtering never
    /// touches transcript bodies on disk.
    private static func searchFields(for meeting: RecentMeetingItem) -> [String] {
        var fields = [meeting.displayTitle, meeting.title]
        if let summary = meeting.summaryPreview {
            fields.append(summary.summary)
            fields.append(contentsOf: summary.sections.flatMap { [$0.title, $0.text] })
        }
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

    private var modelCacheBusyHelp: String {
        modelCacheCleanupInProgress
            ? "A cache cleanup is already running."
            : "Wait for the storage scan to finish."
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
        if let busyReason = LocalMeetingSummaryAvailabilityPolicy.unavailableReason(
            isDictationActive: sttRouter.isRecording || sttRouter.isTranscribing,
            isMeetingRecording: meetingSession.isRecording,
            isPreparingModels: meetingSession.state == .loadingModels,
            isPreparingLocalSummaryModel: isLocalSummaryModelPreparing,
            hasMeetingWork: meetingSession.hasRuntimeDiagnosticsWork,
            isSpeakerReviewPending: meetingSession.isSpeakerReviewPending
        ) {
            return busyReason
        }

        switch localMeetingSummaryProvider {
        case .gemmaMLX:
            if !localSummarySetupStatus.hasEnoughMemory {
                return "This Mac reports \(localSummarySetupStatus.physicalMemoryGB) GB memory. Gemma summaries need at least \(localSummarySetupStatus.minimumMemoryGB) GB."
            }
            if !localSummarySetupStatus.hasRuntime {
                return "Install uv from Beta settings before running Gemma summaries."
            }
        case .appleFoundation:
            if !appleSummarySetupStatus.isReady {
                return appleSummarySetupStatus.unavailableReason
                    ?? "Apple on-device summaries are unavailable on this Mac right now."
            }
        }

        return nil
    }

    private var shortcutsPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsPageIntro(
                title: "Shortcuts",
                summary: "Keyboard triggers and send-after-paste rules."
            )

            SettingsSection(
                title: "Keys",
                detail: "Set push-to-talk, hands-free, paste-last-dictation, and meeting shortcuts."
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

                GeneralToggleRow(
                    title: "Auto-detect calls",
                    isOn: Binding(
                        get: { autoDetectCallsEnabled },
                        set: { newValue in
                            autoDetectCallsEnabled = newValue
                            trackSettingsToggle("auto_call_detection", enabled: newValue, page: .general)
                            AutoCallDetectionPreferences.setEnabled(newValue)
                        }
                    ),
                    help: autoDetectCallsEnabled
                        ? "Offer to record when a call starts, even without a calendar invite."
                        : "Only detect meetings from your calendar and conferencing apps.",
                    info: GeneralInfo(
                        title: "Auto-detect calls",
                        message: "When this is on, Transcripted notices when an app or browser starts using your microphone, or when your camera turns on while a call app is active, and offers to record it. It only checks local device activity on your Mac; nothing about the audio or video ever leaves your device."
                    ),
                    automationIdentifier: "transcripted.settings.general.auto-detect-calls"
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

                VStack(alignment: .leading, spacing: 6) {
                    Picker("Meeting mic processing", selection: Binding(
                        get: { meetingMicProcessingMode },
                        set: { newValue in
                            meetingMicProcessingMode = newValue
                            trackSettingsToggle("meeting_mic_processing_\(newValue.rawValue)", enabled: true, page: .general)
                            MicrophoneProcessingPreferences.setMode(newValue)
                        }
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
                    isOn: Binding(
                        get: { splitLocalSpeakersEnabled },
                        set: { newValue in
                            splitLocalSpeakersEnabled = newValue
                            trackSettingsToggle("local_speaker_split", enabled: newValue, page: .general)
                            LocalSpeakerPreferences.setEnabled(newValue)
                        }
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
            }
        }
        .accessibilityIdentifier("transcripted.settings.page.general")
    }

    private var peoplePage: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsPageIntro(
                title: "Speakers",
                summary: "Name new voices and manage the people in your meetings."
            )

            SpeakerPeopleSettingsSection(model: speakerPeopleModel)
        }
        .accessibilityIdentifier("transcripted.settings.page.people")
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
                        .help(modelCacheCleanupInProgress || modelCacheLoading ? modelCacheBusyHelp : "")
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
                        .help(effectiveTranscriptionModel.isWhisper
                            ? "Switch back to Parakeet before removing the Whisper cache."
                            : (modelCacheCleanupInProgress || modelCacheLoading ? modelCacheBusyHelp : ""))

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
                        .help(modelCacheCleanupInProgress || modelCacheLoading ? modelCacheBusyHelp : "")
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
                .help(modelCacheLoading ? "Storage sizes are being scanned." : "")
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
                    .keyboardShortcut(.defaultAction)
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
                    .keyboardShortcut(.defaultAction)
            } message: {
                Text("Transcripted will remove only known old Parakeet folders: \(modelCacheSnapshot?.staleModelSummary ?? "none"). Active Parakeet CoreML and Whisper caches stay.")
            }
            .alert("Remove Whisper cache?", isPresented: $showWhisperCacheCleanupConfirmation) {
                Button("Remove", role: .destructive) {
                    removeWhisperModelCache()
                }
                Button("Cancel", role: .cancel) {}
                    .keyboardShortcut(.defaultAction)
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
        .accessibilityIdentifier("transcripted.settings.page.storage")
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

                    Picker("Summary provider", selection: Binding(
                        get: { localMeetingSummaryProvider },
                        set: { provider in
                            localMeetingSummaryProviderRawValue = provider.rawValue
                            LocalMeetingSummaryPreferences.setProvider(provider)
                            trackSettingsToggle("local_ai_meeting_summary_provider_\(provider.rawValue)", enabled: true, page: .beta)
                            refreshLocalSummarySetupStatus()
                            if localMeetingSummariesEnabled {
                                cancelLocalSummaryJobs()
                                clearHomeLocalSummaryNotice()
                                cancelLocalSummaryModelPreparation()
                                localSummaryModelPreparationStatus = nil
                                prepareLocalSummaryModelFromBeta()
                            }
                        }
                    )) {
                        ForEach(LocalMeetingSummaryProvider.allCases, id: \.self) { provider in
                            Text(provider.title).tag(provider)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(isLocalSummaryModelPreparing)
                    .help(isLocalSummaryModelPreparing
                        ? "Finish or cancel the current model setup before switching providers."
                        : "")

                    Text(localMeetingSummaryProvider.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

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
        .accessibilityIdentifier("transcripted.settings.page.beta")
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

                if localMeetingSummariesEnabled, selectedLocalSummaryProviderIsReady {
                    SettingsInlineActionButton(
                        title: isLocalSummaryModelPreparing ? "Cancel setup" : localSummaryPrepareButtonTitle,
                        symbolName: isLocalSummaryModelPreparing ? "xmark.circle" : "tray.and.arrow.down",
                        tone: isLocalSummaryModelPreparing ? .warning : .neutral,
                        automationIdentifier: "transcripted.settings.beta.local-summary.prepare-model"
                    ) {
                        if isLocalSummaryModelPreparing {
                            trackSettingsAction("cancel_local_summary_model_prepare", page: .beta)
                            cancelLocalSummaryModelPreparation()
                            localSummaryModelPreparationStatus = "\(localMeetingSummaryProvider.title) setup cancelled. You can try again when this Mac is idle."
                        } else {
                            trackSettingsAction("prepare_local_summary_model", page: .beta)
                            prepareLocalSummaryModelFromBeta()
                        }
                    }
                }
            }

            if localMeetingSummaryProvider == .gemmaMLX, !localSummarySetupStatus.hasRuntime {
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
                        title: "Provider",
                        value: localMeetingSummaryProvider.title
                    )
                    ForEach(localSummarySetupDetails, id: \.title) { detail in
                        betaSetupDetailLine(title: detail.title, value: detail.value)
                    }
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

        let provider = localMeetingSummaryProvider
        switch provider {
        case .gemmaMLX:
            guard localSummarySetupStatus.hasEnoughMemory else {
                trackBetaModelPrepAbandoned(reason: .unavailable, stage: "memory_check")
                localSummaryModelPreparationStatus = "Gemma needs more memory than this Mac reports."
                return
            }

            guard localSummarySetupStatus.hasRuntime else {
                trackBetaModelPrepAbandoned(reason: .unavailable, stage: "runtime_check")
                localSummaryModelPreparationStatus = "Install uv first, then Transcripted can download Gemma here."
                return
            }
        case .appleFoundation:
            guard appleSummarySetupStatus.isReady else {
                trackBetaModelPrepAbandoned(reason: .unavailable, stage: "system_check")
                localSummaryModelPreparationStatus = appleSummarySetupStatus.unavailableReason
                    ?? "Apple on-device summaries are unavailable on this Mac right now."
                return
            }
        }

        isLocalSummaryModelPreparing = true
        localSummaryModelPreparationStatus = localSummaryPreparationStartedStatus
        recordLocalSummaryEvent(
            event: "local_meeting_summary_model_prepare_started",
            message: "\(provider.title) summary model preparation started",
            context: [
                "provider": provider.rawValue,
                "setup_profile": selectedLocalSummaryProviderProfileName,
            ]
        )

        let taskToken = UUID()
        let task = Task.detached(priority: .utility) {
            switch provider {
            case .gemmaMLX:
                return try await LocalMeetingSummarizer().prepareModelForFirstSummary()
            case .appleFoundation:
                return try await AppleFoundationMeetingSummarizer().prepareModelForFirstSummary()
            }
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
                refreshLocalSummarySetupStatus()
                localSummaryModelPreparationStatus = "\(provider.title) is ready. The first real summary should start without a surprise setup step."
                recordLocalSummaryEvent(
                    event: "local_meeting_summary_model_prepare_completed",
                    message: "\(provider.title) summary model preparation completed",
                    context: [
                        "provider": provider.rawValue,
                        "profile": profile,
                    ]
                )
            } catch is CancellationError {
                guard localSummaryModelPreparationToken == taskToken else { return }
                isLocalSummaryModelPreparing = false
                localSummaryModelPreparationTask = nil
                localSummaryModelPreparationToken = nil
                localSummaryModelPreparationStatus = nil
                trackBetaModelPrepAbandoned(reason: .cancelled, stage: "prepare_model")
                recordLocalSummaryEvent(
                    event: "local_meeting_summary_model_prepare_cancelled",
                    message: "\(provider.title) summary model preparation cancelled",
                    context: [
                        "provider": provider.rawValue,
                    ]
                )
            } catch {
                guard localSummaryModelPreparationToken == taskToken else { return }
                isLocalSummaryModelPreparing = false
                localSummaryModelPreparationTask = nil
                localSummaryModelPreparationToken = nil
                refreshLocalSummarySetupStatus()
                localSummaryModelPreparationStatus = "\(provider.title) setup failed: \(error.localizedDescription)"
                trackBetaModelPrepAbandoned(reason: .failed, stage: "prepare_model")
                recordLocalSummaryEvent(
                    level: .error,
                    event: "local_meeting_summary_model_prepare_failed",
                    message: "\(provider.title) summary model preparation failed",
                    context: [
                        "provider": provider.rawValue,
                        "error": error.localizedDescription,
                    ]
                )
            }
        }
    }

    private func cancelLocalSummaryModelPreparation() {
        if localSummaryModelPreparationTask != nil {
            trackBetaModelPrepAbandoned(reason: .cancelled, stage: "prepare_model")
        }
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
        appleSummarySetupStatus = AppleFoundationSummarySetupStatus.current()
    }

    private func cancelLocalSummaryJobs() {
        if !homeLocalSummaryTasks.isEmpty {
            trackLocalSummaryAbandoned(reason: .cancelled, stage: "generate", priorReadyState: "running")
        }
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
        guard notice.shouldAutoDismiss else {
            homeLocalSummaryNoticeDismissTask = nil
            return
        }
        homeLocalSummaryNoticeDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: HomeLocalSummaryNoticeDismissalPolicy.autoDismissDelayNanoseconds)
            guard !Task.isCancelled,
                  HomeLocalSummaryNoticeDismissalPolicy.shouldDismiss(
                    current: homeLocalSummaryNotice,
                    scheduledNoticeID: notice.id
                  ) else { return }
            homeLocalSummaryNotice = HomeLocalSummaryNoticeDismissalPolicy.noticeAfterAutoDismiss(
                current: homeLocalSummaryNotice,
                scheduledNoticeID: notice.id
            )
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

    private func trackLocalSummaryAnalytics(event: String, properties: [String: String]) {
        AnalyticsReporter.track(event, properties: properties)
    }

    private func localSummaryRunDurationBucket(since start: CFAbsoluteTime) -> String {
        AnalyticsReporter.durationBucket(seconds: max(0, CFAbsoluteTimeGetCurrent() - start))
    }

    private func localSummaryFailureKind(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        guard let summaryError = error as? LocalMeetingSummaryError else {
            return "other"
        }

        switch summaryError {
        case .emptyTranscript:
            return "empty_transcript"
        case .insufficientMemory:
            return "insufficient_memory"
        case .runtimeUnavailable:
            return "runtime_unavailable"
        case .appleFoundationUnavailable:
            return "apple_foundation_unavailable"
        case .missingBundledRunner:
            return "missing_runner"
        case .transcriptChanged:
            return "transcript_changed"
        case .processTimedOut:
            return "timeout"
        case .processFailed:
            return "process_failed"
        case .outputMissing:
            return "output_missing"
        }
    }

    private func trackLocalSummaryAbandoned(
        reason: ActivationTelemetry.WorkflowAbandonmentReasonKind,
        stage: String,
        priorReadyState: String
    ) {
        ActivationTelemetry.trackWorkflowAbandoned(
            workflowKind: .localSummary,
            stage: stage,
            reasonKind: reason,
            surface: .home,
            priorReadyState: priorReadyState
        )
    }

    private func trackBetaModelPrepAbandoned(
        reason: ActivationTelemetry.WorkflowAbandonmentReasonKind,
        stage: String
    ) {
        ActivationTelemetry.trackWorkflowAbandoned(
            workflowKind: .betaModelPrep,
            stage: stage,
            reasonKind: reason,
            surface: .home,
            priorReadyState: selectedLocalSummaryProviderIsReady ? "ready" : "not_ready"
        )
    }

    private func openUVInstallGuide() {
        guard let url = URL(string: "https://docs.astral.sh/uv/getting-started/installation/") else { return }
        NSWorkspace.shared.open(url)
    }

    private var localMeetingSummaryProvider: LocalMeetingSummaryProvider {
        LocalMeetingSummaryProvider(rawValue: localMeetingSummaryProviderRawValue)
            ?? LocalMeetingSummaryProvider.defaultProvider
    }

    private var selectedLocalSummaryProviderIsReady: Bool {
        switch localMeetingSummaryProvider {
        case .gemmaMLX:
            return localSummarySetupStatus.isReady
        case .appleFoundation:
            return appleSummarySetupStatus.isReady
        }
    }

    private var selectedLocalSummaryProviderProfileName: String {
        switch localMeetingSummaryProvider {
        case .gemmaMLX:
            return localSummarySetupStatus.profileName
        case .appleFoundation:
            return appleSummarySetupStatus.profileName
        }
    }

    private var localSummaryPrepareButtonTitle: String {
        switch localMeetingSummaryProvider {
        case .gemmaMLX:
            return "Prepare Gemma"
        case .appleFoundation:
            return "Check Apple model"
        }
    }

    private var localSummaryPreparationStartedStatus: String {
        switch localMeetingSummaryProvider {
        case .gemmaMLX:
            return "Preparing Gemma 4 12B locally. Transcripted is warming the local runner and may download several GB from Hugging Face; detailed download progress is not available yet."
        case .appleFoundation:
            return "Checking Apple's on-device Foundation Model locally. Transcripted will use the best Apple model this Mac exposes, including Core Advanced when available."
        }
    }

    private var localSummarySetupDetails: [(title: String, value: String)] {
        switch localMeetingSummaryProvider {
        case .gemmaMLX:
            return [
                ("Model", "Gemma 4 12B 4-bit MLX"),
                ("Download", "First summary may download several GB into your local Hugging Face cache."),
                ("Runtime", localSummarySetupStatus.hasRuntime
                    ? "uv found at \(localSummarySetupStatus.uvPath ?? "")"
                    : "Install uv so Transcripted can run the local MLX package."),
                ("Hardware", "Recommended: Apple Silicon with 16 GB memory. 8 GB Macs are not supported yet."),
                ("Privacy", "Transcript text stays on this Mac. The model download comes from Hugging Face if it is not cached.")
            ]
        case .appleFoundation:
            return [
                ("Model", "Apple Foundation Models system model"),
                ("Context", appleSummarySetupStatus.contextSize > 0
                    ? "\(appleSummarySetupStatus.contextSize) tokens reported by this Mac."
                    : "Context size unavailable."),
                ("Runtime", appleSummarySetupStatus.isReady
                    ? "Apple Intelligence model is available."
                    : (appleSummarySetupStatus.unavailableReason ?? "Apple model unavailable.")),
                ("Hardware", "Uses the best Apple on-device model this Mac exposes. Core Advanced is used only when the system provides it."),
                ("Privacy", "Transcript text stays on this Mac and uses Apple's local model path.")
            ]
        }
    }

    private var localSummarySetupStatusTitle: String {
        if isLocalSummaryModelPreparing {
            return "Preparing \(localMeetingSummaryProvider.title)"
        }

        switch localMeetingSummaryProvider {
        case .gemmaMLX:
            if !localSummarySetupStatus.hasEnoughMemory {
                return "Not supported on this Mac"
            }
            if !localSummarySetupStatus.hasRuntime {
                return "Setup needed"
            }
        case .appleFoundation:
            if !appleSummarySetupStatus.isFrameworkAvailable {
                return "Framework unavailable"
            }
            if !appleSummarySetupStatus.isModelAvailable {
                return "Apple model unavailable"
            }
        }
        return "Runtime ready"
    }

    private var localSummarySetupStatusDetail: String {
        if isLocalSummaryModelPreparing {
            return "Transcripted is preparing \(localMeetingSummaryProvider.title). Home summaries stay paused so this Mac only runs one local summary job at a time."
        }

        switch localMeetingSummaryProvider {
        case .gemmaMLX:
            if !localSummarySetupStatus.hasEnoughMemory {
                return "This Mac reports \(localSummarySetupStatus.physicalMemoryGB) GB memory. Local Gemma summaries need at least \(localSummarySetupStatus.minimumMemoryGB) GB to avoid heavy swapping."
            }
            if !localSummarySetupStatus.hasRuntime {
                return "Install uv first. The first summary may download a large local Gemma model, then future summaries reuse the local cache."
            }
            return "uv is installed. Use Prepare Gemma to download or warm the local model before running a meeting summary."
        case .appleFoundation:
            if !appleSummarySetupStatus.isReady {
                return appleSummarySetupStatus.unavailableReason ?? "Apple on-device summaries are unavailable on this Mac right now."
            }
            return "Apple's on-device model is available with a \(appleSummarySetupStatus.contextSize)-token context. Transcripted will chunk long meetings before merging."
        }
    }

    private var localSummarySetupStatusSymbol: String {
        if isLocalSummaryModelPreparing {
            return "arrow.triangle.2.circlepath"
        }
        if selectedLocalSummaryProviderIsReady {
            return "checkmark.circle.fill"
        }
        return "exclamationmark.circle.fill"
    }

    private var localSummarySetupStatusColor: Color {
        if isLocalSummaryModelPreparing {
            return Color.accentColor
        }
        if selectedLocalSummaryProviderIsReady {
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
                VStack(alignment: .leading, spacing: 6) {
                    Picker("Meeting mic processing", selection: Binding(
                        get: { meetingMicProcessingMode },
                        set: { newValue in
                            meetingMicProcessingMode = newValue
                            trackSettingsToggle("meeting_mic_processing_\(newValue.rawValue)", enabled: true, page: .privacy)
                            MicrophoneProcessingPreferences.setMode(newValue)
                        }
                    )) {
                        ForEach(MicrophoneProcessingMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("transcripted.settings.privacy.meeting-mic-processing")

                    Text(meetingMicProcessingMode.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

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

                Text("Changes here apply from the next recording.")
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
                        guard aboutUpdateButtonEnabled else { return }
                        trackSettingsAction(settingsUpdateActionID, page: .about)
                        sparkleUpdater.performUserUpdateAction(surface: "settings_about")
                    }
                    .disabled(!aboutUpdateButtonEnabled)
                }
            }
        }
        .accessibilityIdentifier("transcripted.settings.page.about")
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
        .accessibilityIdentifier("transcripted.settings.page.support")
    }

    private var settingsFooterShowsUpdateBadge: Bool {
        sparkleUpdater.updateStatus.readyToInstallVersion != nil
    }

    private var settingsFooterActionEnabled: Bool {
        updateActionEnabled(for: sparkleUpdater.updateStatus)
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
        if let captureHelp = updateCaptureSafetyHelp(for: sparkleUpdater.updateStatus) {
            return captureHelp
        }
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
        Task { @MainActor in
            await statsService.refreshStats()
        }
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
            return .betaSummaries
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
        guard TranscriptedStoragePreferences.setCaptureLibraryURL(url) else {
            refreshStoragePaths()
            showCaptureLibrarySelectionError()
            return
        }
        refreshStoragePaths()
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
        updateActionEnabled(for: sparkleUpdater.updateStatus)
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
