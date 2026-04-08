import AppKit
import SwiftUI
import TranscriptedCore

struct AgentConnectionContext {
    let draftFolderURL: URL
    let meetingsFolderURL: URL
    let dictationsFolderURL: URL
    let prompt: String

    init(meetingTitle: String?, meetingDate: Date?, transcriptURL: URL?) {
        let draftFolderURL = FileManager.default.transcriptedAppSupportDir
        try? FileManager.default.createDirectory(at: draftFolderURL, withIntermediateDirectories: true)

        let meetingsFolderURL = MeetingStoragePaths.transcriptsFolder
        let dictationsFolderURL = DictationStoragePaths.transcriptsFolder
        AgentOutput.writeAgentReadme(to: meetingsFolderURL)

        let filename = transcriptURL?.deletingPathExtension().lastPathComponent

        _ = meetingTitle
        _ = meetingDate

        self.draftFolderURL = draftFolderURL
        self.meetingsFolderURL = meetingsFolderURL
        self.dictationsFolderURL = dictationsFolderURL
        self.prompt = Self.makePrompt(
            meetingsFolderURL: meetingsFolderURL,
            dictationsFolderURL: dictationsFolderURL,
            filename: filename
        )
    }

    private static func makePrompt(
        meetingsFolderURL: URL,
        dictationsFolderURL: URL,
        filename: String?
    ) -> String {
        var prompt = """
        I use Transcripted locally on my Mac.

        My transcript folders are:
        - Meetings: \(meetingsFolderURL.path)
        - Dictations: \(dictationsFolderURL.path)

        Please read those folders first and help me work with my transcripts.
        If AGENT.md exists in the meetings folder, read it first.
        If transcripted.json exists, use it as the index of saved meeting transcripts.
        Then use the relevant .md and .json transcript files.
        """

        if let filename {
            prompt += "\n\nIf helpful, start with: \(filename).json"
        }

        return prompt
    }
}

@MainActor
final class AgentConnectionViewModel: ObservableObject {
    @Published var context: AgentConnectionContext
    @Published var promptCopied = false

    private var resetTask: Task<Void, Never>?

    init(context: AgentConnectionContext) {
        self.context = context
    }

    deinit {
        resetTask?.cancel()
    }

    func copyPrompt() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(context.prompt, forType: .string)

        promptCopied = true
        resetTask?.cancel()
        resetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, !Task.isCancelled else { return }
            self.promptCopied = false
        }
    }

    func openDraftFolder() {
        NSWorkspace.shared.open(context.draftFolderURL)
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
                VStack(alignment: .leading, spacing: 20) {
                    promptSection
                    stepsSection
                    foldersSection
                }
                .padding(20)
            }
        }
        .frame(minWidth: 620, minHeight: 560)
        .background(AgentConnectionTheme.background)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(AgentConnectionTheme.badge)
                    .frame(width: 36, height: 36)

                Image(systemName: "terminal")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AgentConnectionTheme.accent)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Connect your agent")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AgentConnectionTheme.textPrimary)

                Text("Your agent can read your local meetings and dictations on this Mac.")
                    .font(.system(size: 12))
                    .foregroundStyle(AgentConnectionTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("Saved locally")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(AgentConnectionTheme.textMuted)
                    .textCase(.uppercase)

                Text(viewModel.context.draftFolderURL.lastPathComponent)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AgentConnectionTheme.textPrimary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(AgentConnectionTheme.background)
    }

    private var promptSection: some View {
        AgentConnectionSectionCard(
            title: "Starter prompt",
            subtitle: "Copy this into Codex, Claude, or another agent."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                Text(viewModel.context.prompt)
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

                HStack(spacing: 10) {
                    Button(viewModel.promptCopied ? "Prompt copied" : "Copy prompt") {
                        viewModel.copyPrompt()
                    }
                    .buttonStyle(AgentConnectionPrimaryButtonStyle())

                    Button("Open Transcripted folder") {
                        viewModel.openDraftFolder()
                    }
                    .buttonStyle(AgentConnectionSecondaryButtonStyle())
                }
            }
        }
    }

    private var foldersSection: some View {
        AgentConnectionSectionCard(
            title: "What your agent can read",
            subtitle: "These are the two folders Transcripted saves for you."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                AgentConnectionFileRow(
                    name: "Meetings",
                    detail: "Recorded meetings from the app.",
                    path: viewModel.context.meetingsFolderURL.path,
                    isAvailable: viewModel.fileExists(viewModel.context.meetingsFolderURL),
                    actionTitle: "Reveal"
                ) {
                    viewModel.reveal(viewModel.context.meetingsFolderURL)
                }

                AgentConnectionFileRow(
                    name: "Dictations",
                    detail: "Dictation notes and quick captures from the app.",
                    path: viewModel.context.dictationsFolderURL.path,
                    isAvailable: viewModel.fileExists(viewModel.context.dictationsFolderURL),
                    actionTitle: "Reveal"
                ) {
                    viewModel.reveal(viewModel.context.dictationsFolderURL)
                }
            }
        }
    }

    private var stepsSection: some View {
        AgentConnectionSectionCard(
            title: "How to use it",
            subtitle: "Three quick steps."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                AgentConnectionStepRow(
                    number: 1,
                    title: "Copy the prompt",
                    detail: "Use the copy button above."
                )

                AgentConnectionStepRow(
                    number: 2,
                    title: "Paste it into your agent",
                    detail: "This tells the agent where your meetings and dictations live."
                )

                AgentConnectionStepRow(
                    number: 3,
                    title: "Ask for help",
                    detail: "Try summaries, action items, follow-ups, decisions, or note cleanup."
                )
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
    let subtitle: String
    let content: Content

    init(
        title: String,
        subtitle: String,
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
                .foregroundStyle(AgentConnectionTheme.textMuted)

            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(AgentConnectionTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

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

private struct AgentConnectionStepRow: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
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
