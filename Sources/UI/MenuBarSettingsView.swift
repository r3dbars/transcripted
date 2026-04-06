// MenuBarSettingsView.swift
// Compact settings section embedded directly into the main menubar view.

import AppKit

@MainActor
final class MenuBarSettingsView: NSView {
    private let footerLabel = NSTextField(labelWithString: "Runs locally on your Mac")
    private let resetButton = NSButton(title: "Reset Shortcuts", target: nil, action: nil)
    private let feedbackButton = NSButton(title: "Send Feedback", target: nil, action: nil)
    private let quitButton = NSButton(title: "Quit Draft", target: nil, action: nil)

    weak var appState: DraftAppState?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupViews() {
        footerLabel.font = NSFont.systemFont(ofSize: 10)
        footerLabel.textColor = MenuTokens.textMutedNS
        addSubview(footerLabel)

        resetButton.bezelStyle = .inline
        resetButton.isBordered = false
        resetButton.font = NSFont.systemFont(ofSize: 10)
        resetButton.contentTintColor = MenuTokens.textSecondaryNS
        resetButton.target = self
        resetButton.action = #selector(resetShortcuts)
        addSubview(resetButton)

        feedbackButton.bezelStyle = .inline
        feedbackButton.isBordered = false
        feedbackButton.font = NSFont.systemFont(ofSize: 10)
        feedbackButton.contentTintColor = MenuTokens.textSecondaryNS
        feedbackButton.target = self
        feedbackButton.action = #selector(sendFeedback)
        addSubview(feedbackButton)

        quitButton.bezelStyle = .inline
        quitButton.isBordered = false
        quitButton.font = NSFont.systemFont(ofSize: 10)
        quitButton.contentTintColor = MenuTokens.textSecondaryNS
        quitButton.target = self
        quitButton.action = #selector(quitApp)
        addSubview(quitButton)
    }

    override func layout() {
        super.layout()
        footerLabel.frame = NSRect(x: 0, y: bounds.height - 12, width: bounds.width, height: 12)

        let quitSize = quitButton.fittingSize
        quitButton.frame = NSRect(x: bounds.width - quitSize.width, y: 0, width: quitSize.width, height: quitSize.height)
        let feedbackSize = feedbackButton.fittingSize
        feedbackButton.frame = NSRect(x: quitButton.frame.minX - 14 - feedbackSize.width, y: 0, width: feedbackSize.width, height: feedbackSize.height)
        let resetSize = resetButton.fittingSize
        resetButton.frame = NSRect(x: feedbackButton.frame.minX - 14 - resetSize.width, y: 0, width: resetSize.width, height: resetSize.height)
    }

    @objc private func sendFeedback() {
        guard let appState = appState else { return }
        let logLines = appState.logger.entries.suffix(80).joined(separator: "\n")
        let subject = "Draft Feedback"
        let body = "What happened:\n[describe the issue here]\n\n---\nLogs:\n\(logLines)"
        let encodedSubject = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? subject
        let encodedBody = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let url = URL(string: "mailto:hi@draftapp.com?subject=\(encodedSubject)&body=\(encodedBody)") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func resetShortcuts() {
        HotkeyPreferences.resetToDefaults()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    var intrinsicHeight: CGFloat { 26 }
}
