import AppKit
import SwiftUI
import TranscriptedCore

struct TranscriptedSettingsView: View {
    enum SettingsPane: String, CaseIterable, Identifiable {
        case general
        case models
        case advanced
        case people
        case about

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: return "General"
            case .models: return "Models"
            case .advanced: return "Advanced"
            case .people: return "People"
            case .about: return "About"
            }
        }

        var symbolName: String {
            switch self {
            case .general: return "slider.horizontal.3"
            case .models: return "waveform.badge.mic"
            case .advanced: return "gearshape.2"
            case .people: return "person.2"
            case .about: return "info.circle"
            }
        }

        var detail: String {
            switch self {
            case .general:
                return "The core controls you’ll reach for most often."
            case .models:
                return "How Transcripted’s local dictation and meeting tools are doing."
            case .advanced:
                return "Permissions, diagnostics, storage, and agent setup."
            case .people:
                return "Speaker matching and cleanup for meeting history."
            case .about:
                return "Version info, updates, and support actions."
            }
        }
    }

    @ObservedObject var speakerPeopleModel: SpeakerPeopleSettingsViewModel
    @ObservedObject private var parakeetEngine: ParakeetEngine
    @ObservedObject private var meetingSession: MeetingSessionController
    @ObservedObject private var sparkleUpdater: SparkleUpdaterController

    @State private var selectedPane: SettingsPane = .general
    @State private var rightOptionEnabled = HotkeyPreferences.rightOptionDictationEnabled()
    @State private var uiSoundsEnabled = UISoundPreferences.isEnabled()
    @State private var crashReportingEnabled = CrashReportingPreferences.isEnabled()
    @State private var anonymousAnalyticsEnabled = AnalyticsPreferences.isEnabled()
    @State private var sentryTestStatus: String?
    @State private var permissionStates = PermissionSnapshot.current()
    @State private var captureLibraryURL = FileManager.default.transcriptedCaptureLibraryDir

    private let onCheckForUpdates: () -> Void
    private let onOpenAgentConnect: () -> Void
    private let onSendFeedback: () -> Void

    init(
        speakerPeopleModel: SpeakerPeopleSettingsViewModel,
        parakeetEngine: ParakeetEngine,
        meetingSession: MeetingSessionController,
        sparkleUpdater: SparkleUpdaterController,
        onCheckForUpdates: @escaping () -> Void,
        onOpenAgentConnect: @escaping () -> Void,
        onSendFeedback: @escaping () -> Void
    ) {
        self.speakerPeopleModel = speakerPeopleModel
        _parakeetEngine = ObservedObject(wrappedValue: parakeetEngine)
        _meetingSession = ObservedObject(wrappedValue: meetingSession)
        _sparkleUpdater = ObservedObject(wrappedValue: sparkleUpdater)
        self.onCheckForUpdates = onCheckForUpdates
        self.onOpenAgentConnect = onOpenAgentConnect
        self.onSendFeedback = onSendFeedback
    }

    var body: some View {
        ZStack {
            Color(MenuTokens.surfaceBackgroundNS)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    settingsSidebar
                        .frame(width: 220)

                    Rectangle()
                        .fill(Color(MenuTokens.sectionDividerNS))
                        .frame(width: 1)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            detailHeader
                            paneContent
                        }
                        .padding(.horizontal, 28)
                        .padding(.vertical, 24)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }

                Rectangle()
                    .fill(Color(MenuTokens.sectionDividerNS))
                    .frame(height: 1)

                SettingsFooterView(
                    modelState: modelBadgeState,
                    updateState: sparkleUpdater.updateState,
                    onOpenModels: { selectedPane = .models },
                    onCheckForUpdates: onCheckForUpdates
                )
            }
        }
        .frame(minWidth: 860, minHeight: 640)
        .preferredColorScheme(.dark)
        .onAppear {
            refreshPermissions()
            refreshStoragePaths()
            rightOptionEnabled = HotkeyPreferences.rightOptionDictationEnabled()
            uiSoundsEnabled = UISoundPreferences.isEnabled()
            crashReportingEnabled = CrashReportingPreferences.isEnabled()
            anonymousAnalyticsEnabled = AnalyticsPreferences.isEnabled()
        }
    }

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Image(systemName: "waveform.badge.mic")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color(MenuTokens.statusGreenNS))

                    Text("Transcripted")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color(MenuTokens.textPrimaryNS))
                }

                Text("A smaller launcher with one place to manage the rest.")
                    .font(.caption)
                    .foregroundStyle(Color(MenuTokens.textSecondaryNS))
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 6) {
                ForEach(SettingsPane.allCases) { pane in
                    Button {
                        selectedPane = pane
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: pane.symbolName)
                                .font(.system(size: 13, weight: .semibold))
                                .frame(width: 18)

                            Text(pane.title)
                                .font(.system(size: 13, weight: .semibold))

                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SettingsSidebarButtonStyle(isSelected: selectedPane == pane))
                }
            }

            Spacer()

            VStack(alignment: .leading, spacing: 4) {
                Text(TranscriptedAppActions.versionDisplay)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(MenuTokens.textPrimaryNS))

                Text("Local-first dictation and meeting capture for your Mac.")
                    .font(.caption2)
                    .foregroundStyle(Color(MenuTokens.textMutedNS))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
    }

    private var detailHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(selectedPane.title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color(MenuTokens.textPrimaryNS))

            Text(selectedPane.detail)
                .font(.callout)
                .foregroundStyle(Color(MenuTokens.textSecondaryNS))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var paneContent: some View {
        switch selectedPane {
        case .general:
            generalPane
        case .models:
            modelsPane
        case .advanced:
            advancedPane
        case .people:
            SpeakerPeopleSettingsSection(model: speakerPeopleModel)
        case .about:
            aboutPane
        }
    }

    private var generalPane: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsSection(
                title: "Capture",
                detail: "Keep the everyday controls in one place instead of scattering them across the menu bar."
            ) {
                VStack(spacing: 0) {
                    SettingsRow(
                        title: "Keyboard shortcuts",
                        detail: "Change the shortcuts for dictation and meeting capture."
                    ) {
                        HotkeyRecorderContainer()
                            .frame(width: 220, height: 76)
                    }

                    SettingsDivider()

                    SettingsRow(
                        title: "Right Option quick start",
                        detail: "Tap the right Option key once to start dictation from anywhere."
                    ) {
                        Toggle("", isOn: Binding(
                            get: { rightOptionEnabled },
                            set: { newValue in
                                rightOptionEnabled = newValue
                                HotkeyPreferences.setRightOptionDictation(enabled: newValue)
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }

                    SettingsDivider()

                    SettingsRow(
                        title: "Dictation sounds",
                        detail: "Play small macOS cues when dictation starts, stops, or finishes."
                    ) {
                        Toggle("", isOn: Binding(
                            get: { uiSoundsEnabled },
                            set: { newValue in
                                uiSoundsEnabled = newValue
                                UISoundPreferences.setEnabled(newValue)
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }
                }
            }

            SettingsSection(
                title: "What changed",
                detail: "The menu bar stays focused on starting work. These controls now live here instead of inside the popover."
            ) {
                VStack(spacing: 0) {
                    SettingsStaticRow(
                        title: "Menu bar",
                        detail: "Start dictation, start a meeting, open settings, check updates, and quit."
                    )

                    SettingsDivider()

                    SettingsStaticRow(
                        title: "Settings",
                        detail: "Shortcuts, model health, storage, permissions, and support live in one consistent shell."
                    )
                }
            }
        }
    }

    private var modelsPane: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsSection(
                title: "Local dictation",
                detail: "Transcripted uses a local Parakeet model for dictation. This badge lives in the footer so you always know what engine is active."
            ) {
                VStack(spacing: 0) {
                    SettingsRow(
                        title: "Current model",
                        detail: "Bundled local speech-to-text engine for dictation."
                    ) {
                        SettingsStatusPill(
                            title: "Parakeet V3",
                            detail: dictationModelState.status,
                            tone: modelBadgeState.tone
                        )
                    }

                    SettingsDivider()

                    SettingsRow(
                        title: dictationModelState.title,
                        detail: dictationModelState.detail
                    ) {
                        Text(dictationModelState.status)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color(MenuTokens.textSecondaryNS))
                    }

                    if let progress = dictationModelState.progress, dictationModelState.tone != .ready {
                        SettingsDivider()

                        SettingsProgressRow(progress: progress)
                    }

                    if dictationModelState.tone != .ready {
                        SettingsDivider()

                        SettingsActionRow(
                            title: "Retry model setup",
                            detail: "Ask Transcripted to try loading the local dictation model again.",
                            buttonTitle: "Retry"
                        ) {
                            Task {
                                await parakeetEngine.initialize()
                            }
                        }
                    }
                }
            }

            SettingsSection(
                title: "Meeting tools",
                detail: "Meeting capture warms up alongside dictation so the first recording is less awkward."
            ) {
                VStack(spacing: 0) {
                    SettingsRow(
                        title: meetingSession.warmupStatus.title,
                        detail: meetingSession.warmupStatus.detail.isEmpty
                            ? "Meeting capture is ready to go."
                            : meetingSession.warmupStatus.detail
                    ) {
                        SettingsStatusPill(
                            title: meetingSession.warmupStatus.meetingsStatus,
                            detail: meetingSession.warmupStatus.subtitle,
                            tone: meetingBadgeTone
                        )
                    }

                    if meetingBadgeTone != .ready {
                        SettingsDivider()

                        SettingsProgressRow(progress: meetingSession.warmupStatus.progress)
                    }

                    if meetingBadgeTone != .ready {
                        SettingsDivider()

                        SettingsActionRow(
                            title: "Retry meeting warmup",
                            detail: "Reload the meeting transcription tools in the background.",
                            buttonTitle: "Retry"
                        ) {
                            Task {
                                await meetingSession.prepareModels(showLoadingUI: false)
                            }
                        }
                    }
                }
            }
        }
    }

    private var advancedPane: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsSection(
                title: "Diagnostics",
                detail: "Crash reports and anonymous analytics stay separate, allowlisted, and scrubbed before anything leaves this Mac."
            ) {
                VStack(spacing: 0) {
                    SettingsRow(
                        title: "Crash and error reports",
                        detail: crashReportingFootnote
                    ) {
                        Toggle("", isOn: Binding(
                            get: { crashReportingEnabled },
                            set: { newValue in
                                crashReportingEnabled = newValue
                                CrashReportingPreferences.setEnabled(newValue)
                                sentryTestStatus = nil
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(!CrashReporter.isAvailable)
                    }

                    SettingsDivider()

                    SettingsRow(
                        title: "Anonymous usage stats",
                        detail: analyticsFootnote
                    ) {
                        Toggle("", isOn: Binding(
                            get: { anonymousAnalyticsEnabled },
                            set: { newValue in
                                anonymousAnalyticsEnabled = newValue
                                AnalyticsPreferences.setEnabled(newValue)
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(!AnalyticsReporter.isAvailable)
                    }

                    SettingsDivider()

                    SettingsActionRow(
                        title: "Send test Sentry event",
                        detail: sentryTestStatus ?? "Verify that Sentry is wired correctly without waiting for a real issue.",
                        buttonTitle: "Send"
                    ) {
                        sendTestSentryEvent()
                    }
                    .disabled(!CrashReporter.isAvailable || !crashReportingEnabled)
                }
            }

            SettingsSection(
                title: "Permissions",
                detail: "Transcripted only asks for the permissions it needs for local capture, paste-back, and optional meeting prompts."
            ) {
                VStack(spacing: 0) {
                    ForEach(Array(TranscriptedPermissionKind.allCases.enumerated()), id: \.element) { index, kind in
                        PermissionStatusRow(
                            kind: kind,
                            granted: permissionStates[kind] ?? false
                        ) {
                            TranscriptedPermissionAccess.openSettings(for: kind)
                            refreshPermissions()
                        }

                        if index < TranscriptedPermissionKind.allCases.count - 1 {
                            SettingsDivider()
                        }
                    }

                    SettingsDivider()

                    SettingsActionRow(
                        title: "Refresh permission status",
                        detail: "Pull the latest authorization state back into the app.",
                        buttonTitle: "Refresh"
                    ) {
                        refreshPermissions()
                    }
                }
            }

            SettingsSection(
                title: "Storage",
                detail: "Captures can live anywhere you want, while app state, cache, logs, and temp files stay under Application Support."
            ) {
                VStack(spacing: 0) {
                    StorageRow(title: "Capture library", url: captureLibraryURL)
                    SettingsDivider()
                    StorageRow(title: "Meeting captures", url: MeetingStoragePaths.transcriptsFolder)
                    SettingsDivider()
                    StorageRow(title: "Dictation captures", url: DictationStoragePaths.transcriptsFolder)
                    SettingsDivider()
                    StorageRow(title: "App state", url: appStateFolder)
                    SettingsDivider()
                    StorageRow(title: "App cache", url: cacheFolder)
                    SettingsDivider()
                    StorageRow(title: "App logs", url: logsFolder)
                    SettingsDivider()
                    StorageRow(title: "Temporary recordings", url: recordingsFolder)
                    SettingsDivider()
                    SettingsActionRow(
                        title: "Choose capture library",
                        detail: "Point Transcripted at an Obsidian vault or any other folder you want agents to read.",
                        buttonTitle: "Choose"
                    ) {
                        chooseCaptureLibrary()
                    }
                    SettingsDivider()
                    SettingsActionRow(
                        title: "Reset capture library",
                        detail: "Move captures back to Transcripted’s default folder.",
                        buttonTitle: "Reset"
                    ) {
                        TranscriptedStoragePreferences.setCaptureLibraryURL(nil)
                        refreshStoragePaths()
                    }
                }
            }

            SettingsSection(
                title: "Agent workflow",
                detail: "The old menu bar “copy for agent” action now lives in one clearer place."
            ) {
                VStack(spacing: 0) {
                    SettingsActionRow(
                        title: "Connect your agent",
                        detail: "Open the MCP and folder setup window for your agent.",
                        buttonTitle: "Open"
                    ) {
                        onOpenAgentConnect()
                    }

                    SettingsDivider()

                    SettingsActionRow(
                        title: "Send feedback",
                        detail: "Open a prefilled email with recent logs attached.",
                        buttonTitle: "Email"
                    ) {
                        onSendFeedback()
                    }
                }
            }
        }
    }

    private var aboutPane: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsSection(
                title: "About Transcripted",
                detail: "Local-first voice capture that saves clean Markdown files you can inspect yourself."
            ) {
                VStack(spacing: 0) {
                    SettingsStaticRow(
                        title: "App version",
                        detail: TranscriptedAppActions.fullVersionDisplay
                    )

                    SettingsDivider()

                    SettingsStaticRow(
                        title: "Current model",
                        detail: "Parakeet V3 for dictation, plus meeting warmup for transcription."
                    )

                    SettingsDivider()

                    SettingsStaticRow(
                        title: "Privacy",
                        detail: "Transcripted never sends transcript text, audio, meeting titles, speaker names, emails, tokens, or file paths through crash reporting or anonymous analytics."
                    )
                }
            }

            SettingsSection(
                title: "Updates and support",
                detail: "Keep Transcripted current and get the setup text for your agent without digging through the menu bar."
            ) {
                VStack(spacing: 0) {
                    SettingsActionRow(
                        title: sparkleUpdater.updateState.buttonTitle,
                        detail: sparkleUpdater.updateState.detailText,
                        buttonTitle: updateActionButtonTitle
                    ) {
                        onCheckForUpdates()
                    }
                    .disabled(sparkleUpdater.updateState == .checking)

                    SettingsDivider()

                    SettingsActionRow(
                        title: "Connect your agent",
                        detail: "Open the setup window for Codex, Claude, Cursor, or any other agent.",
                        buttonTitle: "Open"
                    ) {
                        onOpenAgentConnect()
                    }

                    SettingsDivider()

                    SettingsActionRow(
                        title: "Send feedback",
                        detail: "Email Transcripted with recent logs already attached.",
                        buttonTitle: "Email"
                    ) {
                        onSendFeedback()
                    }
                }
            }
        }
    }

    private var dictationModelState: FirstRunModelCardState {
        FirstRunExperience.modelCard(for: FirstRunLocalModelState(parakeetEngine.modelDownloadState))
    }

    private var modelBadgeState: SettingsBadgeState {
        switch dictationModelState.tone {
        case .ready:
            return SettingsBadgeState(title: "Parakeet V3", detail: "Ready", tone: .ready)
        case .working:
            return SettingsBadgeState(title: "Parakeet V3", detail: dictationModelState.status, tone: .working)
        case .failed:
            return SettingsBadgeState(title: "Parakeet V3", detail: "Needs attention", tone: .warning)
        }
    }

    private var meetingBadgeTone: SettingsStatusTone {
        meetingSession.warmupStatus == .ready ? .ready : .working
    }

    private var updateActionButtonTitle: String {
        switch sparkleUpdater.updateState {
        case .available:
            return "Install"
        case .checking:
            return "Checking"
        default:
            return "Open"
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

    private var crashReportingFootnote: String {
        if CrashReporter.isAvailable {
            return crashReportingEnabled
                ? "Enabled. Transcripted will send scrubbed crash and error data to Sentry so reliability issues are easier to diagnose."
                : "Off. Crash and error details stay on this Mac only."
        }

        return "This build does not have a Sentry DSN configured yet, so crash and error reporting stays local."
    }

    private var analyticsFootnote: String {
        if AnalyticsReporter.isAvailable {
            return anonymousAnalyticsEnabled
                ? "Enabled. Transcripted only sends coarse, allowlisted product events with no raw transcript content."
                : "Off. Transcripted will not send anonymous usage statistics."
        }

        return "This build does not have a PostHog key configured yet, so anonymous analytics stay disabled."
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

    private func refreshPermissions() {
        permissionStates = PermissionSnapshot.current()
    }

    private func refreshStoragePaths() {
        captureLibraryURL = FileManager.default.transcriptedCaptureLibraryDir
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
}

private struct PermissionSnapshot {
    private(set) var values: [TranscriptedPermissionKind: Bool]

    subscript(kind: TranscriptedPermissionKind) -> Bool? {
        values[kind]
    }

    static func current() -> PermissionSnapshot {
        PermissionSnapshot(values: Dictionary(uniqueKeysWithValues: TranscriptedPermissionKind.allCases.map {
            ($0, TranscriptedPermissionAccess.isGranted($0))
        }))
    }
}

private enum SettingsStatusTone {
    case ready
    case working
    case warning

    var color: Color {
        switch self {
        case .ready:
            return Color(MenuTokens.statusGreenNS)
        case .working:
            return Color(NSColor.systemOrange)
        case .warning:
            return Color(NSColor.systemPink)
        }
    }
}

private struct SettingsBadgeState {
    let title: String
    let detail: String
    let tone: SettingsStatusTone
}

struct SettingsSection<Content: View>: View {
    let title: String
    let detail: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Color(MenuTokens.textPrimaryNS))

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Color(MenuTokens.textSecondaryNS))
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 0) {
                content
            }
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(MenuTokens.actionBackgroundNS))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color(MenuTokens.sectionDividerNS), lineWidth: 1)
            )
        }
    }
}

