import AppKit
import SwiftUI

struct AgentConnectionContext {
    let meetingsFolderURL: URL
    let dictationsFolderURL: URL
    let starterPrompt: String
    let folderAccessPrompt: String
    let mcpSetupText: String
    let mcpConfigExample: String
    let folderPathsText: String

    init(meetingTitle: String?, meetingDate: Date?, transcriptURL: URL?) {
        let filename = transcriptURL?.deletingPathExtension().lastPathComponent

        _ = meetingTitle
        _ = meetingDate

        self.meetingsFolderURL = AgentConnectionGuide.meetingsFolder
        self.dictationsFolderURL = AgentConnectionGuide.dictationsFolder
        self.starterPrompt = AgentConnectionGuide.starterPrompt(filename: filename)
        self.folderAccessPrompt = AgentConnectionGuide.folderAccessPrompt
        self.mcpSetupText = AgentConnectionGuide.mcpSetupText
        self.mcpConfigExample = AgentConnectionGuide.mcpConfigExample
        self.folderPathsText = AgentConnectionGuide.folderPathsText
    }
}

private enum AgentConnectionCopyItem: Hashable {
    case prompt
    case mcp
    case folderPrompt
    case folders
}

@MainActor
final class AgentConnectionViewModel: ObservableObject {
    @Published var context: AgentConnectionContext
    @Published private var copiedItem: AgentConnectionCopyItem?

    private var resetTask: Task<Void, Never>?

    init(context: AgentConnectionContext) {
        self.context = context
    }

    deinit {
        resetTask?.cancel()
    }

    func copyStarterPrompt() {
        copy(context.starterPrompt, as: .prompt)
    }

    func copyFolderAccessPrompt() {
        copy(context.folderAccessPrompt, as: .folderPrompt)
    }

    func copyMCPSetup() {
        copy(
            """
            \(context.mcpSetupText)

            \(context.mcpConfigExample)
            """,
            as: .mcp
        )
    }

    func copyFolderPaths() {
        copy(context.folderPathsText, as: .folders)
    }

    fileprivate func copyLabel(for item: AgentConnectionCopyItem, default title: String) -> String {
        copiedItem == item ? "Copied" : title
    }

    func reveal(_ url: URL?) {
        guard let url else {
            NSSound.beep()
            return
        }

        let target = fileExists(url) ? url : url.deletingLastPathComponent()
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    func fileExists(_ url: URL?) -> Bool {
        guard let url else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private func copy(_ value: String, as item: AgentConnectionCopyItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)

        copiedItem = item
        resetTask?.cancel()
        resetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, !Task.isCancelled else { return }
            self.copiedItem = nil
        }
    }
}

@MainActor
struct AgentConnectionWindowView: View {
    @ObservedObject var viewModel: AgentConnectionViewModel

