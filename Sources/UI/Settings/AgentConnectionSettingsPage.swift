import AppKit
import SwiftUI

/// Settings' Agent page, connecting first: one status line, then a row per
/// detected agent (connected ones stay listed with a check), the universal
/// copy-prompt row, and Get Claude Desktop when it isn't installed. The
/// capture folders follow behind Folders.
/// Every row points the agent's own config at the same installed
/// `transcripted-mcp` helper. There is no Disconnect: the connector has no
/// safe way to remove its entry from an agent's config yet.
struct AgentConnectionSettingsPage: View {
    let writingController: WritingController

    private enum RowPhase: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
    }

    private let meetingsFolderURL = AgentConnectionGuide.meetingsFolder
    private let dictationsFolderURL = AgentConnectionGuide.dictationsFolder
    private let writingFolderURL = AgentConnectionGuide.writingFolder
    @State private var detectedAgents: Set<AgentMCPAgent> = []
    @State private var connectedAgents: Set<AgentMCPAgent> = []
    @State private var rowPhases: [AgentMCPAgent: RowPhase] = [:]
    // Raw connect-row error text, kept out of the message and behind "Copy Details".
    @State private var rowFailureDetails: [AgentMCPAgent: String] = [:]
    @State private var configRepairNotices: [AgentMCPAgent: String] = [:]
    @State private var claudeDesktopSelfTest: TranscriptedMCPSelfTest?
    @State private var copiedLocalAgentPrompt = false
    @State private var copiedFolderPaths = false
    @State private var showAdvancedAgentSetup = false
    /// False until the first detection pass finishes, so the empty state
    /// doesn't flash "No agents found" while it's still looking.
    @State private var hasLoadedAgentStates = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsPageIntro(
                title: "Agent",
                summary: "Let your AI tools read your meetings, dictations and writing."
            )
            VStack(alignment: .leading, spacing: 10) {
                statusLine
                agentListSection
            }
            .frame(maxWidth: 620, alignment: .leading)
            WritingCaptureSettingsCard(controller: writingController)
            advancedSection
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transcripted.settings.page.agent")
        .onAppear(perform: refreshAgentStates)
    }

    // MARK: - Status line

    private var statusLine: some View {
        HStack(spacing: 8) {
            if connectedAgents.isEmpty {
                Text(emptyStatusText)
                    .font(LibraryTokens.body)
                    .foregroundStyle(LibraryTokens.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // Connected is fine, not live: neutral ink.
                Circle()
                    .fill(LibraryTokens.ink2)
                    .frame(width: 6, height: 6)

                Text(connectedStatusText)
                    .font(LibraryTokens.body)
                    .foregroundStyle(Color.primary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var emptyStatusText: String {
        guard hasLoadedAgentStates else { return "Looking for agents on this Mac…" }
        if detectedAgents.isEmpty {
            return "No agents found on this Mac. Copy the prompt into any chat, or get Claude Desktop."
        }
        return "Pick one to connect."
    }

    /// "Connected · <first agent> reads your meetings and dictations", naming
    /// the first connected agent (in `AgentMCPAgent.allCases` order) and
    /// folding the rest into "and N more".
    private var connectedStatusText: String {
        let ordered = AgentMCPAgent.allCases.filter { connectedAgents.contains($0) }
        guard let first = ordered.first else { return "" }
        let remainder = ordered.count - 1
        let subject = remainder > 0 ? "\(first.displayName) and \(remainder) more" : first.displayName
        let justConnected = ordered.filter { rowPhases[$0] == .connected }
        if justConnected.count == 1, let agent = justConnected.first {
            return "Connected · Restart \(agent.displayName) to finish"
        }
        if justConnected.count > 1 {
            return "Connected · Restart your agents to finish"
        }
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

            if hasLoadedAgentStates, !detectedAgents.contains(.claudeDesktop) {
                getClaudeDesktopRow
            }

            copyPromptRow
        }
    }

    /// Every detected agent keeps its row; connected ones show a check, so
    /// you can see what's wired up.
    private func shouldShowRow(for agent: AgentMCPAgent) -> Bool {
        detectedAgents.contains(agent)
    }

    private func agentRow(_ agent: AgentMCPAgent) -> some View {
        let phase = rowPhases[agent] ?? .idle
        let isConnected = connectedAgents.contains(agent)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: agentSymbol(agent))
                    .font(TextRole.body.font(weight: .semibold))
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
                    Label("Connected", systemImage: "checkmark")
                        .labelStyle(.titleAndIcon)
                        .font(LibraryTokens.meta)
                        .foregroundStyle(LibraryTokens.ink2)
                        .accessibilityIdentifier("transcripted.settings.agent.connected.\(agent.rawValue)")
                } else {
                    SettingsInlineActionButton(
                        title: phase == .connecting ? "Connecting…" : "Connect",
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
                .font(TextRole.body.font(weight: .semibold))
                .foregroundStyle(LibraryTokens.ink2)
                .frame(width: 20, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text("Something else")
                    .font(LibraryTokens.rowTitle)

                Text("Any other app or chat: paste one prompt.")
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

    /// Claude Desktop isn't installed: listed like the others, with Get in
    /// place of Connect.
    private var getClaudeDesktopRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: agentSymbol(.claudeDesktop))
                .font(TextRole.body.font(weight: .semibold))
                .foregroundStyle(LibraryTokens.ink2)
                .frame(width: 20, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(AgentMCPAgent.claudeDesktop.displayName)
                    .font(LibraryTokens.rowTitle)
                Text("Not on this Mac")
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.ink2)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            SettingsInlineActionButton(
                title: "Get",
                symbolName: "arrow.down.circle",
                automationIdentifier: "transcripted.settings.agent.get-claude-desktop"
            ) {
                openClaudeDesktopDownload()
            }
        }
        .padding(.vertical, 10)
        .libraryRowDivider()
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
        // Just connected: the status line already says to restart, so the
        // row only names what kind of app it is.
        if isConnected && phase == .idle {
            switch agent {
            case .claudeDesktop:
                return "Restart Claude Desktop after Transcripted updates."
            case .claudeCode, .codex, .cursor:
                return "Restart \(agent.displayName) if it's running."
            }
        }
        return agentKind(agent)
    }

    /// Plain words for what each agent is ("Terminal", not "CLI").
    private func agentKind(_ agent: AgentMCPAgent) -> String {
        switch agent {
        case .claudeDesktop: return "Desktop app"
        case .claudeCode: return "Terminal"
        case .codex: return "App and terminal"
        case .cursor: return "Editor"
        }
    }

    // MARK: - Advanced

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            AgentSetupDetailsDisclosure(isExpanded: $showAdvancedAgentSetup) {
                folderDetails
            }
            Link("Transcribe files from Terminal", destination: AgentConnectionGuide.cliDocumentationURL)
                .font(LibraryTokens.meta)
                .help("Import files from Terminal or automate a folder")
                .accessibilityIdentifier("transcripted.settings.agent.cli-docs")
        }
    }

    private var folderDetails: some View {
        VStack(alignment: .leading, spacing: 14) {
            AgentFolderRow(
                name: "Meetings",
                path: meetingsFolderURL.path,
                isAvailable: folderExists(meetingsFolderURL)
            ) {
                reveal(meetingsFolderURL)
            }

            AgentFolderRow(
                name: "Dictations",
                path: dictationsFolderURL.path,
                isAvailable: folderExists(dictationsFolderURL)
            ) {
                reveal(dictationsFolderURL)
            }

            AgentFolderRow(
                name: "Writing",
                path: writingFolderURL.path,
                isAvailable: folderExists(writingFolderURL)
            ) {
                reveal(writingFolderURL)
            }

            SettingsInlineActionButton(
                title: copiedFolderPaths ? "Copied" : "Copy folder paths",
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
            hasLoadedAgentStates = true
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
                .buttonStyle(.transcriptedQuiet)
                .controlSize(.small)
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
                    configRepairNotices[agent] = AgentSetupFailureCopy.replacedSettingsFile(
                        agentName: agent.displayName,
                        backupFilename: backupURL.lastPathComponent
                    )
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
                let failure = AgentSetupFailureCopy.connectFailure(agentName: agent.displayName, error: error)
                rowPhases[agent] = .failed(failure.message)
                rowFailureDetails[agent] = failure.details
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
