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
        AgentConnectionGuide.headerSummary
    )
    private let starterPromptLabel = NSTextField(labelWithString: "Start here")
    private let starterPromptBodyLabel = NSTextField(wrappingLabelWithString:
        AgentConnectionGuide.primarySetupSummary
    )
    private let manualSetupLabel = NSTextField(labelWithString: "Manual setup")
    private let manualSetupBodyLabel = NSTextField(wrappingLabelWithString:
        AgentConnectionGuide.manualSetupSummary
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
        title: "Copy prompt",
        symbolName: "doc.on.doc",
        accessibilityLabel: "Copy agent prompt",
        toolTip: "Copy agent prompt",
        style: .accent
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
        subtitleLabel.maximumNumberOfLines = 2
        addSubview(subtitleLabel)

        [starterPromptLabel, manualSetupLabel].forEach { label in
            label.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            label.textColor = MenuTokens.textPrimaryNS
            addSubview(label)
        }

        [starterPromptBodyLabel, manualSetupBodyLabel].forEach { label in
            label.font = NSFont.systemFont(ofSize: 10)
            label.textColor = MenuTokens.textSecondaryNS
            label.maximumNumberOfLines = 3
            addSubview(label)
        }

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
        var y: CGFloat = 0

        let backWidth = max(72, backButton.fittingSize.width)
        backButton.frame = NSRect(x: pad, y: y, width: backWidth, height: MenuTokens.secondaryButtonSize)
        y += MenuTokens.secondaryButtonSize + 14

        titleLabel.frame = NSRect(x: pad, y: y, width: width, height: 22)
        y += 26

        subtitleLabel.frame = NSRect(x: pad, y: y, width: width, height: 28)
        y += 40

        starterPromptLabel.frame = NSRect(x: pad, y: y, width: width, height: 16)
        y += 22

        starterPromptBodyLabel.frame = NSRect(x: pad, y: y, width: width, height: 28)
        y += 36

        copyPromptButton.frame = NSRect(
            x: pad,
            y: y,
            width: width,
            height: MenuTokens.secondaryButtonSize
        )
        y += MenuTokens.secondaryButtonSize + 18

        manualSetupLabel.frame = NSRect(x: pad, y: y, width: width, height: 16)
        y += 22

        manualSetupBodyLabel.frame = NSRect(x: pad, y: y, width: width, height: 28)
        y += 36

        copyMCPButton.frame = NSRect(
            x: pad,
            y: y,
            width: width,
            height: MenuTokens.secondaryButtonSize
        )
        y += MenuTokens.secondaryButtonSize + 8

        copyFoldersButton.frame = NSRect(
            x: pad,
            y: y,
            width: width,
            height: MenuTokens.secondaryButtonSize
        )
        y += MenuTokens.secondaryButtonSize + 4
    }

    var intrinsicHeight: CGFloat {
        MenuTokens.secondaryButtonSize + 14 +
        26 +
        40 +
        22 +
        36 +
        MenuTokens.secondaryButtonSize + 18 +
        22 +
        36 +
        MenuTokens.secondaryButtonSize + 8 +
        MenuTokens.secondaryButtonSize + 4
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
            self.copyPromptButton.title = "Copy prompt"
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
