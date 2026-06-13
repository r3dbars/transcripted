import AppKit
import SwiftUI

/// Settings' Agent page. One mental model: pick the agent you use, click
/// Connect. Every row points the agent's own config at the same installed
/// `transcripted-mcp` helper; the universal copy-prompt row covers everything
/// else. Live-meeting sharing is a single toggle, and the long tail (folders,
/// Codex inbox automation, config details) lives behind Advanced.
struct AgentConnectionSettingsPage: View {
    private enum RowPhase: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
    }

    private let meetingsFolderURL = AgentConnectionGuide.meetingsFolder
    private let dictationsFolderURL = AgentConnectionGuide.dictationsFolder
    private let meetingSession: MeetingSessionController?

    @State private var detectedAgents: Set<AgentMCPAgent> = []
    @State private var connectedAgents: Set<AgentMCPAgent> = []
    @State private var rowPhases: [AgentMCPAgent: RowPhase] = [:]
    @State private var configRepairNotices: [AgentMCPAgent: String] = [:]
    @State private var claudeDesktopSelfTest: TranscriptedMCPSelfTest?
    @State private var copiedLocalAgentPrompt = false
    @State private var copiedClaudeDesktopConfig = false
    @State private var copiedFolderPaths = false
    @State private var openedCodexInboxSetup = false
    @State private var codexInboxSetupError: String?
    @State private var openedLiveMeetingCodexSetup = false
    @State private var openedLiveMeetingPreview = false
    @State private var copiedLiveMeetingCoworkSetup = false
    @State private var liveMeetingCodexSetupError: String?
    @State private var showAdvancedAgentSetup = false
    @AppStorage(LiveMeetingCodexPreferences.enabledKey) private var liveMeetingCodexEnabled = LiveMeetingCodexPreferences.defaultEnabled

    init(meetingSession: MeetingSessionController? = nil) {
        self.meetingSession = meetingSession
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsPageIntro(
                title: "Agent",
                summary: "Give your AI tools access to your meetings and dictations."
            )

            agentListSection
            liveMeetingSection
            advancedSection
        }
        .onAppear(perform: refreshAgentStates)
    }

    // MARK: - Agent rows

    private var agentListSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(AgentMCPAgent.allCases) { agent in
                if detectedAgents.contains(agent) {
                    agentRow(agent)
                }
            }

            copyPromptRow

            if !detectedAgents.contains(.claudeDesktop) {
                SettingsInlineActionButton(
                    title: "Get Claude Desktop",
                    symbolName: "arrow.down.circle",
                    tone: .accent,
                    automationIdentifier: "transcripted.settings.agent.get-claude-desktop"
                ) {
                    openClaudeDesktopDownload()
                }
            }
        }
    }

    private func agentRow(_ agent: AgentMCPAgent) -> some View {
        let phase = rowPhases[agent] ?? .idle
        let isConnected = connectedAgents.contains(agent)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: agentSymbol(agent))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.displayName)
                        .font(.subheadline.weight(.semibold))

                    Text(agentRowDetail(agent, isConnected: isConnected, phase: phase))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                if isConnected, phase != .connecting {
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                } else {
                    SettingsInlineActionButton(
                        title: phase == .connecting ? "Connecting..." : "Connect",
                        symbolName: phase == .connecting ? "hourglass" : "link",
                        tone: .accent,
                        automationIdentifier: "transcripted.settings.agent.connect.\(agent.rawValue)"
                    ) {
                        connect(agent)
                    }
                    .disabled(phase == .connecting)
                }
            }

            if case .failed(let message) = phase {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let configRepairNotice = configRepairNotices[agent] {
                Label(configRepairNotice, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if agent == .claudeDesktop, let claudeDesktopSelfTest {
                Text("\(claudeDesktopSelfTest.meetingFileCount) meetings, \(claudeDesktopSelfTest.dictationFileCount) dictation files visible.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .modifier(AgentRowCard())
    }

    private var copyPromptRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Something else")
                        .font(.subheadline.weight(.semibold))

                    Text("Windsurf, Zed, web chats — paste one prompt.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                SettingsInlineActionButton(
                    title: copiedLocalAgentPrompt ? "Copied" : "Copy prompt",
                    symbolName: copiedLocalAgentPrompt ? "checkmark" : "doc.on.doc",
                    automationIdentifier: "transcripted.settings.agent.copy-prompt"
                ) {
                    ActivationTelemetry.trackAgentSetupCTA(
                        setupKind: .localPrompt,
                        agentTarget: .localAgent,
                        surface: .agentSettings
                    )
                    ActivationTelemetry.trackAgentPromptAction(
                        promptKind: .localAgentPrompt,
                        actionKind: .copied,
                        agentTarget: .localAgent,
                        surface: .agentSettings
                    )
                    copyText(
                        AgentConnectionGuide.starterPrompt(filename: nil),
                        showingCopiedFeedback: $copiedLocalAgentPrompt
                    )
                }
            }
        }
        .modifier(AgentRowCard())
    }

    private func agentSymbol(_ agent: AgentMCPAgent) -> String {
        switch agent {
        case .claudeDesktop: return "bubble.left.and.text.bubble.right"
        case .claudeCode: return "terminal"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .cursor: return "cursorarrow.rays"
        }
    }

    private func agentRowDetail(_ agent: AgentMCPAgent, isConnected: Bool, phase: RowPhase) -> String {
        if phase == .connected || (isConnected && phase == .idle) {
            switch agent {
            case .claudeDesktop:
                return "Direct tools installed. Restart Claude Desktop after updates."
            case .claudeCode, .codex, .cursor:
                return "Direct tools registered. Restart \(agent.displayName) if it's running."
            }
        }
        return agent.detail
    }

    // MARK: - Live meetings

    private var liveMeetingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $liveMeetingCodexEnabled) {
                Label("Live meetings", systemImage: "waveform")
                    .font(.subheadline.weight(.semibold))
            }
            .toggleStyle(.switch)
            .onChange(of: liveMeetingCodexEnabled) { _, enabled in
                if enabled {
                    prepareLiveMeetingSidecarWorkspace()
                } else {
                    meetingSession?.stopLiveCodexSessionFromSettings()
                    stopLiveMeetingSidecarPreview()
                }
            }

            Text("Let connected agents follow a meeting while it records, from a local live-transcript folder.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if liveMeetingCodexEnabled {
                SettingsInlineActionButton(
                    title: openedLiveMeetingPreview ? "Opened Live View" : "Open Live View",
                    symbolName: openedLiveMeetingPreview ? "checkmark" : "doc.text",
                    tone: .accent,
                    automationIdentifier: "transcripted.settings.agent.open-live-view"
                ) {
                    openLiveMeetingPreview()
                }
            }

            if let liveMeetingCodexSetupError {
                Label(liveMeetingCodexSetupError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Advanced

    private var advancedSection: some View {
        SettingsSection(
            title: "Advanced",
            detail: "Folders, automations, and config details."
        ) {
            AgentSetupDetailsDisclosure(isExpanded: $showAdvancedAgentSetup) {
                VStack(alignment: .leading, spacing: 14) {
                    folderDetails
                    Divider()
                    codexInboxDetails
                    Divider()
                    liveSidecarAgentDetails
                    Divider()
                    claudeDesktopConfigDetails
                }
            }
        }
    }

    private var folderDetails: some View {
        VStack(alignment: .leading, spacing: 14) {
            AgentFolderRow(
                name: "Meetings",
                detail: "Meeting Markdown files.",
                path: meetingsFolderURL.path,
                isAvailable: folderExists(meetingsFolderURL)
            ) {
                reveal(meetingsFolderURL)
            }

            AgentFolderRow(
                name: "Dictation",
                detail: "Dictation Markdown files.",
                path: dictationsFolderURL.path,
                isAvailable: folderExists(dictationsFolderURL)
            ) {
                reveal(dictationsFolderURL)
            }

            SettingsInlineActionButton(
                title: copiedFolderPaths ? "Copied" : "Copy Paths",
                symbolName: "folder",
                automationIdentifier: "transcripted.settings.agent.copy-folder-paths"
            ) {
                ActivationTelemetry.trackAgentPromptAction(
                    promptKind: .folderPaths,
                    actionKind: .copied,
                    agentTarget: .fallbackFolder,
                    surface: .agentSettings
                )
                copyText(
                    AgentConnectionGuide.folderPathsText,
                    showingCopiedFeedback: $copiedFolderPaths
                )
            }
        }
    }

    private var codexInboxDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Codex meeting watcher", systemImage: "tray.and.arrow.down")
                .font(.subheadline.weight(.semibold))

            Text("A pinned Codex chat that checks for new meetings during work hours and posts a short after-action report.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SettingsInlineActionButton(
                title: openedCodexInboxSetup ? "Opened Codex Setup" : "Set up Codex Inbox",
                symbolName: openedCodexInboxSetup ? "checkmark" : "tray.and.arrow.down",
                tone: .accent,
                automationIdentifier: "transcripted.settings.agent.codex-inbox"
            ) {
                setupCodexInbox()
            }

            if let codexInboxSetupError {
                Label(codexInboxSetupError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var liveSidecarAgentDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Live meeting room in an agent", systemImage: "waveform")
                .font(.subheadline.weight(.semibold))

            Text("Set up a dedicated Codex thread or Claude Cowork session that watches the live-meeting folder.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                SettingsInlineActionButton(
                    title: openedLiveMeetingCodexSetup ? "Opened Codex" : "Open in Codex",
                    symbolName: openedLiveMeetingCodexSetup ? "checkmark" : "bubble.left.and.text.bubble.right",
                    tone: .accent
                ) {
                    setupLiveMeetingCodex()
                }

                SettingsInlineActionButton(
                    title: copiedLiveMeetingCoworkSetup ? "Copied Cowork" : "Copy for Cowork",
                    symbolName: copiedLiveMeetingCoworkSetup ? "checkmark" : "doc.on.doc",
                    tone: .accent
                ) {
                    copyLiveMeetingCoworkSetup()
                }
            }
        }
    }

    private var claudeDesktopConfigDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Claude Desktop config", systemImage: "gearshape.2")
                .font(.subheadline.weight(.semibold))

            HStack(spacing: 10) {
                SettingsInlineActionButton(
                    title: copiedClaudeDesktopConfig ? "Copied" : "Copy Claude Config",
                    symbolName: "doc.on.doc"
                ) {
                    ActivationTelemetry.trackAgentPromptAction(
                        promptKind: .claudeDesktopSetup,
                        actionKind: .copied,
                        agentTarget: .claudeDesktop,
                        surface: .agentSettings
                    )
                    copyText(
                        ClaudeDesktopIntegrationInstaller.configSnippet(),
                        showingCopiedFeedback: $copiedClaudeDesktopConfig
                    )
                }

                SettingsInlineActionButton(title: "Show Config", symbolName: "folder") {
                    revealClaudeDesktopConfig()
                }
                .disabled(!FileManager.default.fileExists(atPath: ClaudeDesktopIntegrationInstaller.claudeDesktopConfigURL.path))
            }
        }
    }

    // MARK: - State refresh

    private func refreshAgentStates() {
        Task {
            let states = await Task.detached(priority: .userInitiated) { () -> (detected: Set<AgentMCPAgent>, connected: Set<AgentMCPAgent>) in
                var detected: Set<AgentMCPAgent> = []
                var connected: Set<AgentMCPAgent> = []
                for agent in AgentMCPAgent.allCases {
                    if AgentMCPConnector.isDetected(agent) {
                        detected.insert(agent)
                    }
                    if AgentMCPConnector.isConnected(agent) {
                        connected.insert(agent)
                    }
                }
                return (detected, connected)
            }.value

            // Connected agents stay listed even if detection misses them —
            // the user clearly has the agent if its config points at us.
            detectedAgents = states.detected.union(states.connected)
            connectedAgents = states.connected
            // Fresh on-disk state supersedes stale per-row phases (e.g. an
            // old failure message); only in-flight connects survive.
            rowPhases = rowPhases.filter { $0.value == .connecting }
        }
    }

    // MARK: - Connect

    private func connect(_ agent: AgentMCPAgent) {
        guard rowPhases[agent] != .connecting else { return }
        rowPhases[agent] = .connecting
        configRepairNotices[agent] = nil
        if agent == .claudeDesktop {
            claudeDesktopSelfTest = nil
        }
        let priorStatus: ActivationTelemetry.AgentSetupPriorStatus =
            connectedAgents.contains(agent) ? .installed : .notInstalled

        Task {
            do {
                let outcome = try await Task.detached(priority: .userInitiated) { () -> (selfTest: TranscriptedMCPSelfTest?, replacedConfigBackupURL: URL?) in
                    if agent == .claudeDesktop {
                        let result = try ClaudeDesktopIntegrationInstaller.installForClaudeDesktop()
                        return (result.selfTest, result.backupURL)
                    }
                    let helper = try AgentMCPConnector.ensureHelperInstalled()
                    let result = try AgentMCPConnector.connect(agent, helperCommandPath: helper.path)
                    return (nil, result.replacedConfigBackupURL)
                }.value

                rowPhases[agent] = .connected
                connectedAgents.insert(agent)
                if agent == .claudeDesktop {
                    claudeDesktopSelfTest = outcome.selfTest
                }
                if let backupURL = outcome.replacedConfigBackupURL {
                    // An unreadable config was backed up and replaced — that
                    // dropped the user's other MCP servers, so say so instead
                    // of reporting a clean "Connected".
                    configRepairNotices[agent] = AgentMCPConnector.replacedConfigNotice(for: agent, backupURL: backupURL)
                }
                trackConnect(agent, priorStatus: priorStatus, result: .success)
            } catch {
                rowPhases[agent] = .failed(error.localizedDescription)
                trackConnect(agent, priorStatus: priorStatus, result: .failed)
            }
        }
    }

    private func trackConnect(
        _ agent: AgentMCPAgent,
        priorStatus: ActivationTelemetry.AgentSetupPriorStatus,
        result: ActivationTelemetry.AgentSetupResult
    ) {
        let setupKind: ActivationTelemetry.AgentSetupKind
        let agentTarget: ActivationTelemetry.AgentTarget
        switch agent {
        case .claudeDesktop:
            setupKind = .claudeDesktop
            agentTarget = .claudeDesktop
        case .claudeCode:
            setupKind = .claudeCode
            agentTarget = .claudeCode
        case .codex:
            setupKind = .codexTools
            agentTarget = .codex
        case .cursor:
            setupKind = .cursor
            agentTarget = .cursor
        }

        ActivationTelemetry.trackAgentSetupCTA(
            setupKind: setupKind,
            agentTarget: agentTarget,
            surface: .agentSettings,
            priorStatus: priorStatus,
            result: result
        )
    }

    // MARK: - Codex inbox

    private func setupCodexInbox() {
        codexInboxSetupError = nil

        do {
            let inboxURL = try AgentConnectionGuide.ensureCodexInboxFolder()
            copyText(AgentConnectionGuide.codexInboxSetupPrompt(inboxURL: inboxURL))
            ActivationTelemetry.trackAgentPromptAction(
                promptKind: .codexInboxSetup,
                actionKind: .copied,
                agentTarget: .codex,
                surface: .agentSettings
            )

            guard let setupURL = AgentConnectionGuide.codexInboxSetupURL(inboxURL: inboxURL) else {
                NSWorkspace.shared.activateFileViewerSelecting([inboxURL])
                codexInboxSetupError = "The setup prompt was copied. Open Codex and paste it."
                ActivationTelemetry.trackAgentSetupCTA(
                    setupKind: .codexInbox,
                    agentTarget: .codex,
                    surface: .agentSettings,
                    result: .fallbackCopied
                )
                return
            }

            if NSWorkspace.shared.open(setupURL) {
                ActivationTelemetry.trackAgentSetupCTA(
                    setupKind: .codexInbox,
                    agentTarget: .codex,
                    surface: .agentSettings
                )
                ActivationTelemetry.trackAgentPromptAction(
                    promptKind: .codexInboxSetup,
                    actionKind: .opened,
                    agentTarget: .codex,
                    surface: .agentSettings
                )
                showCopiedFeedback($openedCodexInboxSetup)
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([inboxURL])
                codexInboxSetupError = "Codex was not found. The setup prompt was copied and the inbox folder is open."
                ActivationTelemetry.trackAgentSetupCTA(
                    setupKind: .codexInbox,
                    agentTarget: .codex,
                    surface: .agentSettings,
                    result: .fallbackCopied
                )
            }
        } catch {
            codexInboxSetupError = "Could not set up Codex Inbox: \(error.localizedDescription)"
            ActivationTelemetry.trackAgentSetupCTA(
                setupKind: .codexInbox,
                agentTarget: .codex,
                surface: .agentSettings,
                result: .failed
            )
        }
    }

    // MARK: - Live sidecar

    private func setupLiveMeetingCodex() {
        liveMeetingCodexSetupError = nil

        do {
            liveMeetingCodexEnabled = true
            LiveMeetingCodexPreferences.setEnabled(true)
            let workspaceURL = try prepareLiveMeetingSidecarWorkspaceForUse()
            copyText(AgentConnectionGuide.liveMeetingCodexSetupPrompt(workspaceURL: workspaceURL))
            ActivationTelemetry.trackAgentPromptAction(
                promptKind: .liveMeetingCodexSetup,
                actionKind: .copied,
                agentTarget: .codex,
                surface: .agentSettings
            )

            guard let setupURL = AgentConnectionGuide.liveMeetingCodexSetupURL(workspaceURL: workspaceURL) else {
                NSWorkspace.shared.activateFileViewerSelecting([workspaceURL])
                liveMeetingCodexSetupError = "The setup prompt was copied. Open Codex and paste it."
                ActivationTelemetry.trackAgentSetupCTA(
                    setupKind: .liveSidecar,
                    agentTarget: .codex,
                    surface: .agentSettings,
                    result: .fallbackCopied
                )
                return
            }

            if NSWorkspace.shared.open(setupURL) {
                ActivationTelemetry.trackAgentSetupCTA(
                    setupKind: .liveSidecar,
                    agentTarget: .codex,
                    surface: .agentSettings
                )
                ActivationTelemetry.trackAgentPromptAction(
                    promptKind: .liveMeetingCodexSetup,
                    actionKind: .opened,
                    agentTarget: .codex,
                    surface: .agentSettings
                )
                showCopiedFeedback($openedLiveMeetingCodexSetup)
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([workspaceURL])
                liveMeetingCodexSetupError = "Codex was not found. The setup prompt was copied and the live folder is open."
                ActivationTelemetry.trackAgentSetupCTA(
                    setupKind: .liveSidecar,
                    agentTarget: .codex,
                    surface: .agentSettings,
                    result: .fallbackCopied
                )
            }
        } catch {
            disableLiveMeetingSidecarAfterFailure()
            liveMeetingCodexSetupError = "Could not set up Live Meetings: \(error.localizedDescription)"
            ActivationTelemetry.trackAgentSetupCTA(
                setupKind: .liveSidecar,
                agentTarget: .codex,
                surface: .agentSettings,
                result: .failed
            )
        }
    }

    private func prepareLiveMeetingSidecarWorkspace() {
        liveMeetingCodexSetupError = nil

        do {
            _ = try prepareLiveMeetingSidecarWorkspaceForUse()
        } catch {
            disableLiveMeetingSidecarAfterFailure()
            liveMeetingCodexSetupError = "Could not prepare Live Meetings: \(error.localizedDescription)"
        }
    }

    private func copyLiveMeetingCoworkSetup() {
        liveMeetingCodexSetupError = nil

        do {
            liveMeetingCodexEnabled = true
            LiveMeetingCodexPreferences.setEnabled(true)
            let workspaceURL = try prepareLiveMeetingSidecarWorkspaceForUse()
            copyText(AgentConnectionGuide.liveMeetingCoworkSetupPrompt(workspaceURL: workspaceURL))
            ActivationTelemetry.trackAgentSetupCTA(
                setupKind: .liveSidecar,
                agentTarget: .cowork,
                surface: .agentSettings
            )
            ActivationTelemetry.trackAgentPromptAction(
                promptKind: .liveMeetingCoworkSetup,
                actionKind: .copied,
                agentTarget: .cowork,
                surface: .agentSettings
            )
            NSWorkspace.shared.activateFileViewerSelecting([workspaceURL])
            showCopiedFeedback($copiedLiveMeetingCoworkSetup)
        } catch {
            disableLiveMeetingSidecarAfterFailure()
            liveMeetingCodexSetupError = "Could not set up Live Meetings: \(error.localizedDescription)"
            ActivationTelemetry.trackAgentSetupCTA(
                setupKind: .liveSidecar,
                agentTarget: .cowork,
                surface: .agentSettings,
                result: .failed
            )
        }
    }

    private func openLiveMeetingPreview() {
        liveMeetingCodexSetupError = nil

        do {
            liveMeetingCodexEnabled = true
            LiveMeetingCodexPreferences.setEnabled(true)
            let workspaceURL = try prepareLiveMeetingSidecarWorkspaceForUse()
            let previewURL: URL
            if #available(macOS 14.0, *) {
                previewURL = try LiveMeetingPreviewServer.shared.start(workspaceURL: workspaceURL)
            } else {
                previewURL = workspaceURL.appendingPathComponent(
                    LiveMeetingCodexSession.previewFilename,
                    isDirectory: false
                )
            }

            if NSWorkspace.shared.open(previewURL) {
                ActivationTelemetry.trackAgentSetupCTA(
                    setupKind: .livePreview,
                    agentTarget: .localAgent,
                    surface: .agentSettings
                )
                ActivationTelemetry.trackAgentPromptAction(
                    promptKind: .liveMeetingPreview,
                    actionKind: .opened,
                    agentTarget: .localAgent,
                    surface: .agentSettings
                )
                showCopiedFeedback($openedLiveMeetingPreview)
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([previewURL])
                liveMeetingCodexSetupError = "The live view is ready at \(previewURL.absoluteString)."
                ActivationTelemetry.trackAgentSetupCTA(
                    setupKind: .livePreview,
                    agentTarget: .localAgent,
                    surface: .agentSettings,
                    result: .fallbackCopied
                )
            }
        } catch {
            disableLiveMeetingSidecarAfterFailure()
            liveMeetingCodexSetupError = "Could not open Live View: \(error.localizedDescription)"
            ActivationTelemetry.trackAgentSetupCTA(
                setupKind: .livePreview,
                agentTarget: .localAgent,
                surface: .agentSettings,
                result: .failed
            )
        }
    }

    private func prepareLiveMeetingSidecarWorkspaceForUse() throws -> URL {
        let workspaceURL = try AgentConnectionGuide.ensureLiveMeetingCodexWorkspace()
        if #available(macOS 14.0, *) {
            _ = try LiveMeetingPreviewServer.shared.start(workspaceURL: workspaceURL)
        }
        return workspaceURL
    }

    private func stopLiveMeetingSidecarPreview() {
        if #available(macOS 14.0, *) {
            LiveMeetingPreviewServer.shared.stop()
        }
    }

    private func disableLiveMeetingSidecarAfterFailure() {
        liveMeetingCodexEnabled = false
        LiveMeetingCodexPreferences.setEnabled(false)
        meetingSession?.stopLiveCodexSessionFromSettings()
        stopLiveMeetingSidecarPreview()
    }

    // MARK: - Small helpers

    private func copyText(_ text: String, showingCopiedFeedback copiedFlag: Binding<Bool>? = nil) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard let copiedFlag else { return }
        showCopiedFeedback(copiedFlag)
    }

    private func showCopiedFeedback(_ flag: Binding<Bool>) {
        flag.wrappedValue = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            flag.wrappedValue = false
        }
    }

    private func revealClaudeDesktopConfig() {
        NSWorkspace.shared.activateFileViewerSelecting([ClaudeDesktopIntegrationInstaller.claudeDesktopConfigURL])
    }

    private func openClaudeDesktopDownload() {
        guard let url = URL(string: "https://claude.ai/download") else { return }
        ActivationTelemetry.trackAgentSetupCTA(
            setupKind: .claudeDesktop,
            agentTarget: .claudeDesktop,
            surface: .agentSettings,
            priorStatus: .notInstalled
        )
        NSWorkspace.shared.open(url)
    }

    private func folderExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func reveal(_ url: URL) {
        let target = folderExists(url) ? url : url.deletingLastPathComponent()
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }
}

private struct AgentRowCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
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
