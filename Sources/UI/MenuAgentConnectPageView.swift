// MenuAgentConnectPageView.swift
// Full-page agent connection guide embedded inside the menubar panel.

import AppKit
import TranscriptedCore

@MainActor
final class MenuAgentConnectPageView: NSView {
    var onBack: (() -> Void)?

    private let backButton = MenuOutlineButton(
        title: "Back",
        symbolName: "chevron.left",
        accessibilityLabel: "Back to menu",
        toolTip: "Back"
    )
    private let titleLabel = NSTextField(labelWithString: "Connect your agent")
    private let subtitleLabel = NSTextField(wrappingLabelWithString:
        "Bring Transcripted into Claude, Codex, or another local agent with a simple local-folder setup today, then grow into CLI and MCP flows later."
    )

    private let methodsLabel = NSTextField(labelWithString: "Ways to connect")
    private let folderRow = AgentConnectInfoRowView(
        symbolName: "folder",
        title: "Recommended: local folder mode",
        body: "Point your agent at the Draft folder on this Mac for meetings, dictations, prompts, and logs."
    )
    private let promptRow = AgentConnectInfoRowView(
        symbolName: "text.quote",
        title: "Prompt-first setup",
        body: "Copy a starter prompt for Claude, Codex, or Claude Code so the agent immediately knows where Transcripted stores context."
    )
    private let futureRow = AgentConnectInfoRowView(
        symbolName: "terminal",
        title: "CLI + MCP, coming later",
        body: "We can grow this into a Transcripted CLI and MCP flow for Claude Desktop, Claude Code, and other agent tools."
    )

    private let showFolderButton = MenuOutlineButton(
        title: "Show Draft folder",
        symbolName: "folder",
        accessibilityLabel: "Show Draft folder",
        toolTip: "Show Draft folder"
    )
    private let copyPromptButton = MenuOutlineButton(
        title: "Copy starter prompt",
        symbolName: "doc.on.doc",
        accessibilityLabel: "Copy starter prompt",
        toolTip: "Copy starter prompt"
    )

    private let skillsLabel = NSTextField(labelWithString: "Suggested skills")
    private let skillRows: [AgentConnectInfoRowView] = [
        AgentConnectInfoRowView(
            symbolName: "checklist",
            title: "Action-item extraction",
            body: "Teach your agent to pull owners, deadlines, and follow-ups from every meeting transcript."
        ),
        AgentConnectInfoRowView(
            symbolName: "person.2",
            title: "People + project memory",
            body: "Use persistent speaker IDs and saved dictations to keep running context on people, projects, and decisions."
        ),
        AgentConnectInfoRowView(
            symbolName: "books.vertical",
            title: "Second-brain summaries",
            body: "Ask the agent to merge meetings and quick dictations into daily briefings, project notes, and research context."
        )
    ]

    private let footerNoteLabel = NSTextField(wrappingLabelWithString:
        "This page is the home for agent setup. We can keep expanding it with CLI install steps, MCP instructions, and downloadable skills."
    )

    private var resetTask: Task<Void, Never>?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    deinit {
        resetTask?.cancel()
    }

    private func setupViews() {
        titleLabel.font = NSFont.systemFont(ofSize: 18, weight: .semibold)
        titleLabel.textColor = MenuTokens.textPrimaryNS
        addSubview(titleLabel)

        subtitleLabel.font = NSFont.systemFont(ofSize: 11)
        subtitleLabel.textColor = MenuTokens.textSecondaryNS
        subtitleLabel.maximumNumberOfLines = 3
        addSubview(subtitleLabel)

        [methodsLabel, skillsLabel].forEach { label in
            label.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            label.textColor = MenuTokens.textPrimaryNS
            addSubview(label)
        }

        footerNoteLabel.font = NSFont.systemFont(ofSize: 10)
        footerNoteLabel.textColor = MenuTokens.textMutedNS
        footerNoteLabel.maximumNumberOfLines = 2
        addSubview(footerNoteLabel)

        [folderRow, promptRow, futureRow].forEach { addSubview($0) }
        skillRows.forEach { addSubview($0) }

        backButton.target = self
        backButton.action = #selector(goBack)
        addSubview(backButton)

        showFolderButton.target = self
        showFolderButton.action = #selector(showDraftFolder)
        addSubview(showFolderButton)

        copyPromptButton.target = self
        copyPromptButton.action = #selector(copyStarterPrompt)
        addSubview(copyPromptButton)
    }

