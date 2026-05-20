import AppKit
import Observation
import SwiftUI
import TranscriptedCore
import UniformTypeIdentifiers

private struct SettingsSidebarSection: Identifiable {
    let id: String
    let title: String?
    let pages: [TranscriptedSettingsPage]

    static let defaultSections = [
        SettingsSidebarSection(id: "home", title: nil, pages: [.home]),
        SettingsSidebarSection(id: "setup", title: "Setup", pages: [.general, .storage, .connectAgent]),
        SettingsSidebarSection(id: "trust", title: "Trust", pages: [.support, .about])
    ]
}

private struct SettingsSidebarRow: View {
    let page: TranscriptedSettingsPage
    let isSelected: Bool

    @State private var isHovering = false

    var body: some View {
        Label(page.title, systemImage: page.systemImage)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .padding(.horizontal, 9)
            .contentShape(Rectangle())
            .settingsHoverGlow(
                isActive: isHovering && !isSelected,
                cornerRadius: 8,
                fill: Color.primary.opacity(0.032),
                stroke: Color.accentColor.opacity(0.14),
                shadow: Color.accentColor.opacity(0.08),
                shadowRadius: 7
            )
            .onHover { isHovering = $0 }
    }
}

private struct GeneralSettingsHeader: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.primary)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(0.14))
                )

            Text("General")
                .font(.system(size: 24, weight: .semibold))
        }
    }
}

private struct GeneralSettingsGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .frame(maxWidth: 680, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.88))
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.11), lineWidth: 1)
        )
    }
}

private struct GeneralInfo {
    let title: String
    let message: String
}

private struct GeneralInfoButton: View {
    let info: GeneralInfo

    @State private var isPresented = false
    @State private var isHovering = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isHovering ? Color.primary : Color.secondary)
                .frame(width: 18, height: 18)
                .background(
                    Circle()
                        .fill(Color.primary.opacity(isHovering ? 0.10 : 0.04))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Learn about \(info.title)")
        .accessibilityLabel(Text("About \(info.title)"))
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text(info.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.primary)

                Text(info.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(width: 260, alignment: .leading)
        }
        .onHover { isHovering = $0 }
    }
}

private struct GeneralTitleLabel: View {
    let title: String
    let info: GeneralInfo?

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.82)

            if let info {
                GeneralInfoButton(info: info)
            }
        }
        .layoutPriority(1)
    }
}

private struct GeneralSectionHeading: View {
    let title: String
    let info: GeneralInfo?

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            if let info {
                GeneralInfoButton(info: info)
            }
        }
        .padding(.leading, 10)
    }
}

private struct GeneralToggleRow: View {
    let title: String
    @Binding var isOn: Bool
    var help: String
    var info: GeneralInfo? = nil

    var body: some View {
        HStack(spacing: 10) {
            GeneralTitleLabel(title: title, info: info)

            Spacer(minLength: 10)

            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.regular)
                .tint(.accentColor)
                .help(help)
                .accessibilityLabel(Text(title))
                .accessibilityValue(Text(isOn ? "On" : "Off"))
                .accessibilityHint(Text(help))
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

private struct GeneralActionRow: View {
    let title: String
    let value: String
    let systemImage: String?
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.primary)

                Spacer(minLength: 10)

                HStack(spacing: 6) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .font(.system(size: 11, weight: .semibold))
                    }
                    Text(value)
                        .font(.caption.weight(.semibold))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(Color.secondary)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .background(isHovering ? Color.primary.opacity(0.035) : Color.clear)
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { isHovering = $0 }
        .overlay(alignment: .bottom) {
            Divider()
        }
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(value))
        .accessibilityHint(Text(help))
    }
}

private struct GeneralDisclosureRow: View {
    let title: String
    let value: String
    @Binding var isExpanded: Bool
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.18)) {
                isExpanded.toggle()
            }
            action()
        } label: {
            HStack(spacing: 10) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.primary)

                Spacer(minLength: 10)

                Text(value)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(
                        Circle()
                            .fill(Color.primary.opacity(isHovering ? 0.10 : 0.06))
                    )
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .background(isHovering ? Color.primary.opacity(0.035) : Color.clear)
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { isHovering = $0 }
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text("\(value), \(isExpanded ? "expanded" : "collapsed")"))
        .accessibilityHint(Text(help))
    }
}

