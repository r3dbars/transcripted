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
        "Start with a simple prompt, then use MCP or the CLI if you want a deeper connection."
    )
    private let starterPromptLabel = NSTextField(labelWithString: "Start here")
    private let folderRow = AgentConnectInfoRowView(
        symbolName: "folder",
        title: "Show your folders",
        body: "Meetings and dictations are both saved locally on this Mac."
    )
    private let promptRow = AgentConnectInfoRowView(
        symbolName: "text.quote",
        title: "Works with any agent",
        body: "Copy a simple folder-based prompt for Claude, Codex, ChatGPT, or any local agent."
    )
    private let howToLabel = NSTextField(labelWithString: "Other ways to connect")
    private let stepOneRow = AgentConnectInfoRowView(
        symbolName: "1.circle",
        title: "1. Start with the prompt",
        body: "This is the simplest setup and the right default for most people."
    )
    private let stepTwoRow = AgentConnectInfoRowView(
        symbolName: "2.circle",
        title: "2. Use MCP if supported",
        body: "Supported agents can connect directly with read-only Transcripted tools."
    )
    private let stepThreeRow = AgentConnectInfoRowView(
        symbolName: "3.circle",
        title: "3. Use the CLI if you're advanced",
        body: "The CLI is best for scripts, automation, and offline audio work."
    )

    private let showFolderButton = MenuOutlineButton(
        title: "Show Transcripted folder",
        symbolName: "folder",
        accessibilityLabel: "Show Transcripted folder",
        toolTip: "Show Transcripted folder"
    )
    private let copyPromptButton = MenuOutlineButton(
        title: "Copy starter prompt",
        symbolName: "doc.on.doc",
        accessibilityLabel: "Copy starter prompt",
        toolTip: "Copy starter prompt"
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

        [starterPromptLabel, howToLabel].forEach { label in
            label.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            label.textColor = MenuTokens.textPrimaryNS
            addSubview(label)
        }
        [promptRow, folderRow, stepOneRow, stepTwoRow, stepThreeRow].forEach { addSubview($0) }

        backButton.target = self
        backButton.action = #selector(goBack)
        addSubview(backButton)

        showFolderButton.target = self
        showFolderButton.action = #selector(showAppSupportFolder)
        addSubview(showFolderButton)

        copyPromptButton.target = self
        copyPromptButton.action = #selector(copyStarterPrompt)
        addSubview(copyPromptButton)
    }

    override func layout() {
        super.layout()

        let pad: CGFloat = 0
        let width = bounds.width - pad * 2
        let inlineButtonSpacing: CGFloat = 8
        var y: CGFloat = 0

        let backWidth = max(72, backButton.fittingSize.width)
        backButton.frame = NSRect(x: pad, y: y, width: backWidth, height: MenuTokens.secondaryButtonSize)
        y += MenuTokens.secondaryButtonSize + 14

        titleLabel.frame = NSRect(x: pad, y: y, width: width, height: 22)
        y += 26

        subtitleLabel.frame = NSRect(x: pad, y: y, width: width, height: 42)
        y += 54

        starterPromptLabel.frame = NSRect(x: pad, y: y, width: width, height: 16)
        y += 22

        let copyPromptWidth = max(132, copyPromptButton.fittingSize.width)
        let promptRowWidth = max(180, width - copyPromptWidth - inlineButtonSpacing)
        promptRow.frame = NSRect(x: pad, y: y, width: promptRowWidth, height: AgentConnectInfoRowView.height)
        copyPromptButton.frame = NSRect(
            x: promptRow.frame.maxX + inlineButtonSpacing,
            y: y + 14,
            width: copyPromptWidth,
            height: MenuTokens.secondaryButtonSize
        )
        y += AgentConnectInfoRowView.height + 14

        let showFolderWidth = max(130, showFolderButton.fittingSize.width)
        let folderRowWidth = max(180, width - showFolderWidth - inlineButtonSpacing)
        folderRow.frame = NSRect(x: pad, y: y, width: folderRowWidth, height: AgentConnectInfoRowView.height)
        showFolderButton.frame = NSRect(
            x: folderRow.frame.maxX + inlineButtonSpacing,
            y: y + 14,
            width: showFolderWidth,
            height: MenuTokens.secondaryButtonSize
        )
        y += AgentConnectInfoRowView.height + 18

        howToLabel.frame = NSRect(x: pad, y: y, width: width, height: 16)
        y += 22

        [stepOneRow, stepTwoRow, stepThreeRow].forEach { row in
            let rowHeight = row.intrinsicContentSize.height
            row.frame = NSRect(x: pad, y: y, width: width, height: rowHeight)
            y += rowHeight + 8
        }

        y += 4
    }

    var intrinsicHeight: CGFloat {
        MenuTokens.secondaryButtonSize + 14 + 22 + 24 + 42 + 16 + 22 +
        (AgentConnectInfoRowView.height + 14) +
        (AgentConnectInfoRowView.height + 18) +
        22 + (AgentConnectInfoRowView.height + 8) * 3 + 12
    }

    @objc private func goBack() {
        onBack?()
    }

    @objc private func showAppSupportFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([AgentConnectionGuide.appSupportFolder])
    }

    @objc private func copyStarterPrompt() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(AgentConnectionGuide.starterPrompt(filename: nil), forType: .string)

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
        NSSize(width: NSView.noIntrinsicMetric, height: Self.height)
    }

    static var height: CGFloat {
        56
    }
}