    override func layout() {
        super.layout()

        let pad: CGFloat = 0
        let width = bounds.width - pad * 2
        var y: CGFloat = 0

        let backWidth = max(72, backButton.fittingSize.width)
        backButton.frame = NSRect(x: pad, y: y, width: backWidth, height: MenuTokens.secondaryButtonSize)
        y += MenuTokens.secondaryButtonSize + 14

        titleLabel.frame = NSRect(x: pad, y: y, width: width, height: 22)
        y += 26

        subtitleLabel.frame = NSRect(x: pad, y: y, width: width, height: 42)
        y += 54

        methodsLabel.frame = NSRect(x: pad, y: y, width: width, height: 16)
        y += 22

        [folderRow, promptRow, futureRow].forEach { row in
            let rowHeight = row.intrinsicContentSize.height
            row.frame = NSRect(x: pad, y: y, width: width, height: rowHeight)
            y += rowHeight + 8
        }

        let buttonHeight = MenuTokens.secondaryButtonSize
        let showWidth = max(118, showFolderButton.fittingSize.width)
        let copyWidth = max(132, copyPromptButton.fittingSize.width)
        copyPromptButton.frame = NSRect(x: bounds.width - copyWidth, y: y + 2, width: copyWidth, height: buttonHeight)
        showFolderButton.frame = NSRect(
            x: copyPromptButton.frame.minX - 8 - showWidth,
            y: y + 2,
            width: showWidth,
            height: buttonHeight
        )
        y += buttonHeight + 18

        skillsLabel.frame = NSRect(x: pad, y: y, width: width, height: 16)
        y += 22

        skillRows.forEach { row in
            let rowHeight = row.intrinsicContentSize.height
            row.frame = NSRect(x: pad, y: y, width: width, height: rowHeight)
            y += rowHeight + 8
        }

        footerNoteLabel.frame = NSRect(x: pad, y: y + 2, width: width, height: 28)
    }

    var intrinsicHeight: CGFloat {
        MenuTokens.secondaryButtonSize + 14 + 22 + 26 + 42 + 54 + 16 + 22 + (64 * 3) + (8 * 2) + MenuTokens.secondaryButtonSize + 18 + 16 + 22 + (64 * 3) + (8 * 2) + 30
    }

    @objc private func goBack() {
        onBack?()
    }

    @objc private func showDraftFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([AgentConnectGuide.draftFolder])
    }

    @objc private func copyStarterPrompt() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(AgentConnectGuide.starterPrompt(), forType: .string)

        resetTask?.cancel()
        copyPromptButton.title = "Copied"
        copyPromptButton.setSymbol("checkmark", accessibilityLabel: "Starter prompt copied")
        resetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.copyPromptButton.title = "Copy starter prompt"
            self.copyPromptButton.setSymbol("doc.on.doc", accessibilityLabel: "Copy starter prompt")
        }
    }
}

private enum AgentConnectGuide {
    static var draftFolder: URL {
        let url = FileManager.default.draftAppSupportDir
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var meetingsFolder: URL {
        let url = MeetingStoragePaths.transcriptsFolder
        AgentOutput.writeAgentReadme(to: url)
        return url
    }

    static var dictationsFolder: URL {
        DictationStoragePaths.transcriptsFolder
    }

    static func starterPrompt() -> String {
        let meetingPrompt = AgentOutput.clipboardPrompt(folder: meetingsFolder, filename: nil)
        return """
        \(meetingPrompt)

        Transcripted also saves dictation exports here:
        \(dictationsFolder.path)

        Best local setup:
        - Open this Draft folder in your agent tool: \(draftFolder.path)
        - Use meetings/transcripts for structured meeting history
        - Use dictations/transcripts for quick notes and pasted dictation history

        Help me use Transcripted as a second brain:
        - summarize meetings
        - extract action items and follow-ups
        - track people, projects, and decisions over time
        - build context across my saved transcripts and dictations

        Future setup:
        - a local CLI for agent workflows
        - an MCP server for Claude Desktop, Claude Code, and similar tools
        """
    }
}

private final class AgentConnectInfoRowView: NSView {
    private let symbolWellView = NSView()
    private let symbolView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")

    init(symbolName: String, title: String, body: String) {
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = MenuTokens.actionBackgroundNS.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = MenuTokens.actionBorderNS.cgColor

        symbolWellView.wantsLayer = true
        symbolWellView.layer?.cornerRadius = 11
        symbolWellView.layer?.backgroundColor = MenuTokens.symbolBackgroundNS.cgColor
        symbolWellView.layer?.borderWidth = 1
        symbolWellView.layer?.borderColor = MenuTokens.symbolBorderNS.cgColor
        addSubview(symbolWellView)

        symbolView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        symbolView.contentTintColor = MenuTokens.textPrimaryNS
        symbolWellView.addSubview(symbolView)

        titleLabel.stringValue = title
        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = MenuTokens.textPrimaryNS
        addSubview(titleLabel)

        bodyLabel.stringValue = body
        bodyLabel.font = NSFont.systemFont(ofSize: 10)
        bodyLabel.textColor = MenuTokens.textSecondaryNS
        bodyLabel.maximumNumberOfLines = 2
        addSubview(bodyLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        symbolWellView.frame = NSRect(x: 12, y: 13, width: 22, height: 22)
        symbolView.frame = symbolWellView.bounds
        let textX = symbolWellView.frame.maxX + 10
        let textWidth = bounds.width - textX - 12
        titleLabel.frame = NSRect(x: textX, y: 12, width: textWidth, height: 14)
        bodyLabel.frame = NSRect(x: textX, y: 28, width: textWidth, height: 24)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 64)
    }
}