private struct GeneralExpandedContent<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.025))
        .overlay(alignment: .top) {
            Divider()
        }
    }
}

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
    @State private var settingsColumnVisibility: NavigationSplitViewVisibility = .all

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
                        meetingSession.retryFailedMeeting(id: item.id)
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
                    actionTitle: activity.transcriptURL == nil ? nil : "Open Transcript",
                    action: activity.transcriptURL.map { transcriptURL in
                        {
                            trackSettingsAction("open_current_activity", page: .home)
                            NSWorkspace.shared.open(transcriptURL)
                        }
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
                    canRetryFailedMeetings: canRetryFailedMeetings,
                    failedMeetingRetryUnavailableReason: failedMeetingRetryUnavailableReason,
                    canRetranscribeSavedMeetings: canRetranscribeSavedMeetings,
                    savedMeetingRetranscriptionUnavailableReason: savedMeetingRetranscriptionUnavailableReason,
                    onOpenDictation: { entry in
                        trackSettingsAction("open_recent_dictation", page: .home)
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
                        meetingSession.retryFailedMeeting(id: item.id)
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
        speakerPeopleModel.profileFilter = .needsReview
        navigation.selectedPage = .home
        homeActivityTab = .speakers
        homeHeroMode = .speakers
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
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(preview.markdown, forType: .string)
    }

    private func handleRetranscribeMeeting(_ item: RecentMeetingItem) {
        guard let input = item.audio?.retranscriptionInput else {
            NSSound.beep()
            return
        }

        trackSettingsAction("retranscribe_saved_meeting", page: .home)
        Task { @MainActor in
            let didStart = await meetingSession.retranscribeSavedMeeting(
                micAudioURL: input.micURL,
                systemAudioURL: input.systemURL,
                title: item.title
            )
            if !didStart {
                NSSound.beep()
            }
        }
    }

    private func presentHomeMeetingPreview(_ item: RecentMeetingItem) {
        trackSettingsAction("preview_recent_meeting", page: .home)
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
            HomeRowMenuItem(title: "Open saved file", symbolName: "doc.text") {
                trackSettingsAction("open_recent_dictation_file", page: .home)
                NSWorkspace.shared.open(entry.url)
            },
            HomeRowMenuItem(title: "Report issue", symbolName: "flag") {
                trackSettingsAction("flag_dictation", page: .home)
                homeFeedbackTarget = HomeFeedbackTarget.dictation(entry)
            },
            HomeRowMenuItem(title: "Reveal in Finder", symbolName: "folder") {
                trackSettingsAction("reveal_dictation_in_finder", page: .home)
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

        items.append(contentsOf: [
            HomeRowMenuItem(title: "Report issue", symbolName: "flag") {
                trackSettingsAction("flag_meeting", page: .home)
                homeFeedbackTarget = HomeFeedbackTarget.meeting(item)
            },
            HomeRowMenuItem(title: "Show transcript in Finder", symbolName: "doc.text") {
                trackSettingsAction("reveal_meeting_in_finder", page: .home)
                NSWorkspace.shared.activateFileViewerSelecting([item.transcriptURL])
            }
        ])

        if let audio = item.audio, let firstAudio = audio.urls.first {
            if audio.retranscriptionInput != nil {
                items.append(
                    HomeRowMenuItem(
                        title: "Re-transcribe with speaker ID",
                        symbolName: "person.2.fill",
                        isEnabled: canRetranscribeSavedMeetings
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
        do {
            if let audio = item.audio, MeetingAudioPlayback.shared.isActive(audio) {
                MeetingAudioPlayback.shared.stop()
            }
            try removeItemIfPresent(at: item.transcriptURL)
            if let audio = item.audio {
                try removeItemIfPresent(at: audio.directoryURL)
            }
            refreshRecentCaptures(force: true)
        } catch {
            presentHomeDeleteFailure(
                title: "Could not delete meeting",
                error: error
            )
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

        if !item.audioURLs.isEmpty {
            meetingSession.deleteFailedMeeting(id: item.id)
        } else {
            meetingSession.dismissFailedMeeting(id: item.id)
        }
    }

    private func removeItemIfPresent(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func presentHomeDeleteFailure(title: String, error: Error) {
        NSSound.beep()
        homeDeleteFailure = HomeDeleteFailure(
            title: title,
            message: error.localizedDescription
        )
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
                    )
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
                    )
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
                    )
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
                    )
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
                        help: showGeneralModelSettings ? "Hide transcription model settings." : "Show transcription model settings."
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
                        help: showGeneralShortcutSettings ? "Hide keyboard shortcut settings." : "Show keyboard shortcut settings."
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
                        help: showGeneralPrivacySettings ? "Hide privacy settings." : "Show privacy settings."
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
                        help: "Choose an audio file to transcribe."
                    ) {
                        trackSettingsAction("import_recording", page: .general)
                        actions.importAudioFile()
                    }

                    GeneralDisclosureRow(
                        title: "Corrections",
                        value: customDictionaryStatusLine,
                        isExpanded: $showGeneralCorrections,
                        help: showGeneralCorrections ? "Hide correction settings." : "Show correction settings."
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
                    SettingsInlineActionButton(title: "Send Test Sentry Event", tone: .warning) {
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

                SettingsInlineActionButton(title: "Clear all", tone: .destructive) {
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
                summary: "Name deferred speaker reviews, play samples, and clean up duplicates."
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
        AgentConnectionSettingsPage()
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
        guard SettingsDashboardRefreshPolicy.shouldStartRefresh(
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

private struct AutoEnterAppCandidate: Identifiable, Equatable {
    let bundleID: String
    let name: String

    var id: String { bundleID }

    static func runningApps() -> [AutoEnterAppCandidate] {
        let transcriptedBundleID = Bundle.main.bundleIdentifier
        let candidates = NSWorkspace.shared.runningApplications.compactMap { app -> AutoEnterAppCandidate? in
            guard app.activationPolicy == .regular,
                  let bundleID = app.bundleIdentifier,
                  bundleID != transcriptedBundleID else {
                return nil
            }

            return AutoEnterAppCandidate(
                bundleID: bundleID,
                name: app.localizedName ?? bundleID
            )
        }

        var seen = Set<String>()
        return candidates
            .filter { seen.insert($0.bundleID).inserted }
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }
}

private struct CorrectionDraftRow: Identifiable, Equatable {
    let id: UUID
    var spoken: String
    var replacement: String

    init(id: UUID = UUID(), spoken: String = "", replacement: String = "") {
        self.id = id
        self.spoken = spoken
        self.replacement = replacement
    }

    init(entry: CustomDictionaryEntry) {
        self.init(spoken: entry.spoken, replacement: entry.replacement)
    }

    static func rows(from rawText: String) -> [CorrectionDraftRow] {
        let rows = CustomDictionaryPreferences.entries(from: rawText).map(CorrectionDraftRow.init(entry:))
        return rows.isEmpty ? [CorrectionDraftRow()] : rows
    }

    static func rawText(from rows: [CorrectionDraftRow]) -> String {
        rows.compactMap { row in
            let spoken = row.spoken.trimmingCharacters(in: .whitespacesAndNewlines)
            let replacement = row.replacement.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !spoken.isEmpty else { return nil }
            if replacement.isEmpty || replacement == spoken {
                return spoken
            }
            return "\(spoken) -> \(replacement)"
        }
        .joined(separator: "\n")
    }
}

private struct CorrectionEditorRow: View {
    @Binding var spoken: String
    @Binding var replacement: String
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            TextField("okay ours", text: $spoken)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(Text("Mistake"))

            TextField("OKRs", text: $replacement)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(Text("Fix"))

            Button(role: .destructive, action: onRemove) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(SettingsHoverButtonStyle(tone: .destructive, cornerRadius: 7))
            .accessibilityLabel(Text("Remove correction"))
            .help("Remove this correction.")
        }
    }
}

private struct ModelChoiceRow: View {
    let model: TranscriptionModelChoice
    let isPreferred: Bool
    let isEffective: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbolName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(symbolColor)
                .frame(width: 22)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(model.title)
                        .font(.subheadline.weight(.semibold))

                    Text(statusLabel)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(statusColor)
                }

                Text(model.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)
        }
    }

    private var symbolName: String {
        if isEffective { return "checkmark.circle.fill" }
        return "circle"
    }

    private var symbolColor: Color {
        if isEffective { return .green }
        return .secondary
    }

    private var statusLabel: String {
        if isEffective { return "Active" }
        if isPreferred { return "Preferred" }
        return model.availabilityStatus
    }

    private var statusColor: Color {
        if isEffective { return .green }
        return .secondary
    }
}

private struct AutoEnterAllowedAppRow: View {
    let title: String
    let bundleID: String
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.green)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))

                Text(bundleID)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            SettingsInlineActionButton(
                title: "Remove",
                tone: .destructive,
                action: remove
            )
        }
    }
}

