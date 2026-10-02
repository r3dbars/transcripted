import AppKit
import Observation
import SwiftUI
import TranscriptedCore
import UniformTypeIdentifiers

struct TranscriptedSettingsView: View {
    @Bindable var navigation: TranscriptedSettingsNavigationModel
    @ObservedObject var speakerPeopleModel: SpeakerPeopleSettingsViewModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ObservedObject var sttRouter: STTRouter
    @ObservedObject var meetingSession: MeetingSessionController
    @ObservedObject var sparkleUpdater: SparkleUpdaterController

    let actions: TranscriptedSettingsActions
    private let appLogger: AppLogSink
    let writingController: WritingController

    @State var dictationTriggerSystemWarning = PhysicalDictationTriggerPreferences.functionKeyConflictWarning(
        for: PhysicalDictationTriggerPreferences.pushToTalkBinding()
    )
    @State var dictationShortcutsEnabled = HotkeyPreferences.dictationShortcutsEnabled()
    @State var showTranscriptedInDock = DockVisibilityPreferences.isVisible()
    @State var launchAtLogin = LaunchAtLoginController.currentState
    @State var launchAtLoginReadGeneration = 0
    @State var launchAtLoginFailureMessage: String?
    @State var showCorrectionsSheet = false
    /// Section id the combined settings page should scroll to on next render
    /// (set by Home attention deep-links); cleared after the scroll fires.
    @State var settingsScrollTargetID: String?
    @State var customDictionaryText = CustomDictionaryPreferences.rawText()
    @State var customDictionaryRows = CorrectionDraftRow.rows(from: CustomDictionaryPreferences.rawText())
    @State var customDictionaryPreviewInput = ""
    @State var showCorrectionPreview = false
    @State var dictationCleanupEnabled = DictationCleanupPreferences.isEnabled()
    @State var showAdvancedCorrectionsText = false
    @StateObject var pastMeetingsModel = DictionaryPastMeetingsModel()
    @State var pastMeetingsFixConfirmation: DictionaryPastMeetingsRow?
    @State var preferredTranscriptionModel = TranscriptionModelPreferences.preferredModel()
    @State var preferredSpeakerEmbedder = SpeakerEmbedderPreferences.preferredChoice()
    @State var showSpeakerEmbedderSwitchConfirm = false
    @State var showClearCorrectionsConfirm = false
    @State var uiSoundsEnabled = UISoundPreferences.isEnabled()
    @State var autoEnterEnabled = DictationAutoSendPreferences.isEnabled()
    @State var keepRecommendedMicrophoneActive = DictationPersistentInputPreferences.isEnabled()
    @State var preferredDictationInputUID = DictationPersistentInputPreferences.preferredDeviceUID()
    // The Mac mic recorder switch is set outside the app, so this is read
    // with the other settings rather than observed.
    @State var pinnedMicrophoneRecorderOn = PinnedMicrophoneCapturePreferences.isEnabled()
    @State var microphoneChoice = MicrophoneChoicePreferences.choice()
    @State var availableDictationInputs = (try? CoreAudioInputDeviceLookup.availableInputDevices()) ?? []
    @State var autoEnterKey = DictationAutoSendPreferences.sendKey()
    @State var autoEnterAllowedBundleIDs = DictationAutoSendPreferences.allowedBundleIDs()
    @State var autoEnterAppCandidates: [AutoEnterAppCandidate] = []
    @State var crashReportingEnabled = CrashReportingPreferences.isEnabled()
    @State var anonymousAnalyticsEnabled = AnalyticsPreferences.isEnabled()
    @State var diagnosticsActionStatus: String?
    @State var diagnosticEventSendInFlight = false
    @State var permissionStates = PermissionSnapshot.current()
    @State var permissionRevalidationTask: Task<Void, Never>?
    @State var captureLibraryURL = FileManager.default.transcriptedCaptureLibraryDir
    @State var unavailableCaptureLibraryPath = TranscriptedStoragePreferences.unavailableCustomCaptureLibraryPath()
    @State var pendingCaptureLibraryChoice: PendingCaptureLibraryChoice?
    @State var captureLibraryMigrationInProgress = false
    @State var captureLibraryMigrationStatus: String?
    @State var homeDashboardRefreshTask: Task<Void, Never>?
    @State var homeDashboardRefreshInFlight = false
    @State var homeDashboardRefreshGeneration = SupersessionEpoch()
    @State var lastHomeDashboardRefreshStartedAt: Date?
    @State var modelCacheSnapshot: ModelCacheSnapshot?
    @State var modelCacheLoading = false
    @State var modelCacheCleanupInProgress = false
    @State var modelCacheCleanupStatus: String?
    @State var meetingMicProcessingMode = MicrophoneProcessingPreferences.mode()
    @State var showsMicBoostMigrationNote = MicrophoneProcessingPreferences.showsBoostMigrationNote()
    @State var micBoostHintsHiddenThrough = MicrophoneProcessingPreferences.micBoostHintsHiddenThrough()
    @State var useSystemMeetingMicrophone = MeetingMicrophonePreferences.usesSystemInput()
    @State var splitLocalSpeakersEnabled = LocalSpeakerPreferences.isEnabled()
    @State var autoDetectCallsEnabled = AutoCallDetectionPreferences.isEnabled()
    @State var audioRetentionWindow = AudioStoragePreferences.deleteAudioAfter()
    @StateObject var homeViewModel = HomeViewModel()
    @StateObject var todayViewModel = TodayViewModel()
    @State var homeCopiedRowID: String?
    @State var homeDeleteConfirmation: HomeDeleteConfirmation?
    @State var homeDeleteFailure: HomeDeleteFailure?
    @State private var homeFeedbackTarget: HomeFeedbackTarget?
    @State var homeFindIsVisible = false
    /// True while a footer-initiated update check is in flight or its
    /// "You're up to date" answer is lingering.
    @State var footerVersionCheckActive = false
    @State var homeFindConsumedFocusToken = 0
    @State var homeRevealConsumedToken = 0
    /// A meeting the pill's Open asked Home to expand, waiting for it to
    /// appear in the loaded list.
    @State var homePendingRevealMeetingKey: String?
    @State var homeFindFieldFocusToken = 0
    @State var homeExpandedMeetingID: String?
    @State var homeExpandedMeetingPreview: HomeMeetingPreview?
    @ObservedObject var captureUndo = CaptureUndoManager.shared
    @State private var homeMeetingDeletionIDs: Set<String> = []
    @State var homeMeetingSearchQuery = ""
    @State var homeMeetingPreviewLoadTask: Task<Void, Never>?
    @State var modelCacheCleanupStatusDetails: String?
    @State var captureLibraryMigrationStatusDetails: String?
    @State var speakerInboxScrollRequest = 0
    @State var speakerInboxScrollAwaitingQueue = false

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
        self.writingController = appState.writingController
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
            if let alert = meetingSession.artifactRecoveryAlert {
                handleMeetingArtifactRecoveryAlert(alert)
            }
            refreshState()
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
            let isPresentationSelectionChange = page == navigation.presentedPage
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
        .onReceive(meetingSession.$artifactRecoveryAlert) { alert in
            guard let alert else { return }
            handleMeetingArtifactRecoveryAlert(alert)
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
            // The Home row's "Boost mic next meeting" action and the launch
            // migration change these outside Settings; keep an open window in sync.
            meetingMicProcessingMode = MicrophoneProcessingPreferences.mode()
            showsMicBoostMigrationNote = MicrophoneProcessingPreferences.showsBoostMigrationNote()
            micBoostHintsHiddenThrough = MicrophoneProcessingPreferences.micBoostHintsHiddenThrough()
        }
        .onReceive(NotificationCenter.default.publisher(for: .meetingMicrophonePreferenceChanged)) { _ in
            useSystemMeetingMicrophone = MeetingMicrophonePreferences.usesSystemInput()
        }
        .onReceive(NotificationCenter.default.publisher(for: .transcriptedPermissionsDidChange)) { _ in
            refreshPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
            refreshRecentCaptures()
            refreshShortcutState()
            // Coming back from Login Items should clear a stale approval or
            // failure line.
            refreshLaunchAtLoginState()
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

    func scrollToSpeakerInbox(using proxy: ScrollViewProxy) {
        Task { @MainActor in
            await Task.yield()
            withAnimation(.snappy(duration: 0.22)) {
                proxy.scrollTo(SpeakerPeopleSettingsSection.ScrollTarget.reviewQueue, anchor: .top)
            }
        }
    }

    func handleCopyDictation(_ entry: SavedDictationEntry) {
        trackSettingsAction("copy_dictation", page: .home)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.text, forType: .string)
        flashCopied(rowID: entry.id)
    }

