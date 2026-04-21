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
        SettingsSidebarSection(id: "recording", title: "Recording", pages: [.meetings, .dictations, .shortcuts]),
        SettingsSidebarSection(id: "setup", title: "Setup", pages: [.general, .models, .storage, .connectAgent]),
        SettingsSidebarSection(id: "trust", title: "Trust", pages: [.privacy, .about])
    ]
}

struct TranscriptedSettingsView: View {
    @Bindable var navigation: TranscriptedSettingsNavigationModel
    @ObservedObject var speakerPeopleModel: SpeakerPeopleSettingsViewModel
    @ObservedObject private var sttRouter: STTRouter
    @ObservedObject private var meetingSession: MeetingSessionController
    @ObservedObject private var sparkleUpdater: SparkleUpdaterController

    private let actions: TranscriptedSettingsActions
    private let sidebarSections = SettingsSidebarSection.defaultSections

    @State private var rightOptionEnabled = HotkeyPreferences.rightOptionDictationEnabled()
    @State private var dictationShortcutMode = HotkeyPreferences.dictationShortcutMode()
    @State private var launchAtLoginEnabled = LaunchAtLoginController.isEnabled
    @State private var launchAtLoginStatus = LaunchAtLoginController.statusDescription
    @State private var customDictionaryText = CustomDictionaryPreferences.rawText()
    @State private var preferredTranscriptionModel = TranscriptionModelPreferences.preferredModel()
    @State private var showAdvancedModelControls = false
    @State private var uiSoundsEnabled = UISoundPreferences.isEnabled()
    @State private var autoEnterEnabled = DictationAutoSendPreferences.isEnabled()
    @State private var autoEnterKey = DictationAutoSendPreferences.sendKey()
    @State private var autoEnterAllowedBundleIDs = DictationAutoSendPreferences.allowedBundleIDs()
    @State private var autoEnterAppCandidates = AutoEnterAppCandidate.runningApps()
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
        .onReceive(NotificationCenter.default.publisher(for: .dictationTranscriptDidSave)) { _ in
            refreshRecentCaptures()
        }
        .onReceive(NotificationCenter.default.publisher(for: .transcriptionModelPreferenceDidChange)) { _ in
            preferredTranscriptionModel = TranscriptionModelPreferences.preferredModel()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
            refreshRecentCaptures()
        }
    }

    @ViewBuilder
    private func sidebarRows(for pages: [TranscriptedSettingsPage]) -> some View {
        ForEach(pages) { page in
            Label(page.title, systemImage: page.systemImage)
                .tag(page)
        }
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
                summary: "Start capture and fix anything marked orange."
            )

            let columns = [
                GridItem(.flexible(minimum: 220), spacing: 14),
                GridItem(.flexible(minimum: 220), spacing: 14)
            ]

            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                SettingsActionTile(
                    symbolName: "mic.fill",
                    title: "Start Dictation",
                    detail: "Speak into the app you were using.",
                    tone: .accent,
                    action: actions.startDictation
                )

                SettingsActionTile(
                    symbolName: "record.circle.fill",
                    title: "Start Meeting",
                    detail: "Record your mic and computer audio.",
                    tone: .accent,
                    action: actions.startMeeting
                )

                SettingsActionTile(
                    symbolName: "waveform",
                    title: "Transcribe Audio File",
                    detail: "Turn a recording into notes.",
                    action: actions.importAudioFile
                )

                SettingsActionTile(
                    symbolName: "sparkles",
                    title: "Connect Agent",
                    detail: "Let your agent read saved notes.",
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
                title: "Ready Check",
                detail: "Green is ready. Orange needs attention."
            ) {
                let modelCard = FirstRunExperience.modelCard(
                    for: FirstRunLocalModelState(sttRouter.modelDownloadState),
                    model: effectiveTranscriptionModel
                )

                SettingsStatusCard(
                    title: "Voice model",
                    status: modelCard.status,
                    detail: homeModelDetail(from: modelCard),
                    tone: preferredTranscriptionModel == effectiveTranscriptionModel ? tone(for: modelCard.tone) : .caution
                )

                SettingsStatusCard(
                    title: "Meeting tools",
                    status: meetingSession.warmupStatus.subtitle,
                    detail: meetingSession.warmupStatus.detail.isEmpty
                        ? "Ready for live meetings and audio imports."
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
                title: "Useful Pages",
                detail: "The settings people usually need first."
            ) {
                SettingsQuickLinkRow(
                    symbolName: "keyboard",
                    title: "Shortcuts",
                    detail: "Change the keys Transcripted listens for."
                ) {
                    navigation.selectedPage = .shortcuts
                }

                SettingsQuickLinkRow(
                    symbolName: "person.2.wave.2.fill",
                    title: "Meetings",
                    detail: "Import audio and manage speakers."
                ) {
                    navigation.selectedPage = .meetings
                }

                SettingsQuickLinkRow(
                    symbolName: "externaldrive.fill",
                    title: "Storage",
                    detail: "See where Markdown files live."
                ) {
                    navigation.selectedPage = .storage
                }

                SettingsQuickLinkRow(
                    symbolName: "lock.shield.fill",
                    title: "Privacy",
                    detail: "Review permissions and reporting."
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
                summary: "Keyboard triggers and send-after-paste rules."
            )

            SettingsSection(
                title: "Keys",
                detail: "Set one shortcut for dictation and one for meetings."
            ) {
                HotkeyRecorderContainer()
                    .frame(height: 76)

                Picker("Dictation mode", selection: Binding(
                    get: { dictationShortcutMode },
                    set: { newValue in
                        dictationShortcutMode = newValue
                        HotkeyPreferences.setDictationShortcutMode(newValue)
                    }
                )) {
                    ForEach(DictationShortcutMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(dictationShortcutMode.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Tap the right Option key for hands-free dictation", isOn: Binding(
                    get: { rightOptionEnabled },
                    set: { newValue in
                        rightOptionEnabled = newValue
                        HotkeyPreferences.setRightOptionDictation(enabled: newValue)
                    }
                ))

                Text(rightOptionEnabled
                    ? "Right Option starts and stops dictation with taps."
                    : "Dictation uses only the shortcut above."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            SettingsSection(
                title: "Send After Paste",
                detail: "Press Enter only in the apps you choose."
            ) {
                Toggle("Send after dictation", isOn: Binding(
                    get: { autoEnterEnabled },
                    set: { newValue in
                        autoEnterEnabled = newValue
                        DictationAutoSendPreferences.setEnabled(newValue)
                    }
                ))

                Picker("Send key", selection: Binding(
                    get: { autoEnterKey },
                    set: { newValue in
                        autoEnterKey = newValue
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
                            refreshAutoEnterAppCandidates()
                        }

                        Button("Add App…") {
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
                summary: "Startup and words Transcripted should know."
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
                title: "Custom Words",
                detail: "Names, acronyms, and phrases to favor."
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    TextEditor(text: Binding(
                        get: { customDictionaryText },
                        set: { updateCustomDictionaryText($0) }
                    ))
                    .font(.body)
                    .frame(minHeight: 150)
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

                    HStack(alignment: .firstTextBaseline) {
                        Text(customDictionaryStatusLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer()

                        Button("Clear") {
                            updateCustomDictionaryText("")
                        }
                        .disabled(customDictionaryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    Text("One per line. Use spoken text -> preferred text for corrections.")
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
                summary: "Record meetings, import audio, and manage speakers."
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
                    actions.startMeeting()
                }

                SettingsQuickLinkRow(
                    symbolName: "waveform",
                    title: "Transcribe Audio File",
                    detail: "Turn an audio file into meeting notes."
                ) {
                    actions.importAudioFile()
                }

                Text("Blocked? Open Privacy and check microphone or system audio.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                                meetingSession.retryFailedMeeting(id: item.id)
                            },
                            secondaryAction: {
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
                title: "Recent",
                detail: "The last five saved meeting transcripts."
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
                title: "Sounds",
                detail: "Play short cues for dictation state."
            ) {
                Toggle("Play dictation feedback sounds", isOn: Binding(
                    get: { uiSoundsEnabled },
                    set: { newValue in
                        uiSoundsEnabled = newValue
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
                        chooseCaptureLibrary()
                    }

                    Button("Reset to Default") {
                        TranscriptedStoragePreferences.setCaptureLibraryURL(nil)
                        refreshStoragePaths()
                    }
                }

                Text("Pick an Obsidian vault or any folder you want agents to read.")
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
                        CrashReportingPreferences.setEnabled(newValue)
                        sentryTestStatus = nil
                    }
                ))
                .disabled(!CrashReporter.isAvailable)

                Toggle("Send anonymous usage stats", isOn: Binding(
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
                summary: "Version, updates, and support."
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

    private func refreshState() {
        refreshPermissions()
        refreshStoragePaths()
        refreshRecentCaptures()
        rightOptionEnabled = HotkeyPreferences.rightOptionDictationEnabled()
        dictationShortcutMode = HotkeyPreferences.dictationShortcutMode()
        refreshLaunchAtLoginState()
        customDictionaryText = CustomDictionaryPreferences.rawText()
        preferredTranscriptionModel = TranscriptionModelPreferences.preferredModel()
        showAdvancedModelControls = preferredTranscriptionModel != TranscriptionModelPreferences.defaultModel
        uiSoundsEnabled = UISoundPreferences.isEnabled()
        autoEnterEnabled = DictationAutoSendPreferences.isEnabled()
        autoEnterKey = DictationAutoSendPreferences.sendKey()
        autoEnterAllowedBundleIDs = DictationAutoSendPreferences.allowedBundleIDs()
        refreshAutoEnterAppCandidates()
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

    private func refreshLaunchAtLoginState() {
        launchAtLoginEnabled = LaunchAtLoginController.isEnabled
        launchAtLoginStatus = LaunchAtLoginController.statusDescription
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        let previousValue = launchAtLoginEnabled
        launchAtLoginEnabled = enabled

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
            return "No custom words yet."
        }
        return "\(count) custom word\(count == 1 ? "" : "s") active."
    }

    private func updateCustomDictionaryText(_ text: String) {
        let clampedText = CustomDictionaryPreferences.clampedRawText(text)
        customDictionaryText = clampedText
        CustomDictionaryPreferences.setRawText(clampedText)
    }

    private func updatePreferredTranscriptionModel(_ model: TranscriptionModelChoice) {
        preferredTranscriptionModel = model
        showAdvancedModelControls = true
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
        DictationAutoSendPreferences.setAllowedBundleIDs(autoEnterAllowedBundleIDs)
    }

    private func refreshAutoEnterAppCandidates() {
        autoEnterAppCandidates = AutoEnterAppCandidate.runningApps()
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
            return "Update available (\(version))"
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
            return "Version \(version) is ready."
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
    let copyForAgentAction: () -> Void
    @ObservedObject private var playback = MeetingAudioPlayback.shared

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

            if let audio = item.audio {
                Button {
                    playback.toggle(audio)
                } label: {
                    Label(playback.buttonTitle(for: audio), systemImage: playback.symbolName(for: audio))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsPageIntro(
                title: "Agent",
                summary: "Copy one prompt so your agent can read Transcripted notes."
            )

            SettingsSection(
                title: "Main Prompt",
                detail: "Best first step for Codex, Claude, Cursor, and similar agents."
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
                    Button("Copy Prompt") {
                        viewModel.copyStarterPrompt()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            SettingsSection(
                title: "Direct Tools",
                detail: "Optional read-only MCP setup."
            ) {
                Text(viewModel.context.mcpSetupText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Copy Setup") {
                    viewModel.copyMCPSetup()
                }
                .buttonStyle(.bordered)
            }

            SettingsSection(
                title: "Manual Folders",
                detail: "Fallback paths for agents or quick inspection."
            ) {
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