private struct SettingsRow<Trailing: View>: View {
    let title: String
    let detail: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(MenuTokens.textPrimaryNS))

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Color(MenuTokens.textSecondaryNS))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)

            trailing
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}

private struct SettingsStaticRow: View {
    let title: String
    let detail: String

    var body: some View {
        SettingsRow(title: title, detail: detail) {
            EmptyView()
        }
    }
}

private struct SettingsActionRow: View {
    let title: String
    let detail: String
    let buttonTitle: String
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        SettingsRow(title: title, detail: detail) {
            Button(buttonTitle, action: action)
                .buttonStyle(SettingsInlineButtonStyle())
        }
        .opacity(isEnabled ? 1.0 : 0.6)
    }
}

private struct SettingsProgressRow: View {
    let progress: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: max(0, min(progress, 1)))
                .progressViewStyle(.linear)
                .tint(Color(MenuTokens.statusGreenNS))

            Text("\(Int(max(0, min(progress, 1)) * 100))% complete")
                .font(.caption)
                .foregroundStyle(Color(MenuTokens.textSecondaryNS))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color(MenuTokens.sectionDividerNS))
            .frame(height: 1)
            .padding(.horizontal, 18)
    }
}

private struct SettingsStatusPill: View {
    let title: String
    let detail: String
    let tone: SettingsStatusTone

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(tone.color)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(MenuTokens.textPrimaryNS))

                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(Color(MenuTokens.textSecondaryNS))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Capsule(style: .continuous)
                .fill(Color(MenuTokens.badgeBackgroundNS))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color(MenuTokens.badgeBorderNS), lineWidth: 1)
        )
    }
}

