import AppKit
import Observation
import SwiftUI
import TranscriptedCore

struct TranscriptedSettingsView: View {
    @Bindable var navigation: TranscriptedSettingsNavigationModel
    @ObservedObject var speakerPeopleModel: SpeakerPeopleSettingsViewModel
    @ObservedObject private var parakeetEngine: ParakeetEngine
    @ObservedObject private var meetingSession: MeetingSessionController
    @ObservedObject private var sparkleUpdater: SparkleUpdaterController

    private let actions: TranscriptedSettingsActions

    @State private var rightOptionEnabled = HotkeyPreferences.rightOptionDictationEnabled()
    @State private var uiSoundsEnabled = UISoundPreferences.isEnabled()
    @State private var crashReportingEnabled = CrashReportingPreferences.isEnabled()
    @State private var anonymousAnalyticsEnabled = AnalyticsPreferences.isEnabled()
    @State private var sentryTestStatus: String?
    @State private var permissionStates = PermissionSnapshot.current()
    @State private var captureLibraryURL = FileManager.default.transcriptedCaptureLibraryDir
    @State private var recentMeetings = RecentMeetingsScanner.loadRecent(limit: 5)
    @State private var recentDictations = DictationTranscriptStore.recentSavedDictations(limit: 5)
    @State private var showSupportFolders = false
    @State private var copiedAgentMeetingID: String?

    init(
        appState: TranscriptedAppState,
        navigation: TranscriptedSettingsNavigationModel,
        speakerPeopleModel: SpeakerPeopleSettingsViewModel,
        actions: TranscriptedSettingsActions
    ) {
        self.navigation = navigation
        self.speakerPeopleModel = speakerPeopleModel
        self.actions = actions
        _parakeetEngine = ObservedObject(wrappedValue: appState.sttRouter.parakeetEngine)
        _meetingSession = ObservedObject(wrappedValue: appState.meetingSession)
        _sparkleUpdater = ObservedObject(wrappedValue: appState.sparkleUpdater)
    }

