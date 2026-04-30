// MenuBarSettingsView.swift
// Compact utility footer for the menubar popover.

import AppKit

@MainActor
final class MenuBarSettingsView: NSView {
    private let connectAgentButton = MenuOutlineButton(
        title: "Connect your agent",
        symbolName: "sparkles",
        accessibilityLabel: "Connect your agent",
        toolTip: "Connect your agent",
        style: .accent
    )
    private let settingsButton = MenuIconButton(
        symbolName: "gearshape",
        accessibilityLabel: "Settings",
        toolTip: "Settings"
    )
    private let updatesButton = MenuIconButton(
        symbolName: "arrow.triangle.2.circlepath.circle",
        accessibilityLabel: "Check for updates",
        toolTip: "Check for updates"
    )
    private let feedbackButton = MenuIconButton(
        symbolName: "bubble.left",
        accessibilityLabel: "Submit feedback for support",
        toolTip: "Submit feedback for support"
    )
    private let quitButton = MenuIconButton(
        symbolName: "power",
        accessibilityLabel: "Quit Transcripted",
        toolTip: "Quit Transcripted"
    )

    weak var appState: TranscriptedAppState?
    var onOpenSettings: (() -> Void)?
    var onCheckForUpdates: (() -> Void)?
    var onOpenAgentConnect: (() -> Void)?
    var onOpenSupport: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func setupViews() {
        connectAgentButton.target = self
        connectAgentButton.action = #selector(openAgentConnect)
        addSubview(connectAgentButton)

        [settingsButton, updatesButton, feedbackButton, quitButton].forEach { addSubview($0) }

        settingsButton.target = self
        settingsButton.action = #selector(openSettings)
        updatesButton.target = self
        updatesButton.action = #selector(checkForUpdates)
        feedbackButton.target = self
        feedbackButton.action = #selector(openSupport)
        quitButton.target = self
        quitButton.action = #selector(quitApp)
    }

    override func layout() {
        super.layout()

        let buttonSize = MenuTokens.secondaryButtonSize
        let buttonY: CGFloat = 7
        quitButton.frame = NSRect(x: bounds.width - buttonSize, y: buttonY, width: buttonSize, height: buttonSize)
        feedbackButton.frame = NSRect(
            x: quitButton.frame.minX - 8 - buttonSize,
            y: buttonY,
            width: buttonSize,
            height: buttonSize
        )
        updatesButton.frame = NSRect(
            x: feedbackButton.frame.minX - 8 - buttonSize,
            y: buttonY,
            width: buttonSize,
            height: buttonSize
        )
        settingsButton.frame = NSRect(
            x: updatesButton.frame.minX - 8 - buttonSize,
            y: buttonY,
            width: buttonSize,
            height: buttonSize
        )

        let connectWidth = min(max(150, connectAgentButton.fittingSize.width), max(0, settingsButton.frame.minX - 12))
        connectAgentButton.frame = NSRect(x: 0, y: buttonY, width: connectWidth, height: buttonSize)
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }

    @objc private func checkForUpdates() {
        onCheckForUpdates?()
    }

    @objc private func openAgentConnect() {
        onOpenAgentConnect?()
    }

    @objc private func openSupport() {
        onOpenSupport?()
    }

    func dismissTransientUI() {}

    var intrinsicHeight: CGFloat { MenuTokens.secondaryButtonSize + 8 }
}
