// MenuBarSettingsView.swift
// Compact settings section embedded directly into the main menubar view.

import AppKit

@MainActor
final class MenuBarSettingsView: NSView {
    private let titleLabel = NSTextField(labelWithString: "Settings")
    private let engineLabel = NSTextField(labelWithString: "Parakeet (CoreML)")
    private let engineHint = NSTextField(labelWithString: "Local speech model for dictation and meetings")
    private let hotkeyRecorder = HotkeyRecorderAppKitView(frame: .zero)
    private let feedbackButton = NSButton(title: "Send Feedback + Logs", target: nil, action: nil)
    private let copyLogsButton = NSButton(title: "Copy Logs", target: nil, action: nil)
    private let quitButton = NSButton(title: "Quit Draft", target: nil, action: nil)

    weak var appState: DraftAppState?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupViews() {
        wantsLayer = true
        layer?.cornerRadius = MenuTokens.cardCornerRadius
        layer?.backgroundColor = MenuTokens.cardBackgroundNS.cgColor
        layer?.borderColor = MenuTokens.cardBorderNS.cgColor
        layer?.borderWidth = 1

        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = MenuTokens.textPrimaryNS
        addSubview(titleLabel)

        let engineCaption = NSTextField(labelWithString: "Speech model")
        engineCaption.font = NSFont.systemFont(ofSize: 10)
        engineCaption.textColor = MenuTokens.textSecondaryNS
        engineCaption.tag = 101
        addSubview(engineCaption)

        engineLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        engineLabel.textColor = MenuTokens.textPrimaryNS
        addSubview(engineLabel)

        engineHint.font = NSFont.systemFont(ofSize: 9)
        engineHint.textColor = MenuTokens.textSecondaryNS
        addSubview(engineHint)

        let shortcutCaption = NSTextField(labelWithString: "Shortcuts")
        shortcutCaption.font = NSFont.systemFont(ofSize: 10)
        shortcutCaption.textColor = MenuTokens.textSecondaryNS
        shortcutCaption.tag = 102
        addSubview(shortcutCaption)

        addSubview(hotkeyRecorder)

        // Feedback
        feedbackButton.bezelStyle = .rounded
        feedbackButton.font = NSFont.systemFont(ofSize: 11)
        feedbackButton.target = self
        feedbackButton.action = #selector(sendFeedback)
        addSubview(feedbackButton)

        copyLogsButton.bezelStyle = .rounded
        copyLogsButton.font = NSFont.systemFont(ofSize: 11)
        copyLogsButton.target = self
        copyLogsButton.action = #selector(copyLogs)
        addSubview(copyLogsButton)

        quitButton.bezelStyle = .inline
        quitButton.isBordered = false
        quitButton.font = NSFont.systemFont(ofSize: 11)
        quitButton.contentTintColor = MenuTokens.textSecondaryNS
        quitButton.target = self
        quitButton.action = #selector(quitApp)
        addSubview(quitButton)
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let pad: CGFloat = 12
        let contentW = w - pad * 2
        var y = bounds.height - pad

        y -= 16
        titleLabel.frame = NSRect(x: pad, y: y, width: contentW, height: 16)

        y -= 22
        viewWithTag(101)?.frame = NSRect(x: pad, y: y, width: contentW, height: 12)
        y -= 16
        engineLabel.frame = NSRect(x: pad, y: y, width: contentW, height: 14)
        y -= 14
        engineHint.frame = NSRect(x: pad, y: y, width: contentW, height: 12)

        y -= 18
        viewWithTag(102)?.frame = NSRect(x: pad, y: y, width: contentW, height: 12)
        y -= hotkeyRecorder.intrinsicHeight + 6
        hotkeyRecorder.frame = NSRect(x: pad, y: y, width: contentW, height: 76)

        y -= 14
        let btnW: CGFloat = (contentW - 8) / 2
        y -= 24
        feedbackButton.frame = NSRect(x: pad, y: y, width: btnW, height: 24)
        copyLogsButton.frame = NSRect(x: pad + btnW + 8, y: y, width: btnW, height: 24)

        y -= 24
        let quitSize = quitButton.fittingSize
        quitButton.frame = NSRect(x: pad, y: max(pad - 2, y), width: quitSize.width, height: quitSize.height)
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

    @objc private func copyLogs() {
        guard let appState = appState else { return }
        let logText = appState.logger.entries.suffix(200).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(logText, forType: .string)
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    var intrinsicHeight: CGFloat { 196 }
}
