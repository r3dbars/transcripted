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
        "Point your agent at local Transcripted transcripts on this Mac."
    )
    private let starterPromptLabel = NSTextField(labelWithString: "Starter prompt")
    private let folderRow = AgentConnectInfoRowView(
        symbolName: "folder",
        title: "Data source",
        body: "Meetings and dictations are both available in this local folder."
    )
    private let promptRow = AgentConnectInfoRowView(
        symbolName: "text.quote",
        title: "Copy starter prompt",
        body: "Paste this into Claude, Codex, or any local agent."
    )
    private let howToLabel = NSTextField(labelWithString: "How to use it")
    private let stepOneRow = AgentConnectInfoRowView(
        symbolName: "1.circle",
        title: "1. Copy",
        body: "Copy the starter prompt."
    )
    private let stepTwoRow = AgentConnectInfoRowView(
        symbolName: "2.circle",
        title: "2. Paste",
        body: "Paste it into your agent's prompt."
    )
    private let stepThreeRow = AgentConnectInfoRowView(
        symbolName: "3.circle",
        title: "3. Ask",
        body: "Ask for summaries, action items, or decisions."
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

        starterPromptLabel.frame = NSRect(x: pad, y: y, width: width, height: 16)
        y += 22

        promptRow.frame = NSRect(x: pad, y: y, width: width, height: AgentConnectInfoRowView.height)
        copyPromptButton.frame = NSRect(
            x: bounds.width - copyPromptButton.fittingSize.width,
            y: y + 14,
            width: max(132, copyPromptButton.fittingSize.width),
            height: MenuTokens.secondaryButtonSize
        )
        y += AgentConnectInfoRowView.height + 14

        folderRow.frame = NSRect(x: pad, y: y, width: width, height: AgentConnectInfoRowView.height)
        showFolderButton.frame = NSRect(
            x: bounds.width - showFolderButton.fittingSize.width,
            y: y + 14,
            width: max(130, showFolderButton.fittingSize.width),
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
        let url = FileManager.default.transcriptedAppSupportDir
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

        You also have dictation transcripts here:
        \(dictationsFolder.path)

        Prompt:
        Use the folder at this path for both:
        - meetings: \(meetingsFolder.path)
        - dictations: \(dictationsFolder.path)
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
        NSSize(width: NSView.noIntrinsicMetric, height: Self.height)
    }

    static var height: CGFloat {
        56
    }
}