private struct SettingsFooterView: View {
    let modelState: SettingsBadgeState
    let updateState: SparkleUpdaterController.UpdateState
    let onOpenModels: () -> Void
    let onCheckForUpdates: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpenModels) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(modelState.tone.color)
                        .frame(width: 8, height: 8)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(modelState.title)
                            .font(.caption.weight(.semibold))

                        Text(modelState.detail)
                            .font(.caption2)
                            .foregroundStyle(Color(MenuTokens.textSecondaryNS))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .buttonStyle(SettingsFooterButtonStyle(alignment: .leading))

            Spacer()

            Button(action: onCheckForUpdates) {
                HStack(spacing: 8) {
                    Text(updateState.buttonTitle)
                        .font(.caption.weight(.semibold))

                    Text("• \(updateFooterVersionText)")
                        .font(.caption)
                        .foregroundStyle(Color(MenuTokens.textSecondaryNS))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .buttonStyle(SettingsFooterButtonStyle(alignment: .trailing))
            .disabled(updateState == .checking)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(MenuTokens.surfaceBackgroundNS))
    }

    private var updateFooterVersionText: String {
        switch updateState {
        case .available(let version):
            return version
        default:
            return TranscriptedAppActions.versionDisplay
        }
    }
}

private struct PermissionStatusRow: View {
    let kind: TranscriptedPermissionKind
    let granted: Bool
    let action: () -> Void

