import AppKit
import SwiftUI

/// Settings' Agent page. Reads as a connection state, not a feature list: one
/// status line up top, then a plain row per detected agent that still needs a
/// Connect click. A connected agent collapses into the status line instead of
/// keeping its own row — the page should look empty once everything's wired
/// up. Every row points the agent's own config at the same installed
/// `transcripted-mcp` helper; the universal copy-prompt row covers everything
/// else. The long tail (folders) lives behind Advanced; Codex inbox
/// automation and Claude Desktop config details stay implemented but off the
/// view tree (see `codexInboxDetails` / `claudeDesktopConfigDetails`).
struct AgentConnectionSettingsPage: View {
    private enum RowPhase: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
    }

    private let meetingsFolderURL = AgentConnectionGuide.meetingsFolder
    private let dictationsFolderURL = AgentConnectionGuide.dictationsFolder
    @State private var detectedAgents: Set<AgentMCPAgent> = []
    @State private var connectedAgents: Set<AgentMCPAgent> = []
    @State private var rowPhases: [AgentMCPAgent: RowPhase] = [:]
    // Raw error text for the connect-row failure, kept out of the user-visible
    // message and offered behind "Copy Details".
    @State private var rowFailureDetails: [AgentMCPAgent: String] = [:]
    @State private var configRepairNotices: [AgentMCPAgent: String] = [:]
    @State private var claudeDesktopSelfTest: TranscriptedMCPSelfTest?
    @State private var copiedLocalAgentPrompt = false
    @State private var copiedClaudeDesktopConfig = false
    @State private var copiedFolderPaths = false
    @State private var openedCodexInboxSetup = false
    @State private var codexInboxSetupError: String?
    @State private var codexInboxSetupErrorDetails: String?
    @State private var showAdvancedAgentSetup = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsPageIntro(
                title: "Agent",
                summary: "Give your AI tools access to your meetings and dictations."
            )

            statusLine
            agentListSection
            advancedSection
        }
        .accessibilityIdentifier("transcripted.settings.page.agent")
        .onAppear(perform: refreshAgentStates)
    }

    // MARK: - Status line

    private var statusLine: some View {
        HStack(spacing: 8) {
            if connectedAgents.isEmpty {
                Text("Not connected yet — pick your agent below.")
                    .font(LibraryTokens.body)
                    .foregroundStyle(LibraryTokens.ink2)
            } else {
                Circle()
                    .fill(LibraryTokens.accent)
                    .frame(width: 6, height: 6)

                Text(connectedStatusText)
                    .font(LibraryTokens.body)
                    .foregroundStyle(Color.primary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// "Connected · <first agent> reads your meetings and dictations", naming
    /// the first connected agent (in `AgentMCPAgent.allCases` order) and
    /// folding the rest into "and N more".
    private var connectedStatusText: String {
        let ordered = AgentMCPAgent.allCases.filter { connectedAgents.contains($0) }
        guard let first = ordered.first else { return "" }
        let remainder = ordered.count - 1
        let subject = remainder > 0 ? "\(first.displayName) and \(remainder) more" : first.displayName
        return "Connected · \(subject) reads your meetings and dictations"
    }

    // MARK: - Agent rows

    private var agentListSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(AgentMCPAgent.allCases) { agent in
                if shouldShowRow(for: agent) {
                    agentRow(agent)
                }
            }

            copyPromptRow

            if !detectedAgents.contains(.claudeDesktop) {
                getClaudeDesktopRow
            }
        }
    }

    /// A connected agent collapses into the status line and stops rendering
    /// its own row — unless it still has something the user needs to act on
    /// (a failed retry, or a config-repair notice that dropped their other
    /// MCP servers and must stay visible).
    private func shouldShowRow(for agent: AgentMCPAgent) -> Bool {
        guard detectedAgents.contains(agent) else { return false }
        guard connectedAgents.contains(agent) else { return true }
        if case .failed = rowPhases[agent] ?? .idle { return true }
        return configRepairNotices[agent] != nil
    }

    private func agentRow(_ agent: AgentMCPAgent) -> some View {
        let phase = rowPhases[agent] ?? .idle
        let isConnected = connectedAgents.contains(agent)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: agentSymbol(agent))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LibraryTokens.ink2)
                    .frame(width: 20, alignment: .center)

                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.displayName)
                        .font(LibraryTokens.rowTitle)

                    Text(agentRowDetail(agent, isConnected: isConnected, phase: phase))
                        .font(LibraryTokens.meta)
                        .foregroundStyle(LibraryTokens.ink2)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                if isConnected, phase != .connecting {
                    Text("Connected")
                        .font(LibraryTokens.meta)
                        .foregroundStyle(LibraryTokens.ink2)
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
                failureNotice(
                    message: message,
                    details: rowFailureDetails[agent],
                    detailsAutomationIdentifier: "transcripted.settings.agent.connect-error-details.\(agent.rawValue)"
                )
            }

            if let configRepairNotice = configRepairNotices[agent] {
                Label(configRepairNotice, systemImage: "exclamationmark.triangle.fill")
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if agent == .claudeDesktop, let claudeDesktopSelfTest {
                Text("\(claudeDesktopSelfTest.meetingFileCount) meetings, \(claudeDesktopSelfTest.dictationFileCount) dictation files visible.")
                    .font(LibraryTokens.meta)
                    .monospacedDigit()
                    .foregroundStyle(LibraryTokens.ink2)
            }
        }
        .padding(.vertical, 10)
        .libraryRowDivider()
    }

    private var copyPromptRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(LibraryTokens.ink2)
                .frame(width: 20, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text("Something else")
                    .font(LibraryTokens.rowTitle)

                Text("Windsurf, Zed, web chats — paste one prompt.")
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.ink2)
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
        .padding(.vertical, 10)
        .libraryRowDivider()
    }

    private var getClaudeDesktopRow: some View {
        Button {
            openClaudeDesktopDownload()
        } label: {
            HStack(spacing: 6) {
                Text("Get Claude Desktop")
                    .font(LibraryTokens.body)
                    .foregroundStyle(LibraryTokens.accent)
                Spacer(minLength: 0)
            }
            .frame(minHeight: LibraryTokens.minimumHitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("transcripted.settings.agent.get-claude-desktop")
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

    // MARK: - Advanced

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            LibrarySectionLabel(text: "Advanced")

            AgentSetupDetailsDisclosure(isExpanded: $showAdvancedAgentSetup) {
                folderDetails
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

    // The Codex inbox automation and Claude Desktop config-details groups are
    // intentionally not on the view tree (see `advancedSection` above). Their
    // implementations stay in place — including telemetry, failure copy, and
    // automation identifiers — so restoring them to Advanced is a one-line
    // change, not a rewrite.

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
                failureNotice(
                    message: codexInboxSetupError,
                    details: codexInboxSetupErrorDetails,
                    detailsAutomationIdentifier: "transcripted.settings.agent.codex-inbox.error-details"
                )
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

                let claudeDesktopConfigExists = FileManager.default.fileExists(atPath: ClaudeDesktopIntegrationInstaller.claudeDesktopConfigURL.path)
                SettingsInlineActionButton(title: "Show Config", symbolName: "folder") {
                    revealClaudeDesktopConfig()
                }
                .disabled(!claudeDesktopConfigExists)
                .help(claudeDesktopConfigExists ? "" : "No Claude Desktop config file exists yet.")
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

    // MARK: - Failure notice

    /// Plain-words failure line plus a subtle "Copy Details" reveal for the raw
    /// error. The triggering control (Connect / Set up / Open) is the retry.
    @ViewBuilder
    private func failureNotice(
        message: String,
        details: String?,
        detailsAutomationIdentifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(LibraryTokens.meta)
                .foregroundStyle(LibraryTokens.attention)
                .fixedSize(horizontal: false, vertical: true)

            if let details {
                Button(AgentSetupFailureCopy.detailsTitle) {
                    copyText(details)
                }
                .buttonStyle(.link)
                .font(LibraryTokens.meta)
                .accessibilityIdentifier(detailsAutomationIdentifier)
            }
        }
    }

    // MARK: - Connect

    private func connect(_ agent: AgentMCPAgent) {
        guard rowPhases[agent] != .connecting else { return }
        let previousPhase = rowPhases[agent] ?? .idle
        let priorStatus = AgentSetupLifecycleTelemetry.priorStatus(for: agent)
        let isRetry: Bool
        if case .failed = previousPhase {
            isRetry = true
        } else {
            isRetry = false
        }
        let lifecycleTarget = AgentSetupLifecycleTelemetry.agentTarget(for: agent)
        let lifecycleSetupKind = AgentSetupLifecycleTelemetry.setupKind(for: agent)
        let lifecycleRepairKind = AgentSetupLifecycleTelemetry.repairKind(for: priorStatus)
        let startedAt = CFAbsoluteTimeGetCurrent()

        rowPhases[agent] = .connecting
        rowFailureDetails[agent] = nil
        configRepairNotices[agent] = nil
        if agent == .claudeDesktop {
            claudeDesktopSelfTest = nil
        }
        AgentSetupLifecycleTelemetry.track(
            agentTarget: lifecycleTarget,
            setupKind: lifecycleSetupKind,
            surface: .agentSettings,
            stage: .start,
            outcome: AgentSetupLifecycleTelemetry.startOutcome(isRetry: isRetry, priorStatus: priorStatus),
            priorStatus: priorStatus,
            repairKind: lifecycleRepairKind
        )

        Task {
            do {
                let outcome = try await Task.detached(priority: .userInitiated) { () -> (selfTest: TranscriptedMCPSelfTest?, replacedConfigBackupURL: URL?) in
                    if agent == .claudeDesktop {
                        let result = try ClaudeDesktopIntegrationInstaller.installForClaudeDesktop()
                        return (result.selfTest, result.backupURL)
                    }
                    let helper = try AgentMCPConnector.ensureHelperInstalled()
                    if let helperRepairKind = AgentSetupLifecycleTelemetry.repairKind(for: helper.action) {
                        AgentSetupLifecycleTelemetry.track(
                            agentTarget: lifecycleTarget,
                            setupKind: lifecycleSetupKind,
                            surface: .agentSettings,
                            stage: .helperInstall,
                            outcome: .advanced,
                            priorStatus: priorStatus,
                            repairKind: helperRepairKind
                        )
                    }
                    let result = try AgentMCPConnector.connect(agent, helperCommandPath: helper.path)
                    AgentSetupLifecycleTelemetry.track(
                        agentTarget: lifecycleTarget,
                        setupKind: lifecycleSetupKind,
                        surface: .agentSettings,
                        stage: .agentConfig,
                        outcome: .advanced,
                        priorStatus: priorStatus,
                        repairKind: lifecycleRepairKind
                    )
                    return (nil, result.replacedConfigBackupURL)
                }.value

                rowPhases[agent] = .connected
                connectedAgents.insert(agent)
                if agent == .claudeDesktop {
                    claudeDesktopSelfTest = outcome.selfTest
                    AgentSetupLifecycleTelemetry.track(
                        agentTarget: lifecycleTarget,
                        setupKind: lifecycleSetupKind,
                        surface: .agentSettings,
                        stage: .verification,
                        outcome: .verified,
                        priorStatus: priorStatus,
                        repairKind: lifecycleRepairKind
                    )
                }
                if let backupURL = outcome.replacedConfigBackupURL {
                    // An unreadable config was backed up and replaced — that
                    // dropped the user's other MCP servers, so say so instead
                    // of reporting a clean "Connected".
                    configRepairNotices[agent] = AgentMCPConnector.replacedConfigNotice(for: agent, backupURL: backupURL)
                }
                AgentSetupLifecycleTelemetry.track(
                    agentTarget: lifecycleTarget,
                    setupKind: lifecycleSetupKind,
                    surface: .agentSettings,
                    stage: .finish,
                    outcome: .installed,
                    priorStatus: priorStatus,
                    repairKind: lifecycleRepairKind,
                    durationSeconds: CFAbsoluteTimeGetCurrent() - startedAt
                )
                trackConnect(agent, priorStatus: priorStatus, result: .success)
            } catch {
                rowPhases[agent] = .failed(AgentSetupFailureCopy.connect(agentName: agent.displayName))
                rowFailureDetails[agent] = error.localizedDescription
                AgentSetupLifecycleTelemetry.track(
                    agentTarget: lifecycleTarget,
                    setupKind: lifecycleSetupKind,
                    surface: .agentSettings,
                    stage: .finish,
                    outcome: AgentSetupLifecycleTelemetry.failureOutcome(for: error),
                    priorStatus: priorStatus,
                    repairKind: lifecycleRepairKind,
                    failureKind: AgentSetupLifecycleTelemetry.failureKind(for: error),
                    durationSeconds: CFAbsoluteTimeGetCurrent() - startedAt
                )
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
        codexInboxSetupErrorDetails = nil

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
            codexInboxSetupError = AgentSetupFailureCopy.codexInbox
            codexInboxSetupErrorDetails = error.localizedDescription
            ActivationTelemetry.trackAgentSetupCTA(
                setupKind: .codexInbox,
                agentTarget: .codex,
                surface: .agentSettings,
                result: .failed
            )
        }
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

/// The one divider in this page: a hairline on the bottom edge of a row.
private struct LibraryRowDivider: ViewModifier {
    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            Rectangle()
                .fill(LibraryTokens.hairline)
                .frame(height: 1)
        }
    }
}

private extension View {
    func libraryRowDivider() -> some View {
        modifier(LibraryRowDivider())
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
                            .foregroundStyle(LibraryTokens.attention)
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
                .help(isAvailable ? "" : "This location hasn't been created yet.")
        }
    }
}
