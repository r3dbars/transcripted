import AppKit
import SwiftUI

struct AgentConnectionContext {
    let starterPrompt: String
    let mcpSetupText: String
    let mcpConfigExample: String
    let folderPathsText: String

    init(meetingTitle: String?, meetingDate: Date?, transcriptURL: URL?) {
        let filename = transcriptURL?.deletingPathExtension().lastPathComponent

        _ = meetingTitle
        _ = meetingDate

        self.starterPrompt = AgentConnectionGuide.starterPrompt(filename: filename)
        self.mcpSetupText = AgentConnectionGuide.mcpSetupText
        self.mcpConfigExample = AgentConnectionGuide.mcpConfigExample
        self.folderPathsText = AgentConnectionGuide.folderPathsText
    }
}

private enum AgentConnectionCopyItem: Hashable {
    case prompt
    case mcp
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
                    primarySection
                    advancedSection
                }
                .padding(20)
            }
        }
        .frame(minWidth: 680, minHeight: 440)
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
                Text("Connect your agent")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AgentConnectionTheme.textPrimary)

                Text(AgentConnectionGuide.headerSummary)
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

    private var primarySection: some View {
        AgentConnectionSectionCard(
            title: "Start here",
            subtitle: "This is the only step most people need."
        ) {
            AgentConnectionBodyText(AgentConnectionGuide.primarySetupSummary)

            HStack(spacing: 10) {
                Button(viewModel.copyLabel(for: .prompt, default: "Copy prompt")) {
                    viewModel.copyStarterPrompt()
                }
                .buttonStyle(AgentConnectionPrimaryButtonStyle())
            }
        }
    }

    private var advancedSection: some View {
        AgentConnectionSectionCard(
            title: "Manual setup",
            subtitle: "Only use this if the main prompt is not enough."
        ) {
            AgentConnectionBodyText(AgentConnectionGuide.manualSetupSummary)

            VStack(alignment: .leading, spacing: 10) {
                Button(viewModel.copyLabel(for: .mcp, default: "Copy MCP setup")) {
                    viewModel.copyMCPSetup()
                }
                .buttonStyle(AgentConnectionSecondaryButtonStyle())

                Button(viewModel.copyLabel(for: .folders, default: "Copy folder paths")) {
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