private struct SettingsRecentMeetingAudioControl: View {
    let title: String
    let symbolName: String
    let isActive: Bool
    let isPlaying: Bool
    let scrubber: AnyView?
    let action: () -> Void

    init(
        title: String,
        symbolName: String,
        isActive: Bool,
        isPlaying: Bool,
        scrubber: AnyView? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.symbolName = symbolName
        self.isActive = isActive
        self.isPlaying = isPlaying
        self.scrubber = scrubber
        self.action = action
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: action) {
                HStack(spacing: 8) {
                    Image(systemName: symbolName)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(iconForeground)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(iconBackground))

                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.secondary.opacity(0.22))
                            .frame(width: 44, height: 4)

                        Capsule()
                            .fill(playheadColor)
                            .frame(width: isPlaying ? 28 : 8, height: 4)

                        Circle()
                            .fill(playheadColor)
                            .frame(width: 8, height: 8)
                            .offset(x: isPlaying ? 24 : 4)
                    }
                    .frame(width: 44, height: 12)

                    Text(title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .buttonStyle(SettingsHoverButtonStyle(
                tone: isActive ? .accent : .neutral,
                cornerRadius: 8,
                normalFill: background,
                normalStroke: stroke
            ))

            if let scrubber {
                scrubber
            }
        }
    }

    private var background: Color {
        isActive ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.08)
    }

    private var stroke: Color {
        isActive ? Color.accentColor.opacity(0.28) : Color.primary.opacity(0.10)
    }

    private var iconBackground: Color {
        isActive ? Color.accentColor : Color.primary.opacity(0.12)
    }

    private var iconForeground: Color {
        isActive ? .white : .secondary
    }

    private var playheadColor: Color {
        isActive ? .accentColor : .secondary.opacity(0.65)
    }
}

