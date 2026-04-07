// MenuBarSettingsView.swift
// Compact utility footer for the menubar popover.

import AppKit

@MainActor
final class MenuBarSettingsView: NSView {
    private let connectAgentButton = MenuOutlineButton(
        title: "Connect your agent",
        symbolName: "sparkles",
        accessibilityLabel: "Connect your agent",
        toolTip: "Connect your agent"
    )
    private let settingsButton = MenuIconButton(
        symbolName: "gearshape",
        accessibilityLabel: "Open settings",
        toolTip: "Open settings"
    )
    private let feedbackButton = MenuIconButton(
        symbolName: "bubble.left",
        accessibilityLabel: "Send feedback",
        toolTip: "Send feedback"
    )
    private let quitButton = MenuIconButton(
        symbolName: "power",
        accessibilityLabel: "Quit Transcripted",
        toolTip: "Quit Transcripted"
    )

    weak var appState: DraftAppState?
    var onOpenSettings: (() -> Void)?
    private lazy var connectPopover: NSPopover = {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = MenuAgentConnectPopoverController()
        return popover
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func setupViews() {
        connectAgentButton.target = self
        connectAgentButton.action = #selector(toggleConnectPopover)
        addSubview(connectAgentButton)

        [settingsButton, feedbackButton, quitButton].forEach { addSubview($0) }

        settingsButton.target = self
        settingsButton.action = #selector(openSettings)
        feedbackButton.target = self
        feedbackButton.action = #selector(sendFeedback)
        quitButton.target = self
        quitButton.action = #selector(quitApp)
    }

    override func layout() {
        super.layout()

        let buttonSize = MenuTokens.secondaryButtonSize
        quitButton.frame = NSRect(x: bounds.width - buttonSize, y: 0, width: buttonSize, height: buttonSize)
        feedbackButton.frame = NSRect(
            x: quitButton.frame.minX - 8 - buttonSize,
            y: 0,
            width: buttonSize,
            height: buttonSize
        )
        settingsButton.frame = NSRect(
            x: feedbackButton.frame.minX - 8 - buttonSize,
            y: 0,
            width: buttonSize,
            height: buttonSize
        )

        let connectWidth = min(max(150, connectAgentButton.fittingSize.width), max(0, settingsButton.frame.minX - 12))
        connectAgentButton.frame = NSRect(x: 0, y: 0, width: connectWidth, height: buttonSize)
    }

    @objc private func sendFeedback() {
        guard let appState else { return }
        let logLines = appState.logger.entries.suffix(80).joined(separator: "\n")
        let subject = "Transcripted Feedback"
        let body = "What happened:\n[describe the issue here]\n\n---\nLogs:\n\(logLines)"
        let encodedSubject = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? subject
        let encodedBody = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let url = URL(string: "mailto:hi@transcripted.app?subject=\(encodedSubject)&body=\(encodedBody)") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }

    @objc private func toggleConnectPopover() {
        if connectPopover.isShown {
            connectPopover.performClose(nil)
            return
        }
        connectPopover.show(relativeTo: connectAgentButton.bounds, of: connectAgentButton, preferredEdge: .maxY)
    }

    func dismissTransientUI() {
        connectPopover.performClose(nil)
    }

    var intrinsicHeight: CGFloat { MenuTokens.secondaryButtonSize }
}
