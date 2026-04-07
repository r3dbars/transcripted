// MenuBarSettingsView.swift
// Tiny utility footer for the menubar popover.

import AppKit

@MainActor
final class MenuBarSettingsView: NSView {
    private let footerLabel = NSTextField(labelWithString: "Runs locally on your Mac")
    private let resetButton = NSButton(title: "Reset shortcuts", target: nil, action: nil)
    private let feedbackButton = NSButton(title: "Feedback", target: nil, action: nil)
    private let quitButton = NSButton(title: "Quit", target: nil, action: nil)

    weak var appState: DraftAppState?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func setupViews() {
        footerLabel.font = NSFont.systemFont(ofSize: 10)
        footerLabel.textColor = MenuTokens.textMutedNS
        addSubview(footerLabel)

        [resetButton, feedbackButton, quitButton].forEach { button in
            button.isBordered = false
            button.bezelStyle = .inline
            button.font = NSFont.systemFont(ofSize: 10)
            button.contentTintColor = MenuTokens.textSecondaryNS
            addSubview(button)
        }

        resetButton.target = self
        resetButton.action = #selector(resetShortcuts)
        feedbackButton.target = self
        feedbackButton.action = #selector(sendFeedback)
        quitButton.target = self
        quitButton.action = #selector(quitApp)
    }

    override func layout() {
        super.layout()

        footerLabel.frame = NSRect(x: 0, y: 2, width: 140, height: 12)

        let quitSize = quitButton.fittingSize
        quitButton.frame = NSRect(x: bounds.width - quitSize.width, y: 0, width: quitSize.width, height: quitSize.height)
        let feedbackSize = feedbackButton.fittingSize
        feedbackButton.frame = NSRect(x: quitButton.frame.minX - 14 - feedbackSize.width, y: 0, width: feedbackSize.width, height: feedbackSize.height)
        let resetSize = resetButton.fittingSize
        resetButton.frame = NSRect(x: feedbackButton.frame.minX - 14 - resetSize.width, y: 0, width: resetSize.width, height: resetSize.height)
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

    @objc private func resetShortcuts() {
        HotkeyPreferences.resetToDefaults()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    var intrinsicHeight: CGFloat { 18 }
}