private struct SettingsFailedMeetingRow: View {
    let item: MeetingSessionController.FailedMeetingItem
    let canRetry: Bool
    let retryUnavailableReason: String?
    let audio: MeetingAudioAttachment?
    let retryAction: () -> Void
    let revealAudioAction: () -> Void
    let secondaryAction: () -> Void
    @ObservedObject private var playback = MeetingAudioPlayback.shared
    @State private var selectedPlaybackChoiceID: String?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if item.failureKind == .recordingTooShort {
                Image(systemName: "timer")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 24)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))

                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(item.meta)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 12)

            if let audio {
                let selectedChoice = selectedPlaybackChoice(for: audio)
                SettingsRecentMeetingAudioControl(
                    title: playback.buttonTitle(for: audio, choice: selectedChoice),
                    symbolName: playback.symbolName(for: audio, choice: selectedChoice),
                    isActive: playback.isActive(audio, choice: selectedChoice),
                    isPlaying: playback.isPlaying && playback.isActive(audio, choice: selectedChoice),
                    scrubber: playback.isActive(audio)
                        ? AnyView(MeetingAudioScrubber(attachment: audio, width: 190))
                        : nil
                ) {
                    playback.toggle(audio, choice: selectedChoice)
                }
                .help("\(playback.buttonTitle(for: audio, choice: selectedChoice)) retained meeting audio")

                MeetingAudioSourceMenu(
                    attachment: audio,
                    selectedChoiceID: selectedPlaybackChoiceBinding(for: audio)
                ) { choice in
                    if playback.isActive(audio) {
                        playback.switchSource(audio, choice: choice)
                    }
                }

                Button {
                    revealAudioAction()
                } label: {
                    Label("Show Audio", systemImage: "folder")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
                .buttonStyle(SettingsHoverButtonStyle(
                    cornerRadius: 8,
                    normalFill: Color.primary.opacity(0.025),
                    normalStroke: Color.primary.opacity(0.06)
                ))
            }

            if item.isRetryable || item.isRetrying {
                Button {
                    retryAction()
                } label: {
                    Label(item.isRetrying ? "Retrying..." : "Try Again", systemImage: "arrow.clockwise")
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
                .disabled(retryDisabled)
                .help(retryHelp)
            }

            Button(role: hasRetainedAudioFiles ? .destructive : nil) {
                secondaryAction()
            } label: {
                Label(hasRetainedAudioFiles ? "Delete" : "Dismiss", systemImage: hasRetainedAudioFiles ? "trash" : "xmark")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
            .buttonStyle(SettingsHoverButtonStyle(
                tone: hasRetainedAudioFiles ? .destructive : .neutral,
                cornerRadius: 8,
                normalFill: hasRetainedAudioFiles ? Color.red.opacity(0.06) : Color.primary.opacity(0.025),
                normalStroke: hasRetainedAudioFiles ? Color.red.opacity(0.14) : Color.primary.opacity(0.06)
            ))
        }
    }

    private var retryDisabled: Bool {
        !canRetry || !item.isRetryable || !item.hasAudioFiles || item.isRetrying
    }

    private var retryHelp: String {
        if item.isRetrying {
            return "Retry is already running."
        }
        if !item.hasAudioFiles {
            return "This meeting does not have enough saved audio to retry."
        }
        if !item.isRetryable {
            return "This meeting does not have enough saved audio to retry."
        }
        if let retryUnavailableReason {
            return retryUnavailableReason
        }
        if !canRetry {
            return "Wait for the current meeting work to finish before retrying."
        }
        return "Transcribe this saved audio again."
    }

    private var hasRetainedAudioFiles: Bool {
        !item.audioURLs.isEmpty
    }

    private func selectedPlaybackChoice(for audio: MeetingAudioAttachment) -> MeetingAudioPlaybackChoice? {
        playback.activeChoice(for: audio) ?? audio.playbackChoice(id: selectedPlaybackChoiceID)
    }

    private func selectedPlaybackChoiceBinding(for audio: MeetingAudioAttachment) -> Binding<String?> {
        Binding(
            get: { selectedPlaybackChoice(for: audio)?.id },
            set: { selectedPlaybackChoiceID = $0 }
        )
    }
}

