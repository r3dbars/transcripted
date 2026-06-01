import AppKit
import SwiftUI

struct AgentConnectionSettingsPage: View {
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
    @State private var openedCodexInboxSetup = false
    @State private var codexInboxSetupError: String?
    @State private var openedLiveMeetingCodexSetup = false
    @State private var openedLiveMeetingPreview = false
    @State private var copiedLiveMeetingCoworkSetup = false
    @State private var liveMeetingCodexSetupError: String?
    @State private var showAdvancedAgentSetup = false
    @AppStorage(LiveMeetingCodexPreferences.enabledKey) private var liveMeetingCodexEnabled = LiveMeetingCodexPreferences.defaultEnabled

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

                            Text("Claude web, ChatGPT web, and mobile chats usually cannot see your Mac. Cowork needs the sidecar folder granted for live meetings.")
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

            if let attentionMessage = claudeDesktopStatus.attentionMessage {
                Label(attentionMessage, systemImage: claudeDesktopStatusSymbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(claudeDesktopStatusTint)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }

            VStack(alignment: .leading, spacing: 8) {
                SettingsInlineActionButton(
                    title: openedCodexInboxSetup ? "Opened Codex Setup" : "Set up Codex Inbox",
                    symbolName: openedCodexInboxSetup ? "checkmark" : "tray.and.arrow.down",
                    tone: .accent
                ) {
                    setupCodexInbox()
                }

                Text("Want a pinned Codex chat for Transcripted? This opens Codex with a setup prompt. Send it, then pin the chat in Codex.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let codexInboxSetupError {
                    Label(codexInboxSetupError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $liveMeetingCodexEnabled) {
                    Label("Live meeting sidecar", systemImage: "waveform")
                        .font(.subheadline.weight(.semibold))
                }
                .toggleStyle(.switch)
                .onChange(of: liveMeetingCodexEnabled) { _, enabled in
                    if enabled {
                        prepareLiveMeetingSidecarWorkspace()
                    } else {
                        stopLiveMeetingSidecarPreview()
                    }
                }

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

                    SettingsInlineActionButton(
                        title: openedLiveMeetingPreview ? "Opened Preview" : "Open Preview",
                        symbolName: openedLiveMeetingPreview ? "checkmark" : "doc.text",
                        tone: .accent
                    ) {
                        openLiveMeetingPreview()
                    }
                }

                Text("Use the same local sidecar from Codex or Claude Cowork. Codex can open the workspace directly; Cowork gets a copied setup prompt and folder path.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let liveMeetingCodexSetupError {
                    Label(liveMeetingCodexSetupError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
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
            if claudeDesktopStatus.installedBinaryExists,
               !claudeDesktopStatus.installedBinaryMatchesBundled {
                return "Update Claude Helper"
            }
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
            if claudeDesktopStatus.installedBinaryExists,
               !claudeDesktopStatus.installedBinaryMatchesBundled {
                return "Helper stale"
            }
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

    private func setupCodexInbox() {
        codexInboxSetupError = nil

        do {
            let inboxURL = try AgentConnectionGuide.ensureCodexInboxFolder()
            copyText(AgentConnectionGuide.codexInboxSetupPrompt(inboxURL: inboxURL))

            guard let setupURL = AgentConnectionGuide.codexInboxSetupURL(inboxURL: inboxURL) else {
                NSWorkspace.shared.activateFileViewerSelecting([inboxURL])
                codexInboxSetupError = "The setup prompt was copied. Open Codex and paste it."
                return
            }

            if NSWorkspace.shared.open(setupURL) {
                openedCodexInboxSetup = true
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    openedCodexInboxSetup = false
                }
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([inboxURL])
                codexInboxSetupError = "Codex was not found. The setup prompt was copied and the inbox folder is open."
            }
        } catch {
            codexInboxSetupError = "Could not set up Codex Inbox: \(error.localizedDescription)"
        }
    }

    private func setupLiveMeetingCodex() {
        liveMeetingCodexSetupError = nil

        do {
            liveMeetingCodexEnabled = true
            LiveMeetingCodexPreferences.setEnabled(true)
            let workspaceURL = try prepareLiveMeetingSidecarWorkspaceForUse()
            copyText(AgentConnectionGuide.liveMeetingCodexSetupPrompt(workspaceURL: workspaceURL))

            guard let setupURL = AgentConnectionGuide.liveMeetingCodexSetupURL(workspaceURL: workspaceURL) else {
                NSWorkspace.shared.activateFileViewerSelecting([workspaceURL])
                liveMeetingCodexSetupError = "The setup prompt was copied. Open Codex and paste it."
                return
            }

            if NSWorkspace.shared.open(setupURL) {
                openedLiveMeetingCodexSetup = true
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    openedLiveMeetingCodexSetup = false
                }
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([workspaceURL])
                liveMeetingCodexSetupError = "Codex was not found. The setup prompt was copied and the live folder is open."
            }
        } catch {
            liveMeetingCodexEnabled = false
            LiveMeetingCodexPreferences.setEnabled(false)
            stopLiveMeetingSidecarPreview()
            liveMeetingCodexSetupError = "Could not set up Live Sidecar: \(error.localizedDescription)"
        }
    }

    private func prepareLiveMeetingSidecarWorkspace() {
        liveMeetingCodexSetupError = nil

        do {
            _ = try prepareLiveMeetingSidecarWorkspaceForUse()
        } catch {
            liveMeetingCodexEnabled = false
            LiveMeetingCodexPreferences.setEnabled(false)
            stopLiveMeetingSidecarPreview()
            liveMeetingCodexSetupError = "Could not prepare Live Sidecar: \(error.localizedDescription)"
        }
    }

    private func copyLiveMeetingCoworkSetup() {
        liveMeetingCodexSetupError = nil

        do {
            liveMeetingCodexEnabled = true
            LiveMeetingCodexPreferences.setEnabled(true)
            let workspaceURL = try prepareLiveMeetingSidecarWorkspaceForUse()
            copyText(AgentConnectionGuide.liveMeetingCoworkSetupPrompt(workspaceURL: workspaceURL))
            copiedLiveMeetingCoworkSetup = true
            NSWorkspace.shared.activateFileViewerSelecting([workspaceURL])
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                copiedLiveMeetingCoworkSetup = false
            }
        } catch {
            liveMeetingCodexEnabled = false
            LiveMeetingCodexPreferences.setEnabled(false)
            stopLiveMeetingSidecarPreview()
            liveMeetingCodexSetupError = "Could not set up Live Sidecar: \(error.localizedDescription)"
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
                previewURL = LiveMeetingCodexSession.previewServerURL
            } else {
                previewURL = workspaceURL.appendingPathComponent(
                    LiveMeetingCodexSession.previewFilename,
                    isDirectory: false
                )
            }

            if NSWorkspace.shared.open(previewURL) {
                openedLiveMeetingPreview = true
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    openedLiveMeetingPreview = false
                }
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([previewURL])
                liveMeetingCodexSetupError = "The live preview is ready at \(previewURL.absoluteString)."
            }
        } catch {
            liveMeetingCodexEnabled = false
            LiveMeetingCodexPreferences.setEnabled(false)
            stopLiveMeetingSidecarPreview()
            liveMeetingCodexSetupError = "Could not open Live Preview: \(error.localizedDescription)"
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

        if let attentionMessage = status.attentionMessage {
            return attentionMessage
        }

        switch status.state {
        case .installed:
            return "Claude Desktop is configured. Restart Claude Desktop if you just installed it."
        case .notInstalled:
            return status.claudeDesktopLikelyInstalled
                ? "Click Install for Claude Desktop, then restart Claude Desktop."
                : "Claude Desktop was not found. You can still install now, then install Claude Desktop."
        case .needsRepair:
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
