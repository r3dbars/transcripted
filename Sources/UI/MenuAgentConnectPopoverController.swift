// MenuAgentConnectPopoverController.swift
// Lightweight guide for connecting local agent tools to Transcripted data.

import AppKit
import TranscriptedCore

@MainActor
final class MenuAgentConnectPopoverController: NSViewController {
    private let titleLabel = NSTextField(labelWithString: "Connect your agent")
    private let subtitleLabel = NSTextField(wrappingLabelWithString:
        "Bring Transcripted into Claude, Codex, or another local agent in a couple of steps."
    )

    private let folderRow = AgentConnectInfoRowView(
        symbolName: "folder",
        title: "Local folder mode",
        body: "Point your agent at the Draft folder on this Mac for meetings, dictations, prompts, and logs."
    )

    private let promptRow = AgentConnectInfoRowView(
        symbolName: "text.quote",
        title: "Quickstart prompt",
        body: "Copy a starter prompt that tells your agent where to find structured transcripts and Markdown exports."
    )

    private let futureRow = AgentConnectInfoRowView(
        symbolName: "terminal",
        title: "CLI + MCP later",
        body: "We’ll add direct CLI and MCP setup for Claude Desktop, Claude Code, and other agent tools."
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

    private var resetTask: Task<Void, Never>?

    override func loadView() {
        view = FlippedAgentConnectView(frame: NSRect(x: 0, y: 0, width: 320, height: 248))
        preferredContentSize = view.frame.size
        setupViews()
    }

    deinit {
        resetTask?.cancel()
    }

    private func setupViews() {
        view.appearance = NSAppearance(named: .darkAqua)
        view.wantsLayer = true
        view.layer?.backgroundColor = MenuTokens.surfaceBackgroundNS.cgColor

        titleLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = MenuTokens.textPrimaryNS
        view.addSubview(titleLabel)

        subtitleLabel.font = NSFont.systemFont(ofSize: 11)
        subtitleLabel.textColor = MenuTokens.textSecondaryNS
        subtitleLabel.maximumNumberOfLines = 2
        view.addSubview(subtitleLabel)

        [folderRow, promptRow, futureRow].forEach { view.addSubview($0) }

        showFolderButton.target = self
        showFolderButton.action = #selector(showDraftFolder)
        view.addSubview(showFolderButton)

        copyPromptButton.target = self
        copyPromptButton.action = #selector(copyStarterPrompt)
        view.addSubview(copyPromptButton)
    }

    override func viewDidLayout() {
        super.viewDidLayout()

        let pad: CGFloat = 16
        let width = view.bounds.width - pad * 2
        var y: CGFloat = 16

        titleLabel.frame = NSRect(x: pad, y: y, width: width, height: 18)
        y += 24

        subtitleLabel.frame = NSRect(x: pad, y: y, width: width, height: 30)
        y += 38

        [folderRow, promptRow, futureRow].forEach { row in
            let rowHeight = row.intrinsicContentSize.height
            row.frame = NSRect(x: pad, y: y, width: width, height: rowHeight)
            y += rowHeight + 8
        }

        let buttonHeight = MenuTokens.secondaryButtonSize
        let showWidth = max(118, showFolderButton.fittingSize.width)
        let copyWidth = max(132, copyPromptButton.fittingSize.width)

        copyPromptButton.frame = NSRect(x: view.bounds.width - pad - copyWidth, y: y + 4, width: copyWidth, height: buttonHeight)
        showFolderButton.frame = NSRect(
            x: copyPromptButton.frame.minX - 8 - showWidth,
            y: y + 4,
            width: showWidth,
            height: buttonHeight
        )
    }

    @objc private func showDraftFolder() {
        let folder = AgentConnectGuide.draftFolder
        NSWorkspace.shared.activateFileViewerSelecting([folder])
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

private final class FlippedAgentConnectView: NSView {
    override var isFlipped: Bool { true }
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

    override func layout() {
        super.layout()
        symbolWellView.frame = NSRect(x: 12, y: 11, width: 22, height: 22)
        symbolView.frame = symbolWellView.bounds
        let textX = symbolWellView.frame.maxX + 10
        let textWidth = bounds.width - textX - 12
        titleLabel.frame = NSRect(x: textX, y: 9, width: textWidth, height: 14)
        bodyLabel.frame = NSRect(x: textX, y: 24, width: textWidth, height: 24)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 56)
    }
}