    var body: some View {
        SettingsRow(
            title: kind.title,
            detail: kind.summary
        ) {
            Button(granted ? "Review" : "Fix", action: action)
                .buttonStyle(SettingsInlineButtonStyle())
        }
    }
}

private struct StorageRow: View {
    let title: String
    let url: URL

    var body: some View {
        SettingsRow(
            title: title,
            detail: (url.path as NSString).abbreviatingWithTildeInPath
        ) {
            Button("Show in Finder") {
                if !FileManager.default.fileExists(atPath: url.path) {
                    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            .buttonStyle(SettingsInlineButtonStyle())
        }
    }
}

private struct HotkeyRecorderContainer: NSViewRepresentable {
    func makeNSView(context: Context) -> HotkeyRecorderAppKitView {
        HotkeyRecorderAppKitView(frame: .zero)
    }

    func updateNSView(_ nsView: HotkeyRecorderAppKitView, context: Context) {
        nsView.refreshDisplay()
    }
}

private struct SettingsSidebarButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isSelected ? Color.black : Color(MenuTokens.textPrimaryNS))
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Color(MenuTokens.statusGreenNS) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        isSelected ? Color.clear : Color(MenuTokens.sectionDividerNS),
                        lineWidth: 1
                    )
            )
            .opacity(configuration.isPressed ? 0.85 : 1.0)
    }
}

private struct SettingsInlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color(MenuTokens.textPrimaryNS))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(MenuTokens.badgeBackgroundNS))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color(MenuTokens.badgeBorderNS), lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.8 : 1.0)
    }
}

private struct SettingsFooterButtonStyle: ButtonStyle {
    enum Alignment {
        case leading
        case trailing
    }

    let alignment: Alignment

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: alignment == .leading ? .none : .infinity, alignment: alignment == .leading ? .leading : .trailing)
            .foregroundStyle(Color(MenuTokens.textPrimaryNS))
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(MenuTokens.badgeBackgroundNS))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color(MenuTokens.badgeBorderNS), lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.85 : 1.0)
    }
}
