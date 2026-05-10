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
        SettingsSidebarSection(id: "recording", title: "Recording", pages: [.meetings, .dictations, .people, .shortcuts]),
        SettingsSidebarSection(id: "setup", title: "Setup", pages: [.general, .models, .storage, .connectAgent]),
        SettingsSidebarSection(id: "trust", title: "Trust", pages: [.privacy, .support, .about])
    ]
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
    @State private var showTranscriptedInDock = DockVisibilityPreferences.isVisible()
    @State private var launchAtLoginEnabled = LaunchAtLoginController.isEnabled
    @State private var launchAtLoginStatus = LaunchAtLoginController.statusDescription
    @State private var customDictionaryText = CustomDictionaryPreferences.rawText()
    @State private var customDictionaryRows = CorrectionDraftRow.rows(from: CustomDictionaryPreferences.rawText())
    @State private var customDictionaryPreviewInput = "review the okay ours before the q four meeting"
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
    @State private var feedbackActionStatus: String?
    @State private var sentryTestStatus: String?
    @State private var diagnosticsActionStatus: String?
    @State private var permissionStates = PermissionSnapshot.current()
    @State private var captureLibraryURL = FileManager.default.transcriptedCaptureLibraryDir
    @State private var captureLibraryStatusMessage: String?
    @State private var captureLibraryStatusIsError = false
    @State private var recentMeetings: [RecentMeetingItem] = []
    @State private var recentDictations: [SavedDictationEntry] = []
    @State private var recentCapturesLoading = false
    @State private var recentCaptureRefreshTask: Task<Void, Never>?
    @State private var menuBarItemVisibility = MenuBarVisibilityPreferences.snapshot()
    @State private var showSupportFolders = false
    @State private var copiedAgentMeetingID: String?
    @State private var meetingVoiceProcessingEnabled = MicrophoneProcessingPreferences.isVoiceProcessingEnabled()
    @State private var audioRetentionWindow = AudioStoragePreferences.deleteAudioAfter()
    @State private var pendingAudioRetentionWindow: AudioRetentionWindow?
    @StateObject private var homeViewModel = HomeViewModel()
    @State private var homeActivityTab: HomeActivityTab = .meetings
    @State private var homeHeroMode: HomeHeroMode = .meeting
    @State private var homeCopiedRowID: String?
    @State private var homeDeleteConfirmation: HomeDeleteConfirmation?
    @State private var homeDeleteFailure: HomeDeleteFailure?
    @State private var homeFeedbackTarget: HomeFeedbackTarget?
    @State private var homeMeetingPreview: HomeMeetingPreview?
    @State private var homeMeetingPreviewLoadTask: Task<Void, Never>?

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
        NavigationSplitView {
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
        .task(id: navigation.presentationID) {
            refreshState()
            trackSettingsPageViewed(navigation.selectedPage, source: "presentation")
        }
        .onChange(of: navigation.selectedPage) { _, page in
            refreshRecentCaptures()
            if page == .shortcuts {
                refreshAutoEnterPreferences(includeCandidates: true)
            }
            trackSettingsPageViewed(page, source: "navigation")
        }
        .onChange(of: meetingSession.lastSavedTranscriptURL) { _, _ in
            refreshRecentCaptures()
        }
        .onReceive(NotificationCenter.default.publisher(for: .dictationTranscriptDidSave)) { _ in
            refreshRecentCaptures()
        }
        .onReceive(NotificationCenter.default.publisher(for: .transcriptionModelPreferenceDidChange)) { _ in
            preferredTranscriptionModel = TranscriptionModelPreferences.preferredModel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuBarVisibilityPreferencesDidChange)) { _ in
            refreshMenuBarVisibility()
        }
        .onReceive(NotificationCenter.default.publisher(for: .dockVisibilityPreferencesDidChange)) { _ in
            refreshDockVisibility()
        }
        .onReceive(NotificationCenter.default.publisher(for: .hotkeysDidChange)) { _ in
            refreshShortcutState()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
            refreshRecentCaptures()
            refreshShortcutState()
        }
        .onDisappear {
            recentCaptureRefreshTask?.cancel()
            recentCaptureRefreshTask = nil
            homeMeetingPreviewLoadTask?.cancel()
            homeMeetingPreviewLoadTask = nil
            homeViewModel.cancel()
        }
    }

    @ViewBuilder
    private func sidebarRows(for pages: [TranscriptedSettingsPage]) -> some View {
        ForEach(pages) { page in
            Label(page.title, systemImage: page.systemImage)
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
        .buttonStyle(.plain)
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
        case .meetings:
            meetingsPage
        case .dictations:
            dictationsPage
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

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 20) {
                HomeWelcomeHeader(
                    name: homeViewModel.welcomeName,
                    summary: homeWelcomeSummary
                )
                .frame(maxWidth: .infinity, alignment: .leading)

                HomeStatsTopCard(stats: stats, streak: homeStreak)
            }

            HomeHeroCard(
                selectedMode: homeHeroModeSelection,
                onStartDictation: {
                    trackSettingsAction("start_dictation", page: .home)
                    actions.startDictation()
                },
                onStartMeeting: {
                    trackSettingsAction("start_meeting", page: .home)
                    actions.startMeeting()
                }
            ) {
                HomeActivityTabsCard(
                    selectedTab: homeActivityTab,
                    dictationSections: homeViewModel.dictationDaySections,
                    meetingSections: homeViewModel.meetingDaySections,
                    isLoading: homeViewModel.isLoading,
                    isLoadingMore: homeViewModel.isLoadingMore,
                    canLoadMoreDictations: homeViewModel.canLoadMoreDictations,
                    canLoadMoreMeetings: homeViewModel.canLoadMoreMeetings,
                    copiedRowID: homeCopiedRowID,
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
                    meetingMenuItems: { item in
                        meetingRowMenuItems(for: item)
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

            if !needsAttention.isEmpty {
                HomeNeedsAttentionCard(
                    issues: needsAttention,
                    onOpenPrivacy: {
                        trackSettingsAction("open_needs_attention", page: .home)
                        navigation.selectedPage = .privacy
                    }
                )
            }
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
                    homeFeedbackTarget = preview.feedbackTarget
                },
                onDone: {
                    homeMeetingPreview = nil
                }
            )
        }
        .onChange(of: homeActivityTab) { _, newValue in
            trackSettingsAction("home_tab_\(newValue.rawValue)", page: .home)
        }
        .alert(item: $homeDeleteConfirmation) { confirmation in
            Alert(
                title: Text(confirmation.title),
                message: Text(confirmation.message),
                primaryButton: .destructive(Text("Delete")) {
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
        navigation.selectedPage == .home ? -34 : 14
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
            NSSound.beep()
            return
        }

        let result = TranscriptedSupportActions.openFeedbackEmail(url)
        if result == .unavailable {
            NSSound.beep()
        } else {
            homeFeedbackTarget = nil
        }
    }

    private func flashCopied(rowID: String) {
        homeCopiedRowID = rowID
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: MenuTokens.compactCopyFeedbackDurationNanoseconds)
            if homeCopiedRowID == rowID {
                homeCopiedRowID = nil
            }
        }
    }

    private func dictationRowMenuItems(for entry: SavedDictationEntry) -> [HomeRowMenuItem] {
        [
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
                        refreshRecentCaptures()
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
        var items: [HomeRowMenuItem] = [
            HomeRowMenuItem(title: "Reveal in Finder", symbolName: "folder") {
                trackSettingsAction("reveal_meeting_in_finder", page: .home)
                NSWorkspace.shared.activateFileViewerSelecting([item.transcriptURL])
            }
        ]

        if let audio = item.audio, let firstAudio = audio.urls.first {
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
                homeDeleteConfirmation = HomeDeleteConfirmation(
                    title: "Delete this meeting?",
                    message: "This removes the transcript and any retained audio. This cannot be undone."
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
            try removeItemIfPresent(at: item.transcriptURL)
            if let audio = item.audio {
                try removeItemIfPresent(at: audio.directoryURL)
            }
            refreshRecentCaptures()
        } catch {
            presentHomeDeleteFailure(
                title: "Could not delete meeting",
                error: error
            )
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
                    title: "Permissions",
                    detail: permissionsDetailLine
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
                    title: "Voice model",
                    detail: modelCard.detail
                )
            )
        } else if preferredTranscriptionModel != effectiveTranscriptionModel {
            issues.append(
                HomeNeedsAttentionCard.Issue(
                    title: "Voice model",
                    detail: "\(preferredTranscriptionModel.title) is selected but \(effectiveTranscriptionModel.title) is being used."
                )
            )
        }

        return issues
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
                HotkeyRecorderContainer()
                    .frame(height: 108)

                if let dictationTriggerSystemWarning {
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
                Toggle("Send after dictation", isOn: Binding(
                    get: { autoEnterEnabled },
                    set: { newValue in
                        autoEnterEnabled = newValue
                        trackSettingsToggle("auto_send", enabled: newValue, page: .shortcuts)
                        DictationAutoSendPreferences.setEnabled(newValue)
                    }
                ))

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

                        Button("Refresh") {
                            trackSettingsAction("refresh_auto_send_apps", page: .shortcuts)
                            refreshAutoEnterAppCandidates()
                        }

                        Button("Add App…") {
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
                            Toggle(isOn: Binding(
                                get: { autoEnterAllowedBundleIDs.contains(app.bundleID) },
                                set: { isAllowed in
                                    setAutoEnterApp(app.bundleID, isAllowed: isAllowed)
                                }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(app.name)
                                        .font(.subheadline)
                                    Text(app.bundleID)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .disabled(!autoEnterEnabled)
                }

                Text(autoEnterEnabled
                    ? "Transcripted sends \(autoEnterKey.title) after it pastes, only in selected apps."
                    : "Off. Dictation only pastes text."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var generalPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsPageIntro(
                title: "General",
                summary: "Startup and simple corrections for names, acronyms, and phrases."
            )

            SettingsSection(
                title: "Startup",
                detail: "Open Transcripted when you log in."
            ) {
                Toggle("Launch Transcripted at login", isOn: Binding(
                    get: { launchAtLoginEnabled },
                    set: { newValue in
                        updateLaunchAtLogin(newValue)
                    }
                ))

                Text(launchAtLoginStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SettingsSection(
                title: "Dock",
                detail: "Choose whether Transcripted stays visible in the Dock when idle."
            ) {
                Toggle("Show Transcripted in Dock", isOn: Binding(
                    get: { showTranscriptedInDock },
                    set: { newValue in
                        showTranscriptedInDock = newValue
                        trackSettingsToggle("show_in_dock", enabled: newValue, page: .general)
                        DockVisibilityPreferences.setVisible(newValue)
                    }
                ))

                Text(
                    showTranscriptedInDock
                        ? "Transcripted keeps a normal Dock icon."
                        : "Transcripted stays menu-bar-only while idle and still becomes visible during active recording if recovery is needed."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            SettingsSection(
                title: "Setup",
                detail: "Revisit the guided permissions and first-dictation flow."
            ) {
                Button("Run Setup Again") {
                    trackSettingsAction("run_onboarding_again", page: .general)
                    actions.openOnboarding()
                }

                Text("Use this if permissions changed, setup felt skipped, or you want to test the first-run flow again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsSection(
                title: "Corrections",
                detail: "Fix the words Transcripted usually gets wrong."
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Add what Transcripted writes now, then the version you want saved.")
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            Text("When Transcripted writes this")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Text("Replace with")
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
                        }

                        Spacer()

                        Button("Clear") {
                            trackSettingsAction("clear_corrections", page: .general)
                            clearCorrectionRows()
                        }
                        .disabled(!hasCustomDictionaryContent)
                    }

                    HStack(alignment: .firstTextBaseline) {
                        Text(customDictionaryStatusLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer()

                        Text("Applies to dictation and meetings after transcription.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Try it")
                            .font(.subheadline.weight(.semibold))

                        TextField("Dictate a sample phrase", text: $customDictionaryPreviewInput)
                            .textFieldStyle(.roundedBorder)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Preview")
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

                    DisclosureGroup("Advanced text format", isExpanded: $showAdvancedCorrectionsText) {
                        VStack(alignment: .leading, spacing: 10) {
                            TextEditor(text: Binding(
                                get: { customDictionaryText },
                                set: { updateCustomDictionaryText($0) }
                            ))
                            .font(.body.monospaced())
                            .frame(minHeight: 130)
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

                            Text("One per line. Old lists like `spoken -> preferred` still work here.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, 4)

                    Text("Examples: `okay ours` becomes `OKRs`, or `q four roadmap` becomes `Q4 roadmap`.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
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
                    tone: tone(for: modelCard.tone)
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
                            Button("Use Parakeet") {
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

    private var meetingsPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsPageIntro(
                title: "Meetings",
                summary: "Record meetings, import audio, and open recent transcripts."
            )

            SettingsSection(
                title: "Start or Import",
                detail: "Record now, or transcribe a file."
            ) {
                SettingsQuickLinkRow(
                    symbolName: "record.circle.fill",
                    title: "Start Meeting",
                    detail: "Capture your mic and computer audio."
                ) {
                    trackSettingsAction("start_meeting", page: .meetings)
                    actions.startMeeting()
                }

                SettingsQuickLinkRow(
                    symbolName: "waveform",
                    title: "Transcribe Audio File",
                    detail: "Turn an audio file into meeting notes."
                ) {
                    trackSettingsAction("import_recording", page: .meetings)
                    actions.importAudioFile()
                }

                Text("Blocked? Open Privacy and check microphone or system audio.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SettingsSection(
                title: "Recent Meetings",
                detail: "The last five saved meeting transcripts."
            ) {
                if let activity = meetingsPageTranscriptionActivity {
                    SettingsActivityCard(
                        symbolName: activity.symbolName,
                        title: activity.title,
                        status: activity.status,
                        detail: activity.detail,
                        tone: activity.tone,
                        progress: activity.progress,
                        actionTitle: nil,
                        action: nil
                    )
                }

                if recentCapturesLoading && recentMeetings.isEmpty {
                    Text("Loading recent meetings...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if recentMeetings.isEmpty {
                    Text("Record or import a meeting and it will appear here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(recentMeetings) { item in
                        SettingsRecentMeetingRow(
                            item: item,
                            detail: formattedRecentDate(item.date),
                            isCopied: copiedAgentMeetingID == item.id,
                            openAction: {
                                trackSettingsAction("open_recent_meeting", page: .meetings)
                                NSWorkspace.shared.open(item.transcriptURL)
                            },
                            revealAction: {
                                trackSettingsAction("reveal_recent_meeting", page: .meetings)
                                NSWorkspace.shared.activateFileViewerSelecting([item.transcriptURL])
                            },
                            copyPathAction: {
                                trackSettingsAction("copy_recent_meeting_path", page: .meetings)
                                copyPath(item.transcriptURL)
                            },
                            copyForAgentAction: {
                                trackSettingsAction("copy_recent_meeting_for_agent", page: .meetings)
                                copyMeetingForAgent(item)
                            }
                        )
                    }
                }

                SettingsQuickLinkRow(
                    symbolName: "folder",
                    title: "Open Meetings Folder",
                    detail: "See every saved meeting transcript in Finder."
                ) {
                    trackSettingsAction("open_meetings_folder", page: .meetings)
                    openMeetingsFolder()
                }
            }

            if !meetingSession.failedMeetings.isEmpty {
                SettingsSection(
                    title: "Needs Attention",
                    detail: "Retry or clear unfinished meetings."
                ) {
                    ForEach(meetingSession.failedMeetings) { item in
                        SettingsFailedMeetingRow(
                            item: item,
                            retryAction: {
                                trackSettingsAction("retry_failed_meeting", page: .meetings)
                                meetingSession.retryFailedMeeting(id: item.id)
                            },
                            secondaryAction: {
                                trackSettingsAction(item.hasAudioFiles ? "delete_failed_meeting" : "dismiss_failed_meeting", page: .meetings)
                                if item.hasAudioFiles {
                                    meetingSession.deleteFailedMeeting(id: item.id)
                                } else {
                                    meetingSession.dismissFailedMeeting(id: item.id)
                                }
                            }
                        )
                    }
                }
            }

            SettingsSection(
                title: "Microphone Processing",
                detail: "How Transcripted cleans up your mic for meetings."
            ) {
                Toggle("Use Apple voice processing for Safari/Firefox mic attenuation", isOn: Binding(
                    get: { meetingVoiceProcessingEnabled },
                    set: { newValue in
                        meetingVoiceProcessingEnabled = newValue
                        trackSettingsToggle("meeting_voice_processing", enabled: newValue, page: .meetings)
                        MicrophoneProcessingPreferences.setVoiceProcessingEnabled(newValue)
                    }
                ))

                Text(meetingVoiceProcessingEnabled
                    ? "May lower other app audio in Zoom/Meet."
                    : "Off — Transcripted boosts the saved mic and live STT copy in software without changing system audio."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Text("Takes effect on the next recording.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var peoplePage: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsPageIntro(
                title: "People",
                summary: "Name deferred speaker reviews, play samples, and clean up duplicates."
            )

            SpeakerPeopleSettingsSection(model: speakerPeopleModel)
        }
    }

    private var dictationsPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsPageIntro(
                title: "Dictation",
                summary: "Paste the latest dictation and set sound cues."
            )

            SettingsSection(
                title: "Paste Last",
                detail: "Use the newest saved dictation again."
            ) {
                SettingsQuickLinkRow(
                    symbolName: "arrow.turn.down.right",
                    title: "Paste Last Dictation",
                    detail: "Paste into the app you were using."
                ) {
                    trackSettingsAction("paste_last_dictation", page: .dictations)
                    actions.pasteLastDictation()
                }

                Text("If paste is unavailable, Transcripted copies the text.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SettingsSection(
                title: "Recent",
                detail: "The newest saved dictations."
            ) {
                if recentCapturesLoading && recentDictations.isEmpty {
                    Text("Loading recent dictations...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if recentDictations.isEmpty {
                    Text("No dictations saved yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(recentDictations) { item in
                        SettingsQuickLinkRow(
                            symbolName: "text.bubble",
                            title: item.title,
                            detail: "\(formattedRecentDate(item.createdAt)) • \(item.sourceAppName)"
                        ) {
                            trackSettingsAction("open_recent_dictation", page: .dictations)
                            NSWorkspace.shared.open(item.url)
                        }
                    }
                }
            }

            SettingsSection(
                title: "Sounds",
                detail: "Play short cues for dictation state."
            ) {
                Toggle("Play dictation feedback sounds", isOn: Binding(
                    get: { uiSoundsEnabled },
                    set: { newValue in
                        uiSoundsEnabled = newValue
                        trackSettingsToggle("dictation_sounds", enabled: newValue, page: .dictations)
                        UISoundPreferences.setEnabled(newValue)
                    }
                ))

                Text(uiSoundsEnabled
                    ? "Sounds play when dictation starts, stops, completes, or hears no speech."
                    : "Dictation sounds are off."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
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
                    Button("Choose Folder") {
                        trackSettingsAction("choose_capture_library", page: .storage)
                        chooseCaptureLibrary()
                    }

                    Button("Reset to Default") {
                        trackSettingsAction("reset_capture_library", page: .storage)
                        resetCaptureLibraryToDefault()
                    }
                }

                Text("Pick an Obsidian vault or any folder you want agents to read.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let captureLibraryStatusMessage {
                    Text(captureLibraryStatusMessage)
                        .font(.caption)
                        .foregroundColor(captureLibraryStatusIsError ? .red : .secondary)
                }
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
                        TranscriptedPermissionAccess.openSettings(for: kind)
                        refreshPermissions()
                    }
                }
            }

            SettingsSection(
                title: "Reporting",
                detail: "Optional. Scrubbed before anything leaves this Mac."
            ) {
                Toggle("Send crash and error reports", isOn: Binding(
                    get: { crashReportingEnabled },
                    set: { newValue in
                        crashReportingEnabled = newValue
                        trackSettingsToggle("crash_reporting", enabled: newValue, page: .privacy)
                        CrashReportingPreferences.setEnabled(newValue)
                        sentryTestStatus = nil
                        diagnosticsActionStatus = nil
                    }
                ))
                .disabled(!CrashReporter.isAvailable)

                Toggle("Send anonymous usage stats", isOn: Binding(
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
                ))
                .disabled(!AnalyticsReporter.isAvailable)

                HStack {
                    Button("Send Test Sentry Event") {
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

                Text(crashReportingFootnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(analyticsFootnote)
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
                    Toggle("Check automatically", isOn: Binding(
                        get: { sparkleUpdater.automaticUpdateSettings.automaticChecksEnabled },
                        set: { newValue in
                            trackSettingsToggle("automatic_update_checks", enabled: newValue, page: .about)
                            sparkleUpdater.setAutomaticallyChecksForUpdates(newValue)
                        }
                    ))

                    Toggle("Download automatically", isOn: Binding(
                        get: { sparkleUpdater.automaticUpdateSettings.automaticDownloadsEnabled },
                        set: { newValue in
                            trackSettingsToggle("automatic_update_downloads", enabled: newValue, page: .about)
                            sparkleUpdater.setAutomaticallyDownloadsUpdates(newValue)
                        }
                    ))
                    .disabled(!sparkleUpdater.automaticUpdateSettings.automaticDownloadsAllowed)

                    Text(automaticUpdatesDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Button(aboutUpdateButtonTitle) {
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
                status: feedbackActionStatus,
                isEnabled: true
            ) {
                trackSettingsAction("submit_feedback", page: .support)
                let result = actions.sendFeedback()
                feedbackActionStatus = result.statusMessage
                if result == .unavailable {
                    NSSound.beep()
                }
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
                        .background(buttonBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .foregroundStyle(buttonForeground)
                }
                .buttonStyle(.plain)
                .disabled(!isEnabled)
                .opacity(isEnabled ? 1 : 0.55)

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
        "\(effectiveTranscriptionModel.summary) Audio and transcripts stay local."
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
        HomeTranscriptionActivityPresentation.make(
            sessionState: meetingSession.state,
            displayStatus: meetingSession.displayStatus,
            warmupStatus: meetingSession.warmupStatus,
            lastSavedTitle: meetingSession.lastSavedTitle,
            lastSavedTranscriptURL: meetingSession.lastSavedTranscriptURL
        )
    }

    private var meetingsPageTranscriptionActivity: HomeTranscriptionActivityPresentation? {
        switch meetingSession.displayStatus {
        case .gettingReady, .transcribing, .finishing:
            return homeTranscriptionActivity
        case .idle, .transcriptSaved, .failed:
            return nil
        }
    }

    private func refreshState() {
        refreshPermissions()
        refreshStoragePaths()
        refreshRecentCaptures()
        refreshShortcutState()
        refreshMenuBarVisibility()
        refreshDockVisibility()
        refreshLaunchAtLoginState()
        customDictionaryText = CustomDictionaryPreferences.rawText()
        customDictionaryRows = CorrectionDraftRow.rows(from: customDictionaryText)
        preferredTranscriptionModel = TranscriptionModelPreferences.preferredModel()
        showAdvancedModelControls = preferredTranscriptionModel != TranscriptionModelPreferences.defaultModel
        uiSoundsEnabled = UISoundPreferences.isEnabled()
        refreshAutoEnterPreferences(includeCandidates: navigation.selectedPage == .shortcuts)
        crashReportingEnabled = CrashReportingPreferences.isEnabled()
        anonymousAnalyticsEnabled = AnalyticsPreferences.isEnabled()
        if case .unknown = sparkleUpdater.updateStatus.state {
            sparkleUpdater.refreshUpdateStatus()
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

    private func refreshRecentCaptures() {
        recentCaptureRefreshTask?.cancel()
        recentCaptureRefreshTask = nil
        recentCapturesLoading = false

        switch SettingsRecentCaptureRefreshPolicy.mode(for: navigation.selectedPage) {
        case .homeDashboard:
            homeViewModel.refresh()
            Task { @MainActor in
                await statsService.refreshStats()
            }
        case .recentLists:
            recentCapturesLoading = true
            recentCaptureRefreshTask = Task { @MainActor in
                let snapshot = await RecentCaptureLoader.load(limit: 5)
                guard !Task.isCancelled else { return }
                recentMeetings = snapshot.meetings
                recentDictations = snapshot.dictations
                recentCapturesLoading = false
            }
        case .none:
            break
        }
    }

    private func refreshShortcutState() {
        dictationTriggerSystemWarning = PhysicalDictationTriggerPreferences.functionKeyConflictWarning(
            for: PhysicalDictationTriggerPreferences.pushToTalkBinding()
        )
    }

    private func refreshMenuBarVisibility() {
        menuBarItemVisibility = MenuBarVisibilityPreferences.snapshot()
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
        guard !sample.isEmpty else { return "Dictate a sample phrase above to check your corrections." }

        let entries = CustomDictionaryPreferences.entries(from: customDictionaryText)
        guard !entries.isEmpty else { return sample }
        return CustomDictionaryTextProcessor.apply(to: sample, entries: entries)
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

    private func updatePreferredTranscriptionModel(_ model: TranscriptionModelChoice) {
        preferredTranscriptionModel = model
        showAdvancedModelControls = true
        trackSettingsAction("switch_model", page: .models)
        TranscriptionModelPreferences.setPreferredModel(model)
        Task { @MainActor in
            await sttRouter.initializeSelectedModel()
        }
    }

    private func menuBarVisibilityBinding(for item: MenuBarOptionalItem) -> Binding<Bool> {
        Binding(
            get: { menuBarItemVisibility[item] ?? true },
            set: { newValue in
                menuBarItemVisibility[item] = newValue
                trackSettingsToggle("menu_bar_\(item.analyticsValue)", enabled: newValue, page: .home)
                MenuBarVisibilityPreferences.setVisible(item, newValue)
            }
        )
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
        let preparedURL: URL
        do {
            preparedURL = try TranscriptedStoragePreferences.prepareCaptureLibraryURL(url)
        } catch {
            captureLibraryStatusMessage = error.localizedDescription
            captureLibraryStatusIsError = true
            return
        }

        TranscriptedStoragePreferences.setCaptureLibraryURL(preparedURL)
        refreshStoragePaths()
        captureLibraryStatusMessage = "Capture library updated."
        captureLibraryStatusIsError = false
        AnalyticsReporter.track(
            "settings_capture_library_changed",
            properties: [
                "location_type": isUsingDefaultCaptureLibrary ? "default" : "custom",
                "page_id": TranscriptedSettingsPage.storage.analyticsValue,
            ]
        )
    }

    private func resetCaptureLibraryToDefault() {
        let oldURL = captureLibraryURL.standardizedFileURL

        if !isUsingDefaultCaptureLibrary {
            switch confirmDefaultCaptureLibraryReset(oldURL: oldURL) {
            case .reset:
                break
            case .cancel:
                return
            case .revealOldFolder:
                revealCaptureLibrary(oldURL)
                captureLibraryStatusMessage = "Old capture folder revealed. Capture library unchanged."
                captureLibraryStatusIsError = false
                return
            }
        }

        TranscriptedStoragePreferences.setCaptureLibraryURL(nil)
        refreshStoragePaths()
        captureLibraryStatusMessage = "Capture library reset to the default folder. Existing captures stayed in the old folder."
        captureLibraryStatusIsError = false
        AnalyticsReporter.track(
            "settings_capture_library_changed",
            properties: [
                "location_type": "default",
                "page_id": TranscriptedSettingsPage.storage.analyticsValue,
            ]
        )
    }

    private enum CaptureLibraryResetChoice {
        case reset
        case cancel
        case revealOldFolder
    }

    private func confirmDefaultCaptureLibraryReset(oldURL: URL) -> CaptureLibraryResetChoice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Reset capture library to the default folder?"
        alert.informativeText = """
        Future captures will go to the default location. Existing captures in \(oldURL.path) will stay there.

        Do you want to continue?
        """
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Reveal Old Folder")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .reset
        case .alertThirdButtonReturn:
            return .revealOldFolder
        default:
            return .cancel
        }
    }

    private func revealCaptureLibrary(_ url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
        }
    }

    private var sortedAutoEnterAllowedBundleIDs: [String] {
        autoEnterAllowedBundleIDs.sorted { lhs, rhs in
            autoEnterDisplayName(for: lhs).localizedCaseInsensitiveCompare(autoEnterDisplayName(for: rhs)) == .orderedAscending
        }
    }

    private func setAutoEnterApp(_ bundleID: String, isAllowed: Bool) {
        if isAllowed {
            autoEnterAllowedBundleIDs.insert(bundleID)
        } else {
            autoEnterAllowedBundleIDs.remove(bundleID)
        }
        trackSettingsToggle("auto_send_app_allowed", enabled: isAllowed, page: .shortcuts)
        DictationAutoSendPreferences.setAllowedBundleIDs(autoEnterAllowedBundleIDs)
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

    private func chooseAutoEnterApp() {
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

        setAutoEnterApp(bundleID, isAllowed: true)
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

    private func copyMeetingForAgent(_ item: RecentMeetingItem) {
        guard let bundle = AgentConnectionGuide.portableMeetingBundle(
            title: item.title,
            date: item.date,
            transcriptURL: item.transcriptURL
        ) else {
            NSSound.beep()
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(bundle, forType: .string)
        copiedAgentMeetingID = item.id

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: MenuTokens.compactCopyFeedbackDurationNanoseconds)
            if copiedAgentMeetingID == item.id {
                copiedAgentMeetingID = nil
            }
        }
    }

    private func openMeetingsFolder() {
        let folder = MeetingStoragePaths.transcriptsFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    private func copyPath(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.path, forType: .string)
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

            TextField("OKRs", text: $replacement)
                .textFieldStyle(.roundedBorder)

            Button(role: .destructive, action: onRemove) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
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

            Button("Remove", action: remove)
        }
    }
}

private struct SettingsRecentMeetingRow: View {
    let item: RecentMeetingItem
    let detail: String
    let isCopied: Bool
    let openAction: () -> Void
    let revealAction: () -> Void
    let copyPathAction: () -> Void
    let copyForAgentAction: () -> Void
    @ObservedObject private var playback = MeetingAudioPlayback.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: openAction) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.primary)

                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 12)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help("Click to open. Right-click for more.")
            .contextMenu {
                Button("Open Transcript", action: openAction)
                Button("Reveal in Finder", action: revealAction)
                Button("Copy Path", action: copyPathAction)
                Divider()
                Button(isCopied ? "Copied for Agent" : "Copy for Agent", action: copyForAgentAction)
            }

            HStack(spacing: 10) {
                if let audio = item.audio {
                    SettingsRecentMeetingAudioControl(
                        title: playback.buttonTitle(for: audio),
                        symbolName: playback.symbolName(for: audio),
                        isActive: playback.isActive(audio),
                        isPlaying: playback.isPlaying && playback.isActive(audio)
                    ) {
                        playback.toggle(audio)
                    }
                    .help("\(playback.buttonTitle(for: audio)) meeting audio")
                }

                Button {
                    copyForAgentAction()
                } label: {
                    Label(isCopied ? "Copied" : "Copy for Agent", systemImage: isCopied ? "checkmark" : "sparkles")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
}

private struct SettingsRecentMeetingAudioControl: View {
    let title: String
    let symbolName: String
    let isActive: Bool
    let isPlaying: Bool
    let action: () -> Void

    var body: some View {
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
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(stroke, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
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
    let retryAction: () -> Void
    let secondaryAction: () -> Void

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

            if item.isRetryable || item.isRetrying {
                Button {
                    retryAction()
                } label: {
                    Label(item.isRetrying ? "Retrying..." : "Retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!item.isRetryable || item.isRetrying)
            }

            Button(role: item.hasAudioFiles ? .destructive : nil) {
                secondaryAction()
            } label: {
                Label(item.hasAudioFiles ? "Delete" : "Dismiss", systemImage: item.hasAudioFiles ? "trash" : "xmark")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
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
                summary: "Pick one."
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
                DisclosureGroup("Show setup details", isExpanded: $showAdvancedAgentSetup) {
                    VStack(alignment: .leading, spacing: 14) {
                        ClaudeDesktopStatusRow(status: claudeDesktopStatus)

                        HStack(spacing: 10) {
                            Button {
                                copyText(
                                    ClaudeDesktopIntegrationInstaller.configSnippet(),
                                    showingCopiedFeedback: $copiedClaudeDesktopConfig
                                )
                            } label: {
                                Label(copiedClaudeDesktopConfig ? "Copied" : "Copy Claude Config", systemImage: "doc.on.doc")
                            }
                            .buttonStyle(.bordered)

                            Button {
                                revealClaudeDesktopConfig()
                            } label: {
                                Label("Show Config", systemImage: "folder")
                            }
                            .buttonStyle(.bordered)
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
                                Button {
                                    copyText(
                                        AgentConnectionGuide.folderAccessPrompt,
                                        showingCopiedFeedback: $copiedFolderPrompt
                                    )
                                } label: {
                                    Label(copiedFolderPrompt ? "Copied" : "Copy Folder Prompt", systemImage: "doc.on.doc")
                                }
                                .buttonStyle(.bordered)

                                Button {
                                    copyText(
                                        AgentConnectionGuide.folderPathsText,
                                        showingCopiedFeedback: $copiedFolderPaths
                                    )
                                } label: {
                                    Label(copiedFolderPaths ? "Copied" : "Copy Paths", systemImage: "folder")
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                    .padding(.top, 10)
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
                Button {
                    openClaudeDesktopDownload()
                } label: {
                    Label("Get Claude Desktop", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
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
            try? await Task.sleep(nanoseconds: MenuTokens.copyFeedbackDurationNanoseconds)
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

    @State private var isHovered = false

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
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(isHovered && isEnabled ? 0.95 : 0.78))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(tint.opacity(isHovered && isEnabled ? 0.56 : 0.28), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(isEnabled ? 1.0 : 0.72)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovered = $0 }
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

            Button("Reveal", action: action)
                .buttonStyle(.bordered)
                .disabled(!isAvailable)
        }
    }
}