    var body: some View {
        VStack(spacing: 0) {
            header

            Rectangle()
                .fill(AgentConnectionTheme.divider)
                .frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    claudeDesktopSection
                    localAgentSection
                    webFallbackSection
                }
                .padding(20)
            }
        }
        .frame(minWidth: 680, minHeight: 620)
        .background(AgentConnectionTheme.background)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(AgentConnectionTheme.badge)
                    .frame(width: 36, height: 36)

                Image(systemName: "sparkles.rectangle.stack")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AgentConnectionTheme.accent)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Pick your agent")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AgentConnectionTheme.textPrimary)

                Text("Claude Desktop gets direct tools. Local coding agents get one prompt. Web chats are fallback only.")
                    .font(.system(size: 12))
                    .foregroundStyle(AgentConnectionTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(AgentConnectionTheme.background)
    }

    private var claudeDesktopSection: some View {
        AgentConnectionSectionCard(
            title: "Claude Desktop",
            subtitle: "Best path: install Transcripted direct tools, then restart Claude Desktop."
        ) {
            AgentConnectionBodyText("Use Transcripted Settings > Agent > Install for Claude Desktop. The app writes the Claude config and checks your local library.")

            HStack(spacing: 10) {
                Button(viewModel.copyLabel(for: .mcp, default: "Copy Steps")) {
                    viewModel.copyMCPSetup()
                }
                .buttonStyle(AgentConnectionSecondaryButtonStyle())
            }
        }
    }

    private var localAgentSection: some View {
        AgentConnectionSectionCard(
            title: "Local Coding Agents",
            subtitle: "Claude Code, Codex, Cursor, Windsurf, Zed, OpenCode, OpenClaw, Cline, Continue, and VS Code agents."
        ) {
            AgentConnectionBodyText("Paste one prompt into the agent. It will use direct tools if available, otherwise it reads your Transcripted Markdown folders.")

            HStack(spacing: 10) {
                Button(viewModel.copyLabel(for: .prompt, default: "Copy Prompt")) {
                    viewModel.copyStarterPrompt()
                }
                .buttonStyle(AgentConnectionPrimaryButtonStyle())
            }
        }
    }

    private var webFallbackSection: some View {
        AgentConnectionSectionCard(
            title: "Fallback Only: Web Chat Or Cowork",
            subtitle: "Not recommended for full Transcripted memory."
        ) {
            AgentConnectionBodyText("Claude web, ChatGPT web, Cowork, and mobile chats usually cannot see your Mac. Use this only for granted folders or pasted meetings.")

            VStack(alignment: .leading, spacing: 10) {
                AgentConnectionFileRow(
                    name: "Meetings",
                    detail: "Saved meeting markdown files live here.",
                    path: viewModel.context.meetingsFolderURL.path,
                    isAvailable: viewModel.fileExists(viewModel.context.meetingsFolderURL),
                    actionTitle: "Reveal"
                ) {
                    viewModel.reveal(viewModel.context.meetingsFolderURL)
                }

                AgentConnectionFileRow(
                    name: "Dictations",
                    detail: "Saved dictation days and entries live here.",
                    path: viewModel.context.dictationsFolderURL.path,
                    isAvailable: viewModel.fileExists(viewModel.context.dictationsFolderURL),
                    actionTitle: "Reveal"
                ) {
                    viewModel.reveal(viewModel.context.dictationsFolderURL)
                }
            }

            HStack(spacing: 10) {
                Button(viewModel.copyLabel(for: .folderPrompt, default: "Copy Folder Prompt")) {
                    viewModel.copyFolderAccessPrompt()
                }
                .buttonStyle(AgentConnectionSecondaryButtonStyle())

                Button(viewModel.copyLabel(for: .folders, default: "Copy Paths")) {
                    viewModel.copyFolderPaths()
                }
                .buttonStyle(AgentConnectionSecondaryButtonStyle())
            }
        }
    }
}

private enum AgentConnectionTheme {
    static let background = Color(MenuTokens.surfaceBackgroundNS)
    static let card = Color(MenuTokens.actionBackgroundNS)
    static let badge = Color(MenuTokens.badgeBackgroundNS)
    static let divider = Color(MenuTokens.sectionDividerNS)
    static let accent = Color(OverlayTokens.accentGreen)
    static let textPrimary = Color(MenuTokens.textPrimaryNS)
    static let textSecondary = Color(MenuTokens.textSecondaryNS)
    static let textMuted = Color(MenuTokens.textMutedNS)
    static let missing = Color(NSColor.systemOrange)
}

private struct AgentConnectionSectionCard<Content: View>: View {
    let title: String
    let subtitle: String?
    let content: Content

    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AgentConnectionTheme.textPrimary)

            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(AgentConnectionTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 14) {
                content
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(AgentConnectionTheme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(AgentConnectionTheme.divider, lineWidth: 1)
            )
        }
    }
}

private struct AgentConnectionBodyText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(AgentConnectionTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct AgentConnectionFileRow: View {
    let name: String
    let detail: String
    let path: String
    let isAvailable: Bool
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AgentConnectionTheme.textPrimary)

                    if !isAvailable {
                        Text("Not written yet")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(AgentConnectionTheme.missing)
                    }
                }

                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(AgentConnectionTheme.textSecondary)

                Text(path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(AgentConnectionTheme.textMuted)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 12)

            Button(actionTitle, action: action)
                .buttonStyle(AgentConnectionSecondaryButtonStyle())
                .disabled(!isAvailable)
        }
    }
}

private struct AgentConnectionPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.black)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(AgentConnectionTheme.accent)
            )
            .opacity(configuration.isPressed ? 0.85 : 1.0)
    }
}

private struct AgentConnectionSecondaryButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(isHovered ? AgentConnectionTheme.textPrimary : AgentConnectionTheme.textSecondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(AgentConnectionTheme.badge)
            )
            .opacity(configuration.isPressed ? 0.8 : 1.0)
            .onHover { isHovered = $0 }
    }
}