private struct AgentConnectionSettingsPage: View {
    @StateObject private var viewModel = AgentConnectionViewModel(
        context: AgentConnectionContext(meetingTitle: nil, meetingDate: nil, transcriptURL: nil)
    )
    @State private var claudeDesktopStatus = ClaudeDesktopIntegrationInstaller.currentStatus()
    @State private var claudeDesktopInstallResult: ClaudeDesktopIntegrationInstallResult?
    @State private var claudeDesktopInstallError: String?
    @State private var isInstallingClaudeDesktop = false
    @State private var copiedClaudeDesktopConfig = false
    @State private var copiedLocalAgentPrompt = false
    @State private var copiedFolderPrompt = false
    @State private var copiedFolderPaths = false
    @State private var showAdvancedAgentSetup = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsPageIntro(
                title: "Agent",
                summary: "Install direct tools for Claude Desktop, or copy a prompt for local coding agents."
            )

            agentActionSection

            if let claudeDesktopInstallResult {
                ClaudeDesktopSelfTestResultView(result: claudeDesktopInstallResult)
            }

            if let claudeDesktopInstallError {
                Label(claudeDesktopInstallError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsSection(
                title: "Details",
                detail: "Advanced setup."
            ) {
                AgentSetupDetailsDisclosure(isExpanded: $showAdvancedAgentSetup) {
                    VStack(alignment: .leading, spacing: 14) {
                        ClaudeDesktopStatusRow(status: claudeDesktopStatus)

                        HStack(spacing: 10) {
                            SettingsInlineActionButton(
                                title: copiedClaudeDesktopConfig ? "Copied" : "Copy Claude Config",
                                symbolName: "doc.on.doc"
                            ) {
                                copyText(
                                    ClaudeDesktopIntegrationInstaller.configSnippet(),
                                    showingCopiedFeedback: $copiedClaudeDesktopConfig
                                )
                            }

                            SettingsInlineActionButton(title: "Show Config", symbolName: "folder") {
                                revealClaudeDesktopConfig()
                            }
                            .disabled(!claudeDesktopStatus.configExists)
                        }

                        AgentFolderRow(
                            name: "Meetings",
                            detail: "Meeting Markdown files.",
                            path: viewModel.context.meetingsFolderURL.path,
                            isAvailable: viewModel.fileExists(viewModel.context.meetingsFolderURL)
                        ) {
                            viewModel.reveal(viewModel.context.meetingsFolderURL)
                        }

                        AgentFolderRow(
                            name: "Dictation",
                            detail: "Dictation Markdown files.",
                            path: viewModel.context.dictationsFolderURL.path,
                            isAvailable: viewModel.fileExists(viewModel.context.dictationsFolderURL)
                        ) {
                            viewModel.reveal(viewModel.context.dictationsFolderURL)
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 8) {
                            Label("Web chats are fallback only", systemImage: "globe")
                                .font(.subheadline.weight(.semibold))

                            Text("Claude web, ChatGPT web, Cowork, and mobile chats usually cannot see your Mac. Use them for a pasted meeting or granted folders, not full Transcripted memory.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            HStack(spacing: 10) {
                                SettingsInlineActionButton(
                                    title: copiedFolderPrompt ? "Copied" : "Copy Folder Prompt",
                                    symbolName: "doc.on.doc"
                                ) {
                                    copyText(
                                        AgentConnectionGuide.folderAccessPrompt,
                                        showingCopiedFeedback: $copiedFolderPrompt
                                    )
                                }

                                SettingsInlineActionButton(
                                    title: copiedFolderPaths ? "Copied" : "Copy Paths",
                                    symbolName: "folder"
                                ) {
                                    copyText(
                                        AgentConnectionGuide.folderPathsText,
                                        showingCopiedFeedback: $copiedFolderPaths
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
        .onAppear(perform: refreshClaudeDesktopStatus)
    }

    private var agentActionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                AgentConnectActionButton(
                    symbolName: claudeDesktopActionSymbol,
                    title: claudeDesktopActionTitle,
                    subtitle: "Claude Desktop",
                    statusText: claudeDesktopStatusText,
                    statusSymbolName: claudeDesktopStatusSymbol,
                    tint: claudeDesktopStatusTint,
                    isEnabled: claudeDesktopActionEnabled
                ) {
                    installClaudeDesktop()
                }

                AgentConnectActionButton(
                    symbolName: copiedLocalAgentPrompt ? "checkmark" : "chevron.left.forwardslash.chevron.right",
                    title: copiedLocalAgentPrompt ? "Copied" : "Copy for Agent",
                    subtitle: "Codex, Claude Code, Cursor",
                    statusText: "Local files",
                    statusSymbolName: "folder",
                    tint: Color(nsColor: .systemBlue),
                    isEnabled: true
                ) {
                    copyText(
                        AgentConnectionGuide.starterPrompt(filename: nil),
                        showingCopiedFeedback: $copiedLocalAgentPrompt
                    )
                }
            }

            if !claudeDesktopStatus.claudeDesktopLikelyInstalled {
                SettingsInlineActionButton(title: "Get Claude Desktop", symbolName: "arrow.down.circle", tone: .accent) {
                    openClaudeDesktopDownload()
                }
            }
        }
    }

    private var claudeDesktopActionTitle: String {
        if isInstallingClaudeDesktop {
            return "Installing..."
        }

        switch claudeDesktopStatus.state {
        case .installed:
            return "Install in Claude"
        case .notInstalled:
            return "Install in Claude"
        case .needsRepair:
            return "Repair Claude Setup"
        }
    }

    private var claudeDesktopActionSymbol: String {
        if isInstallingClaudeDesktop {
            return "hourglass"
        }

        switch claudeDesktopStatus.state {
        case .installed:
            return "checkmark"
        case .notInstalled:
            return "sparkles"
        case .needsRepair:
            return "arrow.clockwise"
        }
    }

    private var claudeDesktopActionEnabled: Bool {
        !isInstallingClaudeDesktop
            && claudeDesktopStatus.bundledBinaryExists
    }

    private var claudeDesktopStatusText: String {
        if !claudeDesktopStatus.bundledBinaryExists {
            return "Missing"
        }

        switch claudeDesktopStatus.state {
        case .installed:
            return "Installed"
        case .notInstalled:
            return "Not installed"
        case .needsRepair:
            return "Repair"
        }
    }

    private var claudeDesktopStatusSymbol: String {
        switch claudeDesktopStatus.state {
        case .installed:
            return "checkmark.circle.fill"
        case .notInstalled:
            return "arrow.right.circle"
        case .needsRepair:
            return "exclamationmark.triangle.fill"
        }
    }

    private var claudeDesktopStatusTint: Color {
        switch claudeDesktopStatus.state {
        case .installed:
            return .green
        case .notInstalled:
            return Color(nsColor: .systemOrange)
        case .needsRepair:
            return .orange
        }
    }

    private func refreshClaudeDesktopStatus() {
        claudeDesktopStatus = ClaudeDesktopIntegrationInstaller.currentStatus()
    }

    private func installClaudeDesktop() {
        guard !isInstallingClaudeDesktop else { return }
        isInstallingClaudeDesktop = true
        claudeDesktopInstallResult = nil
        claudeDesktopInstallError = nil

        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try ClaudeDesktopIntegrationInstaller.installForClaudeDesktop()
                }.value

                claudeDesktopInstallResult = result
                refreshClaudeDesktopStatus()
            } catch {
                claudeDesktopInstallError = error.localizedDescription
                refreshClaudeDesktopStatus()
            }

            isInstallingClaudeDesktop = false
        }
    }

    private func copyText(_ text: String, showingCopiedFeedback copiedFlag: Binding<Bool>? = nil) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard let copiedFlag else { return }
        copiedFlag.wrappedValue = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copiedFlag.wrappedValue = false
        }
    }

