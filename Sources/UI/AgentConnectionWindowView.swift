import AppKit
import SwiftUI
import TranscriptedCore

struct AgentConnectionContext {
    let meetingTitle: String?
    let meetingDate: Date?
    let transcriptsFolderURL: URL
    let agentReadmeURL: URL
    let indexURL: URL
    let transcriptMarkdownURL: URL?
    let transcriptJSONURL: URL?
    let prompt: String

    init(meeting: RecentMeetingItem?) {
        let transcriptsFolderURL = MeetingStoragePaths.transcriptsFolder
        try? FileManager.default.createDirectory(at: transcriptsFolderURL, withIntermediateDirectories: true)
        AgentOutput.writeAgentReadme(to: transcriptsFolderURL)
        let transcriptMarkdownURL = meeting?.transcriptURL
        let transcriptJSONURL = transcriptMarkdownURL?
            .deletingPathExtension()
            .appendingPathExtension("json")
        let filename = transcriptMarkdownURL?.deletingPathExtension().lastPathComponent

        self.meetingTitle = meeting?.title
        self.meetingDate = meeting?.date
        self.transcriptsFolderURL = transcriptsFolderURL
        self.agentReadmeURL = transcriptsFolderURL.appendingPathComponent("AGENT.md")
        self.indexURL = transcriptsFolderURL.appendingPathComponent("transcripted.json")
        self.transcriptMarkdownURL = transcriptMarkdownURL
        self.transcriptJSONURL = transcriptJSONURL
        self.prompt = AgentOutput.clipboardPrompt(folder: transcriptsFolderURL, filename: filename)
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

    func openTranscriptsFolder() {
        NSWorkspace.shared.open(context.transcriptsFolderURL)
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

    var selectedTranscriptName: String {
        context.meetingTitle ?? "Any saved meeting transcript"
    }

    var meetingDateText: String? {
        guard let meetingDate = context.meetingDate else { return nil }
        return Self.dateFormatter.string(from: meetingDate)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
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
                    summarySection
                    promptSection
                    filesSection
                    stepsSection
                }
                .padding(20)
            }
        }
        .frame(minWidth: 620, minHeight: 620)
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

                Text("Open a real setup page instead of a tiny menu. Everything below points your agent at the local Transcripted meeting data on this Mac.")
                    .font(.system(size: 12))
                    .foregroundStyle(AgentConnectionTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("Transcript folder")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(AgentConnectionTheme.textMuted)
                    .textCase(.uppercase)

                Text(viewModel.context.transcriptsFolderURL.lastPathComponent)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AgentConnectionTheme.textPrimary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(AgentConnectionTheme.background)
    }

    private var summarySection: some View {
        AgentConnectionSectionCard(
            title: "Suggested starting point",
            subtitle: "This is the transcript you launched the flow from."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(viewModel.selectedTranscriptName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(AgentConnectionTheme.textPrimary)

                        if let meetingDateText = viewModel.meetingDateText {
                            Text(meetingDateText)
                                .font(.system(size: 11))
                                .foregroundStyle(AgentConnectionTheme.textSecondary)
                        }
                    }

                    Spacer()

                    Text("Local only")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(AgentConnectionTheme.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule(style: .continuous)
                                .fill(AgentConnectionTheme.badge)
                        )
                }

                if let transcriptJSONURL = viewModel.context.transcriptJSONURL {
                    AgentConnectionPathRow(
                        title: transcriptJSONURL.lastPathComponent,
                        detail: "Structured sidecar with speakers, utterances, and metadata.",
                        path: transcriptJSONURL.path,
                        isAvailable: viewModel.fileExists(transcriptJSONURL)
                    )
                }

                if let transcriptMarkdownURL = viewModel.context.transcriptMarkdownURL {
                    AgentConnectionPathRow(
                        title: transcriptMarkdownURL.lastPathComponent,
                        detail: "Readable markdown transcript for quick manual inspection.",
                        path: transcriptMarkdownURL.path,
                        isAvailable: viewModel.fileExists(transcriptMarkdownURL)
                    )
                }
            }
        }
    }

    private var promptSection: some View {
        AgentConnectionSectionCard(
            title: "Starter prompt",
            subtitle: "Copy this into Codex, Claude, or another agent so it reads the right files first."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                ScrollView {
                    Text(viewModel.context.prompt)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(AgentConnectionTheme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(14)
                }
                .frame(minHeight: 132)
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

                    Button("Open transcripts folder") {
                        viewModel.openTranscriptsFolder()
                    }
                    .buttonStyle(AgentConnectionSecondaryButtonStyle())
                }
            }
        }
    }

    private var filesSection: some View {
        AgentConnectionSectionCard(
            title: "Files your agent should inspect",
            subtitle: "These are the core artifacts behind the connect flow."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                AgentConnectionFileRow(
                    name: "AGENT.md",
                    detail: "Schema and conventions for Transcripted meeting exports.",
                    path: viewModel.context.agentReadmeURL.path,
                    isAvailable: viewModel.fileExists(viewModel.context.agentReadmeURL),
                    actionTitle: "Reveal"
                ) {
                    viewModel.reveal(viewModel.context.agentReadmeURL)
                }

                AgentConnectionFileRow(
                    name: "transcripted.json",
                    detail: "Root index of every saved transcript in the folder.",
                    path: viewModel.context.indexURL.path,
                    isAvailable: viewModel.fileExists(viewModel.context.indexURL),
                    actionTitle: "Reveal"
                ) {
                    viewModel.reveal(viewModel.context.indexURL)
                }

                AgentConnectionFileRow(
                    name: viewModel.context.transcriptJSONURL?.lastPathComponent ?? "Selected transcript sidecar",
                    detail: "Recommended first transcript to load for this session.",
                    path: viewModel.context.transcriptJSONURL?.path ?? "Saved next to the selected .md transcript",
                    isAvailable: viewModel.fileExists(viewModel.context.transcriptJSONURL),
                    actionTitle: "Reveal"
                ) {
                    viewModel.reveal(viewModel.context.transcriptJSONURL)
                }
            }
        }
    }

    private var stepsSection: some View {
        AgentConnectionSectionCard(
            title: "How to use it",
            subtitle: "The window stays open while you explore. Close it when you are done."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                AgentConnectionStepRow(
                    number: 1,
                    title: "Read the contract",
                    detail: "Start with AGENT.md so the agent understands the export format and speaker IDs."
                )

                AgentConnectionStepRow(
                    number: 2,
                    title: "Load the index",
                    detail: "Read transcripted.json to find the saved meetings and pick the right transcript."
                )

                AgentConnectionStepRow(
                    number: 3,
                    title: "Open the selected transcript JSON",
                    detail: "Use the sidecar for structured speaker turns, timestamps, and transcript text."
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
            Text(title.uppercased())
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AgentConnectionTheme.textMuted)
                .tracking(0.8)

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

private struct AgentConnectionPathRow: View {
    let title: String
    let detail: String
    let path: String
    let isAvailable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AgentConnectionTheme.textPrimary)

                if !isAvailable {
                    Text("Missing")
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