    func handleCopyMeeting(_ item: RecentMeetingItem) {
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
        guard let input = item.audio?.retranscriptionInput else {
            presentHomeActionFailure(
                title: "Could not re-transcribe meeting",
                message: "Transcripted couldn't find this meeting's audio. It may have been moved, or deleted by the Delete meeting audio after setting.",
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
                    message: "Transcripted couldn't re-transcribe this meeting's audio. The saved files may be incomplete or already in use.",
                    retry: {
                        handleRetranscribeMeeting(item)
                    }
                )
            }
        }
    }

    /// Expand a capture in place (quiet-library interaction). Clicking the
    /// same row again, pressing Esc, or expanding another row collapses it.
    func toggleHomeMeetingExpansion(_ item: RecentMeetingItem) {
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

    func collapseHomeMeetingExpansion() {
        homeMeetingPreviewLoadTask?.cancel()
        MeetingAudioPlayback.shared.stop()
        withAnimation(.snappy(duration: 0.22)) {
            homeExpandedMeetingID = nil
        }
        homeExpandedMeetingPreview = nil
    }

    static func readMeetingMarkdown(at url: URL) async -> HomeMeetingMarkdownReadResult {
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
            appVersion: TranscriptedAppVersion.description,
            includeDiagnostics: submission.includeDiagnostics
        )

        let url = FeedbackIssueBuilder.emailURL(
            report: report,
            rawLogLines: submission.includeDiagnostics ? appLogger.entries : nil
        )
        if SupportEmailDispatcher.open(url) {
            homeFeedbackTarget = nil
        }
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

    func dictationRowMenuItems(for entry: SavedDictationEntry) -> [HomeRowMenuItem] {
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

    func meetingRowMenuItems(for item: RecentMeetingItem) -> [HomeRowMenuItem] {
        var items: [HomeRowMenuItem] = []
        let hasPendingSpeakerReview = hasSpeakerReviewWork(for: item)

        items.append(contentsOf: [
            HomeRowMenuItem(
                title: HomeMeetingRenameAffordance.title,
                symbolName: HomeMeetingRenameAffordance.symbolName,
                automationIdentifier: HomeMeetingRenameAffordance.automationIdentifier
            ) {
                promptRenameMeeting(item)
            },
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
            meetingDate: item.date,
            voiceProcessingPreferenceEnabled: meetingMicProcessingMode.usesAppleVoiceProcessing,
            hintsHiddenThrough: micBoostHintsHiddenThrough
        ) {
            items.append(
                HomeRowMenuItem(title: "Boost mic next meeting", symbolName: "mic.badge.plus") {
                    // One meeting only, like the in-meeting Boost Mic prompt.
                    trackSettingsToggle("meeting_mic_boost_next_meeting", enabled: true, page: .home)
                    MicrophoneProcessingPreferences.requestBoostForNextMeeting()
                    micBoostHintsHiddenThrough = MicrophoneProcessingPreferences.micBoostHintsHiddenThrough()
                }
            )
        }

        if let audio = item.audio {
            let audioRevealURLs = HomeMeetingRowActionTargets.audioRevealURLs(for: item)
            if !audioRevealURLs.isEmpty {
                if audio.retranscriptionInput != nil {
                    items.append(
                        HomeRowMenuItem(
                            title: RecentMeetingRetranscriptionMenuActionPolicy.title(
                                globalUnavailableReason: savedMeetingRetranscriptionUnavailableReason
                            ),
                            symbolName: "person.2.fill",
                            isEnabled: RecentMeetingRetranscriptionMenuActionPolicy.isEnabled(
                                globalUnavailableReason: savedMeetingRetranscriptionUnavailableReason
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
    /// Planning and Trash share the transcript writer's serializer, off the
    /// main actor, so an in-flight rewrite cannot resurrect a deleted meeting.
    private func deleteMeetingWithUndo(_ item: RecentMeetingItem) {
        guard !captureUndo.isPending(item.id),
              homeMeetingDeletionIDs.insert(item.id).inserted else { return }
        if homeExpandedMeetingID == item.id {
            collapseHomeMeetingExpansion()
        }
        if let audio = item.audio {
            MeetingAudioPlayback.shared.stopIfActive(attachmentIDs: [audio.id])
        }
        Task { @MainActor in
            defer { homeMeetingDeletionIDs.remove(item.id) }
            do {
                let payload = try await Task.detached(priority: .userInitiated) {
                    try HomeMeetingDeletion.trash(item)
                }.value
                MeetingAudioPlayback.shared.stopIfActive(attachmentIDs: Set(payload.plan.audioAttachmentIDs))
                captureUndo.stage(
                    id: item.id,
                    message: CaptureUndoMessage.deleted(item.title),
                    undoAction: {
                        Task { @MainActor in
                            await Task.detached(priority: .userInitiated) {
                                HomeMeetingDeletion.restore(payload)
                            }.value
                            refreshRecentCaptures(force: true)
                        }
                    },
                    finalize: {
                        refreshRecentCaptures(force: true)
                        // A deleted meeting must not live on as a dictionary-fix backup.
                        let deletedTranscripts = payload.plan.transcriptURLs
                        Task.detached(priority: .utility) {
                            DictionaryPastMeetingBackupStore.default().removeBackups(forMeetingsAt: deletedTranscripts)
                        }
                    }
                )
                trackSettingsAction("delete_meeting_confirm", page: .home)
            } catch let error as HomeMeetingDeletionError {
                refreshRecentCaptures(force: true)
                presentHomeActionFailure(
                    title: "Could not delete meeting",
                    message: error.localizedDescription,
                    retryTitle: "Refresh meetings",
                    retry: { refreshRecentCaptures(force: true) }
                )
            } catch {
                presentHomeDeleteFailure(
                    title: "Could not delete meeting",
                    error: error,
                    retry: { deleteMeetingWithUndo(item) }
                )
            }
        }
    }
}

// User-facing copy for the "we can't find this artifact on disk" failures that
// several Settings actions surface. Centralized so the identical strings are
// not re-typed at each call site and can't drift apart.
enum SettingsArtifactMessage {
    static let meetingTranscriptNotFound =
        "Transcripted couldn't find this meeting's transcript on disk. It may have been moved, renamed, or deleted outside the app."
    static let dictationFileNotFound =
        "Transcripted couldn't find this dictation's file on disk. It may have been moved, renamed, or deleted outside the app."
    static let meetingRetainedAudioNotFound =
        "Transcripted couldn't find this meeting's audio on disk. It may have been moved, or deleted by the Delete meeting audio after setting."
}