    private func revealClaudeDesktopConfig() {
        NSWorkspace.shared.activateFileViewerSelecting([claudeDesktopStatus.configURL])
    }

    private func openClaudeDesktopDownload() {
        guard let url = URL(string: "https://claude.ai/download") else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct AgentConnectActionButton: View {
    let symbolName: String
    let title: String
    let subtitle: String
    let statusText: String
    let statusSymbolName: String
    let tint: Color
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: symbolName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 42, height: 42)
                    .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(tint.opacity(0.18), lineWidth: 1)
                    )

                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.88)

                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)

                    Label(statusText, systemImage: statusSymbolName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.88)
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(tint.opacity(isEnabled ? 0.95 : 0.45))
                    .frame(width: 26, height: 26)
                    .background(tint.opacity(isEnabled ? 0.11 : 0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(SettingsHoverButtonStyle(
            tone: .accent,
            cornerRadius: 8,
            normalFill: Color(nsColor: .controlBackgroundColor).opacity(0.78),
            normalStroke: tint.opacity(0.28),
            hoverFill: Color(nsColor: .controlBackgroundColor).opacity(0.95),
            pressedFill: Color(nsColor: .controlBackgroundColor).opacity(0.88),
            hoverStroke: tint.opacity(0.56)
        ))
        .disabled(!isEnabled)
    }
}