    var body: some View {
        NavigationSplitView {
            List(TranscriptedSettingsPage.allCases, selection: $navigation.selectedPage) { page in
                Label(page.title, systemImage: page.systemImage)
                    .tag(page)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    Divider()
                    HStack {
                        Text(TranscriptedSupportActions.appVersionDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
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
                    .padding(28)
                    .frame(maxWidth: 860, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(minWidth: 880, minHeight: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: refreshState)
        .task(id: navigation.presentationID) {
            refreshState()
        }
        .onChange(of: navigation.selectedPage) { _, _ in
            refreshRecentCaptures()
        }
        .onChange(of: meetingSession.lastSavedTranscriptURL) { _, _ in
            refreshRecentCaptures()
        }
    }

    @ViewBuilder
    private var pageBody: some View {
        switch navigation.selectedPage {
        case .home:
            homePage
        case .shortcuts:
            shortcutsPage
        case .meetings:
            meetingsPage
        case .dictations:
            dictationsPage
        case .storage:
            storagePage
        case .connectAgent:
            connectAgentPage
        case .privacy:
            privacyPage
        case .about:
            aboutPage
        }
    }

    private var homePage: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsPageIntro(
                title: "Home",
                summary: "Start recording quickly, import audio files, and see what still needs setup."
            )

            let columns = [
                GridItem(.flexible(minimum: 220), spacing: 14),
                GridItem(.flexible(minimum: 220), spacing: 14)
            ]

            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                SettingsActionTile(
                    symbolName: "mic.fill",
                    title: "Start Dictation",
                    detail: "Turn speech into text in the app you were just using.",
                    tone: .accent,
                    action: actions.startDictation
                )

                SettingsActionTile(
                    symbolName: "record.circle.fill",
                    title: "Start Meeting",
                    detail: "Capture your mic and meeting audio together.",
                    tone: .accent,
                    action: actions.startMeeting
                )

                SettingsActionTile(
                    symbolName: "waveform",
                    title: "Transcribe Audio File",
                    detail: "Import an existing recording and run it through the meeting pipeline.",
                    action: actions.importAudioFile
                )

                SettingsActionTile(
                    symbolName: "sparkles",
                    title: "Connect Your Agent",
                    detail: "Copy the main prompt or set up MCP when you want a deeper connection.",
                    action: {
                        navigation.selectedPage = .connectAgent
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
                            NSWorkspace.shared.open(transcriptURL)
                        }
                    }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            SettingsSection(
                title: "Setup Status",
                detail: "These cards show whether Transcripted is ready for dictation, meetings, and local storage."
            ) {
                let modelCard = FirstRunExperience.modelCard(for: FirstRunLocalModelState(parakeetEngine.modelDownloadState))

                SettingsStatusCard(
                    title: "Local voice model",
                    status: modelCard.status,
                    detail: modelCard.detail,
                    tone: tone(for: modelCard.tone)
                )

                SettingsStatusCard(
                    title: "Meeting tools",
                    status: meetingSession.warmupStatus.subtitle,
                    detail: meetingSession.warmupStatus.detail.isEmpty
                        ? "Meeting capture and imported audio transcription share the same local setup."
                        : meetingSession.warmupStatus.detail,
                    tone: meetingSession.warmupStatus == .ready ? .ready : .working
                )

                SettingsStatusCard(
                    title: "Permissions",
                    status: permissionsStatusLine,
                    detail: permissionsDetailLine,
                    tone: missingRequiredPermissions.isEmpty ? .ready : .caution
                )

                SettingsStatusCard(
                    title: "Capture library",
                    status: isUsingDefaultCaptureLibrary ? "Default location" : "Custom location",
                    detail: (captureLibraryURL.path as NSString).abbreviatingWithTildeInPath,
                    tone: .ready
                )
            }

            SettingsSection(
                title: "What To Adjust Next",
                detail: "These are the pages most people look at after the first successful recording."
            ) {
                SettingsQuickLinkRow(
                    symbolName: "keyboard",
                    title: "Shortcuts",
                    detail: "Change the global keys Transcripted listens for."
                ) {
                    navigation.selectedPage = .shortcuts
                }

                SettingsQuickLinkRow(
                    symbolName: "person.2.wave.2.fill",
                    title: "Meetings",
                    detail: "Import audio files and tune speaker matching."
                ) {
                    navigation.selectedPage = .meetings
                }

                SettingsQuickLinkRow(
                    symbolName: "lock.shield.fill",
                    title: "Privacy",
                    detail: "Review permissions, crash reporting, and anonymous analytics."
                ) {
                    navigation.selectedPage = .privacy
                }
            }
        }
        .animation(.snappy(duration: 0.22), value: homeTranscriptionActivity)
    }

    private var shortcutsPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsPageIntro(
                title: "Shortcuts",
                summary: "Choose the keyboard triggers Transcripted listens for anywhere on your Mac."
            )

            SettingsSection(
                title: "Keyboard Shortcuts",
                detail: "Set one shortcut for dictation and one for meetings. Transcripted applies them immediately."
            ) {
                HotkeyRecorderContainer()
                    .frame(height: 76)

                Toggle("Tap the right Option key to start dictation", isOn: Binding(
                    get: { rightOptionEnabled },
                    set: { newValue in
                        rightOptionEnabled = newValue
                        HotkeyPreferences.setRightOptionDictation(enabled: newValue)
                    }
                ))

                Text(rightOptionEnabled
                    ? "A quick tap of the right Option key will also start dictation."
                    : "Dictation will only use the configured keyboard shortcut."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var meetingsPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsPageIntro(
                title: "Meetings",
                summary: "Control how Transcripted records meetings, imports audio files, and keeps speaker matching tidy."
            )

            SettingsSection(
                title: "Meeting Actions",
                detail: "Meetings can start live from your Mac or from an audio file you already recorded."
            ) {
                SettingsQuickLinkRow(
                    symbolName: "record.circle.fill",
                    title: "Start Meeting",
                    detail: "Begin capturing your microphone and system audio together."
                ) {
                    actions.startMeeting()
                }

                SettingsQuickLinkRow(
                    symbolName: "waveform",
                    title: "Transcribe Audio File",
                    detail: "Import a saved audio file and run it through the meeting transcription pipeline."
                ) {
                    actions.importAudioFile()
                }

                Text("If a meeting action is blocked, check Privacy for microphone or system audio permissions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SettingsSection(
                title: "Recent Meetings",
                detail: "Open one of the last five saved meeting transcripts without digging through folders."
            ) {
                if recentMeetings.isEmpty {
                    Text("No meeting transcripts saved yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(recentMeetings) { item in
                        SettingsRecentMeetingRow(
                            item: item,
                            detail: formattedRecentDate(item.date),
                            isCopied: copiedAgentMeetingID == item.id,
                            openAction: {
                                NSWorkspace.shared.open(item.transcriptURL)
                            },
                            copyForAgentAction: {
                                copyMeetingForAgent(item)
                            }
                        )
                    }
                }
            }

            SpeakerPeopleSettingsSection(model: speakerPeopleModel)
        }
    }

    private var dictationsPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsPageIntro(
                title: "Dictations",
                summary: "Control what happens after dictation finishes, including sound cues and pasting the latest saved dictation."
            )

            SettingsSection(
                title: "Dictation Actions",
                detail: "Use the latest saved dictation again without starting a new recording."
            ) {
                SettingsQuickLinkRow(
                    symbolName: "arrow.turn.down.right",
                    title: "Paste Last Dictation",
                    detail: "Paste the newest saved dictation into the app you were just using."
                ) {
                    actions.pasteLastDictation()
                }

                Text("Transcripted uses Accessibility to paste automatically. If that is unavailable, it falls back to copying the text.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SettingsSection(
                title: "Recent Dictations",
                detail: "These are the newest saved dictations from the last few days. Opening one jumps to the markdown file for that day."
            ) {
                if recentDictations.isEmpty {
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
                            NSWorkspace.shared.open(item.url)
                        }
                    }
                }
            }

            SettingsSection(
                title: "Feedback Sounds",
                detail: "Use quiet system sounds to confirm what happened after dictation starts or finishes."
            ) {
                Toggle("Play dictation feedback sounds", isOn: Binding(
                    get: { uiSoundsEnabled },
                    set: { newValue in
                        uiSoundsEnabled = newValue
                        UISoundPreferences.setEnabled(newValue)
                    }
                ))

                Text(uiSoundsEnabled
                    ? "Transcripted will play subtle sounds when dictation starts, stops, completes, or ends with no speech."
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
                summary: "Choose where captures live while keeping app-owned state, logs, and temporary files separate."
            )

            SettingsSection(
                title: "Capture Library",
                detail: "This is the main folder for the markdown files you may want to open yourself or hand to an agent later."
            ) {
                StorageRow(title: "Capture library", url: captureLibraryURL)
                StorageRow(title: "Meeting captures", url: MeetingStoragePaths.transcriptsFolder)
                StorageRow(title: "Dictation captures", url: DictationStoragePaths.transcriptsFolder)

                HStack {
                    Button("Choose Capture Library") {
                        chooseCaptureLibrary()
                    }

                    Button("Reset to Default") {
                        TranscriptedStoragePreferences.setCaptureLibraryURL(nil)
                        refreshStoragePaths()
                    }
                }

                Text("Choose a folder like an Obsidian vault if you want agents to read the raw Markdown captures directly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SettingsSection(
                title: "Support Folders",
                detail: "These folders are usually only useful when troubleshooting, inspecting logs, or cleaning up storage."
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
                summary: "Review the permissions Transcripted needs and choose whether optional reporting leaves this Mac."
            )

            SettingsSection(
                title: "Permissions",
                detail: "Transcripted only asks for permissions that help with local capture, paste-back, and optional meeting prompts."
            ) {
                ForEach(TranscriptedPermissionKind.allCases) { kind in
                    PermissionStatusRow(kind: kind, granted: permissionStates[kind] ?? false) {
                        TranscriptedPermissionAccess.openSettings(for: kind)
                        refreshPermissions()
                    }
                }
            }

            SettingsSection(
                title: "Optional Reporting",
                detail: "Crash reports and anonymous usage statistics stay separate, scoped, and scrubbed before anything leaves this Mac."
            ) {
                Toggle("Send crash and error reports", isOn: Binding(
                    get: { crashReportingEnabled },
                    set: { newValue in
                        crashReportingEnabled = newValue
                        CrashReportingPreferences.setEnabled(newValue)
                        sentryTestStatus = nil
                    }
                ))
                .disabled(!CrashReporter.isAvailable)

                Toggle("Send anonymous usage statistics", isOn: Binding(
                    get: { anonymousAnalyticsEnabled },
                    set: { newValue in
                        anonymousAnalyticsEnabled = newValue
                        AnalyticsPreferences.setEnabled(newValue)
                    }
                ))
                .disabled(!AnalyticsReporter.isAvailable)

                HStack {
                    Button("Send Test Sentry Event") {
                        sendTestSentryEvent()
                    }
                    .disabled(!CrashReporter.isAvailable || !crashReportingEnabled)

                    if let sentryTestStatus {
                        Text(sentryTestStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Text("Transcripted never sends transcript text, audio, meeting titles, speaker names, source app names, emails, file paths, or raw URLs through either path.")
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
                summary: "Transcripted is a local-first Mac app for dictation, meetings, and clean Markdown exports."
            )

            SettingsSection(
                title: "Version",
                detail: "Build info and update controls live here."
            ) {
                SettingsStatusCard(
                    title: "Transcripted",
                    status: TranscriptedSupportActions.appVersionDescription,
                    detail: "Updates are delivered through Sparkle when the appcast is current and automatic checks are enabled.",
                    tone: .ready
                )

                SettingsStatusCard(
                    title: "Updates",
                    status: aboutUpdateStatusTitle,
                    detail: aboutUpdateStatusDetail,
                    tone: aboutUpdateStatusTone
                )

                HStack {
                    Button(aboutUpdateButtonTitle) {
                        actions.checkForUpdates()
                    }
                    .disabled(!sparkleUpdater.updateStatus.canCheckForUpdates)

                    Button("Submit Feedback") {
                        actions.sendFeedback()
                    }
                }
            }
        }
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
            return "Microphone and Accessibility are on. Optional meeting permissions can be adjusted any time."
        }
        return "Turn on \(missingRequiredPermissions.map(\.title).joined(separator: " and ")) so Transcripted can record and paste back reliably."
    }

    private var isUsingDefaultCaptureLibrary: Bool {
        captureLibraryURL.standardizedFileURL == FileManager.default.transcriptedDefaultCaptureLibraryDir.standardizedFileURL
    }

    private var crashReportingFootnote: String {
        if CrashReporter.isAvailable {
            return crashReportingEnabled
                ? "Enabled. Transcripted will send scrubbed crash and error data to Sentry so reliability issues are easier to diagnose."
                : "Off. Transcripted will keep crash and error details on this Mac only."
        }
        return "This build does not have a Sentry DSN configured yet, so crash and error reporting stay local."
    }

    private var analyticsFootnote: String {
        if AnalyticsReporter.isAvailable {
            return anonymousAnalyticsEnabled
                ? "Enabled. Transcripted sends only allowlisted anonymous product events such as launches, dictation completions, and meeting workflow milestones."
                : "Off. Transcripted will not send anonymous usage statistics unless you turn this back on."
        }
        return "This build does not have a PostHog project key configured yet, so anonymous usage statistics stay disabled."
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

    private func refreshState() {
        refreshPermissions()
        refreshStoragePaths()
        refreshRecentCaptures()
        rightOptionEnabled = HotkeyPreferences.rightOptionDictationEnabled()
        uiSoundsEnabled = UISoundPreferences.isEnabled()
        crashReportingEnabled = CrashReportingPreferences.isEnabled()
        anonymousAnalyticsEnabled = AnalyticsPreferences.isEnabled()
        if case .unknown = sparkleUpdater.updateStatus.state {
            sparkleUpdater.refreshUpdateStatus()
        }
    }

    private func refreshPermissions() {
        permissionStates = PermissionSnapshot.current()
    }

    private func refreshStoragePaths() {
        captureLibraryURL = FileManager.default.transcriptedCaptureLibraryDir
    }

    private func refreshRecentCaptures() {
        recentMeetings = RecentMeetingsScanner.loadRecent(limit: 5)
        recentDictations = DictationTranscriptStore.recentSavedDictations(limit: 5)
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

    private func chooseCaptureLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Select the folder Transcripted should use as its capture library."
        panel.directoryURL = captureLibraryURL

        guard panel.runModal() == .OK, let url = panel.url else { return }
        TranscriptedStoragePreferences.setCaptureLibraryURL(url)
        refreshStoragePaths()
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
            return "Update available (\(version))"
        }
    }

    private var aboutUpdateStatusDetail: String {
        switch sparkleUpdater.updateStatus.state {
        case .unknown, .readyToCheck:
            return "Ask Sparkle to check whether a newer Transcripted release is ready."
        case .checking:
            return "Transcripted is probing for the latest available version now."
        case .noUpdateAvailable:
            return "This Mac is already on the newest version Sparkle can see right now."
        case .updateAvailable(let version):
            return "Version \(version) is ready. Use the button below to open the standard Sparkle update flow."
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
        case .updateAvailable:
            return .caution
        }
    }

    private var aboutUpdateButtonTitle: String {
        switch sparkleUpdater.updateStatus.state {
        case .updateAvailable:
            return "Update Available"
        case .checking:
            return "Checking for Updates…"
        case .unknown, .readyToCheck, .noUpdateAvailable:
            return "Check for Updates"
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
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if copiedAgentMeetingID == item.id {
                copiedAgentMeetingID = nil
            }
        }
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

private struct SettingsRecentMeetingRow: View {
    let item: RecentMeetingItem
    let detail: String
    let isCopied: Bool
    let openAction: () -> Void
    let copyForAgentAction: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
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

private struct AgentConnectionSettingsPage: View {
    @StateObject private var viewModel = AgentConnectionViewModel(
        context: AgentConnectionContext(meetingTitle: nil, meetingDate: nil, transcriptURL: nil)
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsPageIntro(
                title: "Connect Your Agent",
                summary: "Copy one smart prompt with the Summarize and Search Memory starter skills. The agent picks the best route automatically."
            )

            SettingsSection(
                title: "Main Path",
                detail: "Most people only need the main prompt. Local agents read Transcripted directly; remote chats get one clear next step if they cannot reach this Mac."
            ) {
                ForEach(Array(AgentConnectionGuide.starterSkills.enumerated()), id: \.offset) { _, skill in
                    SettingsQuickLinkRow(
                        symbolName: skill.symbolName,
                        title: skill.title,
                        detail: skill.displayDetail
                    ) {}
                    .disabled(true)
                }

                HStack {
                    Button("Copy Agent Setup") {
                        viewModel.copyStarterPrompt()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            SettingsSection(
                title: "Optional MCP Setup",
                detail: "Only use this if your agent supports MCP and you want the direct read-only tool connection."
            ) {
                Text(viewModel.context.mcpSetupText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Copy MCP Setup") {
                    viewModel.copyMCPSetup()
                }
                .buttonStyle(.bordered)
            }

            SettingsSection(
                title: "Manual Folders",
                detail: "These are fallback paths for manual setup or quick inspection."
            ) {
                AgentFolderRow(
                    name: "Meetings",
                    detail: "Saved meeting markdown files live here.",
                    path: viewModel.context.meetingsFolderURL.path,
                    isAvailable: viewModel.fileExists(viewModel.context.meetingsFolderURL)
                ) {
                    viewModel.reveal(viewModel.context.meetingsFolderURL)
                }

                AgentFolderRow(
                    name: "Dictations",
                    detail: "Saved dictation days and entries live here.",
                    path: viewModel.context.dictationsFolderURL.path,
                    isAvailable: viewModel.fileExists(viewModel.context.dictationsFolderURL)
                ) {
                    viewModel.reveal(viewModel.context.dictationsFolderURL)
                }

                Button("Copy Folder Paths") {
                    viewModel.copyFolderPaths()
                }
                .buttonStyle(.bordered)
            }
        }
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
