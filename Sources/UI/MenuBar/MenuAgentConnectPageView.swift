// MenuAgentConnectPageView.swift
// Full-page agent connection guide embedded inside the menubar panel.

import AppKit

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
        "Copy once, paste anywhere, and let your agent pick the best available Transcripted connection."
    )
    private let starterPromptLabel = NSTextField(labelWithString: "Starter skills")
    private let benefitOneRow = AgentConnectInfoRowView(
        symbolName: AgentConnectionGuide.starterSkills[0].symbolName,
        title: AgentConnectionGuide.starterSkills[0].title,
        body: AgentConnectionGuide.starterSkills[0].displayDetail
    )
    private let benefitTwoRow = AgentConnectInfoRowView(
        symbolName: AgentConnectionGuide.starterSkills[1].symbolName,
        title: AgentConnectionGuide.starterSkills[1].title,
        body: AgentConnectionGuide.starterSkills[1].displayDetail
    )
    private let manualSetupLabel = NSTextField(labelWithString: "Need manual setup?")
    private let mcpRow = AgentConnectInfoRowView(
        symbolName: "cable.connector",
        title: "Optional MCP setup",
        body: "Copy the MCP setup text only if your agent supports MCP and you want direct read-only tools."
    )
    private let folderRow = AgentConnectInfoRowView(
        symbolName: "folder",
        title: "Manual folders",
        body: "Use these only if you want to inspect or share the raw Transcripted paths yourself."
    )

    private let copyMCPButton = MenuOutlineButton(
        title: "Copy MCP setup",
        symbolName: "cable.connector",
        accessibilityLabel: "Copy MCP setup",
        toolTip: "Copy MCP setup"
    )
    private let copyFoldersButton = MenuOutlineButton(
        title: "Copy folder paths",
        symbolName: "folder",
        accessibilityLabel: "Copy folder paths",
        toolTip: "Copy folder paths"
    )
    private let copyPromptButton = MenuOutlineButton(
        title: "Copy agent prompt",
        symbolName: "doc.on.doc",
        accessibilityLabel: "Copy agent prompt",
        toolTip: "Copy agent prompt"
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

        [starterPromptLabel, manualSetupLabel].forEach { label in
            label.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            label.textColor = MenuTokens.textPrimaryNS
            addSubview(label)
        }
        [benefitOneRow, benefitTwoRow, mcpRow, folderRow].forEach { addSubview($0) }

        backButton.target = self
        backButton.action = #selector(goBack)
        addSubview(backButton)

        copyPromptButton.target = self
        copyPromptButton.action = #selector(copyStarterPrompt)
        addSubview(copyPromptButton)

        copyMCPButton.target = self
        copyMCPButton.action = #selector(copyMCPSetup)
        addSubview(copyMCPButton)

        copyFoldersButton.target = self
        copyFoldersButton.action = #selector(copyFolderPaths)
        addSubview(copyFoldersButton)
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
        benefitOneRow.frame = NSRect(x: pad, y: y, width: promptRowWidth, height: AgentConnectInfoRowView.height)
        copyPromptButton.frame = NSRect(
            x: benefitOneRow.frame.maxX + inlineButtonSpacing,
            y: y + 14,
            width: copyPromptWidth,
            height: MenuTokens.secondaryButtonSize
        )
        y += AgentConnectInfoRowView.height + 14

        benefitTwoRow.frame = NSRect(x: pad, y: y, width: width, height: AgentConnectInfoRowView.height)
        y += AgentConnectInfoRowView.height + 18

        manualSetupLabel.frame = NSRect(x: pad, y: y, width: width, height: 16)
        y += 22

        let copyMCPWidth = max(120, copyMCPButton.fittingSize.width)
        let mcpRowWidth = max(180, width - copyMCPWidth - inlineButtonSpacing)
        mcpRow.frame = NSRect(x: pad, y: y, width: mcpRowWidth, height: AgentConnectInfoRowView.height)
        copyMCPButton.frame = NSRect(
            x: mcpRow.frame.maxX + inlineButtonSpacing,
            y: y + 14,
            width: copyMCPWidth,
            height: MenuTokens.secondaryButtonSize
        )
        y += AgentConnectInfoRowView.height + 10

        let copyFoldersWidth = max(126, copyFoldersButton.fittingSize.width)
        let folderRowWidth = max(180, width - copyFoldersWidth - inlineButtonSpacing)
        folderRow.frame = NSRect(x: pad, y: y, width: folderRowWidth, height: AgentConnectInfoRowView.height)
        copyFoldersButton.frame = NSRect(
            x: folderRow.frame.maxX + inlineButtonSpacing,
            y: y + 14,
            width: copyFoldersWidth,
            height: MenuTokens.secondaryButtonSize
        )
        y += AgentConnectInfoRowView.height + 8

        y += 4
    }

    var intrinsicHeight: CGFloat {
        MenuTokens.secondaryButtonSize + 14 + 22 + 24 + 42 + 16 + 22 +
        (AgentConnectInfoRowView.height + 14) +
        (AgentConnectInfoRowView.height + 18) +
        22 +
        (AgentConnectInfoRowView.height + 10) +
        (AgentConnectInfoRowView.height + 8) + 12
    }

    @objc private func goBack() {
        onBack?()
    }

    @objc private func copyStarterPrompt() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(AgentConnectionGuide.starterPrompt(filename: nil), forType: .string)

        resetTask?.cancel()
        copyPromptButton.title = "Copied"
        copyPromptButton.setSymbol("checkmark", accessibilityLabel: "Agent prompt copied")
        resetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.copyPromptButton.title = "Copy agent prompt"
            self.copyPromptButton.setSymbol("doc.on.doc", accessibilityLabel: "Copy agent prompt")
        }
    }

    @objc private func copyMCPSetup() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(
            "\(AgentConnectionGuide.mcpSetupText)\n\n\(AgentConnectionGuide.mcpConfigExample)",
            forType: .string
        )

        resetTask?.cancel()
        copyMCPButton.title = "Copied"
        copyMCPButton.setSymbol("checkmark", accessibilityLabel: "MCP setup copied")
        resetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.copyMCPButton.title = "Copy MCP setup"
            self.copyMCPButton.setSymbol("cable.connector", accessibilityLabel: "Copy MCP setup")
        }
    }

    @objc private func copyFolderPaths() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(AgentConnectionGuide.folderPathsText, forType: .string)

        resetTask?.cancel()
        copyFoldersButton.title = "Copied"
        copyFoldersButton.setSymbol("checkmark", accessibilityLabel: "Folder paths copied")
        resetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.copyFoldersButton.title = "Copy folder paths"
            self.copyFoldersButton.setSymbol("folder", accessibilityLabel: "Copy folder paths")
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