private struct AgentSetupDetailsDisclosure<Content: View>: View {
    @Binding var isExpanded: Bool
    let content: Content

    init(
        isExpanded: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) {
        self._isExpanded = isExpanded
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 16, height: 16)

                    Text("Show setup details")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)

                    Spacer(minLength: 12)

                    Text(isExpanded ? "Hide" : "Show")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(SettingsHoverButtonStyle(
                tone: .neutral,
                cornerRadius: 8,
                normalFill: Color.primary.opacity(0.018),
                normalStroke: Color.primary.opacity(0.07),
                hoverFill: Color.primary.opacity(0.04),
                pressedFill: Color.primary.opacity(0.06),
                hoverStroke: Color.primary.opacity(0.12)
            ))
            .accessibilityLabel(Text("Show setup details"))
            .accessibilityValue(Text(isExpanded ? "Expanded" : "Collapsed"))
            .accessibilityHint(Text(isExpanded ? "Hide advanced agent setup details" : "Show advanced agent setup details"))

            if isExpanded {
                VStack(alignment: .leading, spacing: 14) {
                    content
                }
                .padding(.top, 14)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

private struct ClaudeDesktopStatusRow: View {
    let status: ClaudeDesktopIntegrationStatus

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbolName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let configuredPath = status.configuredCommandPath,
                   configuredPath != status.installedBinaryURL.path {
                    Text(configuredPath)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }

            Spacer(minLength: 12)
        }
    }

    private var symbolName: String {
        switch status.state {
        case .installed:
            return "checkmark.circle.fill"
        case .notInstalled:
            return "circle"
        case .needsRepair:
            return "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch status.state {
        case .installed:
            return .green
        case .notInstalled:
            return .secondary
        case .needsRepair:
            return .orange
        }
    }

    private var title: String {
        switch status.state {
        case .installed:
            return "Installed"
        case .notInstalled:
            return "Not installed yet"
        case .needsRepair:
            return "Needs update"
        }
    }

    private var detail: String {
        if !status.bundledBinaryExists {
            return "This app build does not include Transcripted direct tools yet."
        }

        if !status.configIsReadable {
            return "Claude Desktop config is not readable JSON. Install will back it up and write a clean config."
        }

        switch status.state {
        case .installed:
            return "Claude Desktop is configured. Restart Claude Desktop if you just installed it."
        case .notInstalled:
            return status.claudeDesktopLikelyInstalled
                ? "Click Install for Claude Desktop, then restart Claude Desktop."
                : "Claude Desktop was not found. You can still install now, then install Claude Desktop."
        case .needsRepair:
            if !status.installedBinaryExists {
                return "The server file is missing. Install will copy a fresh one and update Claude Desktop."
            }
            return "Claude Desktop points at another Transcripted server. Install will update it."
        }
    }
}

private struct ClaudeDesktopSelfTestResultView: View {
    let result: ClaudeDesktopIntegrationInstallResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                "Ready. Restart Claude.",
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.green)

            Text("\(result.selfTest.meetingFileCount) meetings, \(result.selfTest.dictationFileCount) dictation files found.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let backupURL = result.backupURL {
                Text("Previous config backed up to \(backupURL.lastPathComponent).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct AgentFolderRow: View {
    let name: String
    let detail: String
    let path: String
    let isAvailable: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(name)
                        .font(.subheadline.weight(.semibold))

                    if !isAvailable {
                        Text("Not written yet")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(path)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 12)

            SettingsInlineActionButton(title: "Reveal", action: action)
                .disabled(!isAvailable)
        }
    }
}
