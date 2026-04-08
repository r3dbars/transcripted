import AppKit
import SwiftUI

struct AgentConnectionContext {
    let appSupportFolderURL: URL
    let meetingsFolderURL: URL
    let dictationsFolderURL: URL
    let starterPrompt: String
    let mcpSetupText: String
    let mcpConfigExample: String
    let cliSummary: String
    let cliExamples: String

    init(meetingTitle: String?, meetingDate: Date?, transcriptURL: URL?) {
        let filename = transcriptURL?.deletingPathExtension().lastPathComponent

        _ = meetingTitle
        _ = meetingDate

        self.appSupportFolderURL = AgentConnectionGuide.appSupportFolder
        self.meetingsFolderURL = AgentConnectionGuide.meetingsFolder
        self.dictationsFolderURL = AgentConnectionGuide.dictationsFolder
        self.starterPrompt = AgentConnectionGuide.starterPrompt(filename: filename)
        self.mcpSetupText = AgentConnectionGuide.mcpSetupText
        self.mcpConfigExample = AgentConnectionGuide.mcpConfigExample
        self.cliSummary = AgentConnectionGuide.cliSummary
        self.cliExamples = AgentConnectionGuide.cliExamples
    }
}

private enum AgentConnectionCopyItem: Hashable {
    case prompt
    case mcp
    case cli
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

    func copyCLIExamples() {
        copy(
            """
            \(context.cliSummary)

            \(context.cliExamples)
            """,
            as: .cli
        )
    }

    fileprivate func copyLabel(for item: AgentConnectionCopyItem, default title: String) -> String {
        copiedItem == item ? "Copied" : title
    }

    func openAppSupportFolder() {
        NSWorkspace.shared.open(context.appSupportFolderURL)
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
                    startHereSection
                    mcpSection
                    cliSection
                    foldersSection
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
                Text("Connect your agent")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AgentConnectionTheme.textPrimary)

                Text("Start with the copy-paste prompt. If your agent supports MCP, you can give it a direct read-only connection too.")
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

    private var startHereSection: some View {
        AgentConnectionSectionCard(
            title: "Start here",
            subtitle: "Works with Claude, Codex, ChatGPT, or any agent that can read local files."
        ) {
            AgentConnectionBodyText("This is the simplest setup and the best default for most people. Give your agent the folders once, then ask normal questions.")

            AgentConnectionCodeBlock(text: viewModel.context.starterPrompt)

            HStack(spacing: 10) {
                Button(viewModel.copyLabel(for: .prompt, default: "Copy prompt")) {
                    viewModel.copyStarterPrompt()
                }
                .buttonStyle(AgentConnectionPrimaryButtonStyle())

                Button("Open Transcripted folder") {
                    viewModel.openAppSupportFolder()
                }
                .buttonStyle(AgentConnectionSecondaryButtonStyle())
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Good first asks")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AgentConnectionTheme.textPrimary)

                ForEach(Array(AgentConnectionGuide.starterExamples.enumerated()), id: \.offset) { index, example in
                    AgentConnectionInfoRow(
                        symbolName: "\(index + 1).circle.fill",
                        title: example,
                        detail: "Paste the prompt above first, then ask this directly."
                    )
                }
            }
        }
    }

    private var mcpSection: some View {
        AgentConnectionSectionCard(
            title: "Best on supported agents",
            subtitle: "MCP gives your agent direct read-only tools instead of making it browse files by hand."
        ) {
            AgentConnectionBodyText(viewModel.context.mcpSetupText)

            VStack(alignment: .leading, spacing: 10) {
                Text("What the Transcripted MCP server gives you")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AgentConnectionTheme.textPrimary)

                ForEach(Array(AgentConnectionGuide.mcpHighlights.enumerated()), id: \.offset) { index, highlight in
                    AgentConnectionInfoRow(
                        symbolName: index == 0 ? "wand.and.stars" : "checkmark.circle.fill",
                        title: highlight,
                        detail: "Read-only access to the local context Transcripted already saved on this Mac."
                    )
                }
            }

            AgentConnectionCodeBlock(text: viewModel.context.mcpConfigExample)

            HStack(spacing: 10) {
                Button(viewModel.copyLabel(for: .mcp, default: "Copy MCP example")) {
                    viewModel.copyMCPSetup()
                }
                .buttonStyle(AgentConnectionPrimaryButtonStyle())

                Button("Show meetings folder") {
                    viewModel.reveal(viewModel.context.meetingsFolderURL)
                }
                .buttonStyle(AgentConnectionSecondaryButtonStyle())
            }
        }
    }

    private var cliSection: some View {
        AgentConnectionSectionCard(
            title: "Advanced CLI",
            subtitle: "Use the terminal when you want scripts, automation, or offline audio work."
        ) {
            AgentConnectionBodyText(viewModel.context.cliSummary)

            AgentConnectionCodeBlock(text: viewModel.context.cliExamples)

            HStack(spacing: 10) {
                Button(viewModel.copyLabel(for: .cli, default: "Copy CLI examples")) {
                    viewModel.copyCLIExamples()
                }
                .buttonStyle(AgentConnectionPrimaryButtonStyle())

                Button("Show dictations folder") {
                    viewModel.reveal(viewModel.context.dictationsFolderURL)
                }
                .buttonStyle(AgentConnectionSecondaryButtonStyle())
            }
        }
    }

    private var foldersSection: some View {
        AgentConnectionSectionCard(
            title: "Your folders",
            subtitle: "All three paths above work from the same local Transcripted data."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                AgentConnectionFileRow(
                    name: "Meetings",
                    detail: "Structured meeting transcripts, markdown files, and AGENT.md live here.",
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
        }
    }
}

private enum AgentConnectionTheme {
    static let background = Color(MenuTokens.surfaceBackgroundNS)
    static let card = Color(MenuTokens.actionBackgroundNS)
    static let badge = Color(MenuTokens.badgeBackgroundNS)
    static let divider = Color(MenuTokens.sectionDividerNS)
    static let promptBackground = Color.black.opacity(0.18)
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

private struct AgentConnectionCodeBlock: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(AgentConnectionTheme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AgentConnectionTheme.promptBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(AgentConnectionTheme.divider, lineWidth: 1)
            )
    }
}

private struct AgentConnectionInfoRow: View {
    let symbolName: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbolName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AgentConnectionTheme.accent)
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(AgentConnectionTheme.badge)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AgentConnectionTheme.textPrimary)

                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(AgentConnectionTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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
