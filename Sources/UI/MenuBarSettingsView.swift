// MenuBarSettingsView.swift
// Settings popover content: name, transcription engine, Gemini API key, shortcuts, feedback, quit

import AppKit

@MainActor
final class MenuBarSettingsView: NSView {
    private let titleLabel = NSTextField(labelWithString: "Settings")
    private let nameField = NSTextField()
    private let nameHint = NSTextField(labelWithString: "Used to identify your messages in screenshots")
    private let engineLabel = NSTextField(labelWithString: "Parakeet (CoreML)")
    private let engineHint = NSTextField(labelWithString: "CoreML Parakeet — local, ~0.2s latency")
    private let hotkeyRecorder = HotkeyRecorderAppKitView(frame: .zero)
    private let llmLabel = NSTextField(labelWithString: "")
    private let llmHint = NSTextField(labelWithString: "")
    private let feedbackButton = NSButton(title: "Send Feedback + Logs", target: nil, action: nil)
    private let copyLogsButton = NSButton(title: "Copy Logs", target: nil, action: nil)
    private let quitButton = NSButton(title: "Quit Draft", target: nil, action: nil)

    // Gemini API key section
    private let apiKeyField = NSSecureTextField()
    private let apiKeyStatus = NSTextField(labelWithString: "")
    private let apiKeyClearButton = NSButton(title: "Clear", target: nil, action: nil)

    weak var appState: DraftAppState?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupViews() {
        titleLabel.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        titleLabel.alignment = .center
        addSubview(titleLabel)

        // Name field
        let nameCaption = NSTextField(labelWithString: "Your Name")
        nameCaption.font = NSFont.systemFont(ofSize: 11)
        nameCaption.textColor = MenuTokens.textSecondaryNS
        nameCaption.tag = 100
        addSubview(nameCaption)

        nameField.stringValue = UserDefaults.standard.string(forKey: "user-display-name") ?? ""
        nameField.placeholderString = "Your name"
        nameField.font = NSFont.systemFont(ofSize: 13)
        nameField.bezelStyle = .roundedBezel
        nameField.target = self
        nameField.action = #selector(nameChanged)
        addSubview(nameField)

        nameHint.font = NSFont.systemFont(ofSize: 10)
        nameHint.textColor = MenuTokens.textSecondaryNS
        addSubview(nameHint)

        // Transcription engine
        let engineCaption = NSTextField(labelWithString: "Transcription Engine")
        engineCaption.font = NSFont.systemFont(ofSize: 11)
        engineCaption.textColor = MenuTokens.textSecondaryNS
        engineCaption.tag = 101
        addSubview(engineCaption)

        engineLabel.font = NSFont.systemFont(ofSize: 13)
        addSubview(engineLabel)

        engineHint.font = NSFont.systemFont(ofSize: 10)
        engineHint.textColor = MenuTokens.textSecondaryNS
        addSubview(engineHint)

        // Gemini API key
        let geminiCaption = NSTextField(labelWithString: "Drafting Engine")
        geminiCaption.font = NSFont.systemFont(ofSize: 11)
        geminiCaption.textColor = MenuTokens.textSecondaryNS
        geminiCaption.tag = 103
        addSubview(geminiCaption)

        apiKeyField.placeholderString = "Gemini API Key"
        apiKeyField.font = NSFont.systemFont(ofSize: 13)
        apiKeyField.bezelStyle = .roundedBezel
        apiKeyField.target = self
        apiKeyField.action = #selector(apiKeyChanged)
        addSubview(apiKeyField)

        apiKeyStatus.font = NSFont.systemFont(ofSize: 10)
        addSubview(apiKeyStatus)

        apiKeyClearButton.bezelStyle = .rounded
        apiKeyClearButton.controlSize = .small
        apiKeyClearButton.font = NSFont.systemFont(ofSize: 10)
        apiKeyClearButton.target = self
        apiKeyClearButton.action = #selector(clearAPIKey)
        addSubview(apiKeyClearButton)

        updateAPIKeyStatus()

        // Keyboard shortcuts
        let shortcutCaption = NSTextField(labelWithString: "Keyboard Shortcuts")
        shortcutCaption.font = NSFont.systemFont(ofSize: 11)
        shortcutCaption.textColor = MenuTokens.textSecondaryNS
        shortcutCaption.tag = 102
        addSubview(shortcutCaption)

        addSubview(hotkeyRecorder)

        // LLM status
        llmLabel.font = NSFont.systemFont(ofSize: 11)
        llmLabel.textColor = MenuTokens.textSecondaryNS
        llmLabel.alignment = .center
        addSubview(llmLabel)

        llmHint.font = NSFont.systemFont(ofSize: 10)
        llmHint.textColor = MenuTokens.textSecondaryNS
        llmHint.alignment = .center
        addSubview(llmHint)

        // Feedback
        feedbackButton.bezelStyle = .rounded
        feedbackButton.target = self
        feedbackButton.action = #selector(sendFeedback)
        addSubview(feedbackButton)

        copyLogsButton.bezelStyle = .rounded
        copyLogsButton.target = self
        copyLogsButton.action = #selector(copyLogs)
        addSubview(copyLogsButton)

        // Quit
        quitButton.bezelStyle = .rounded
        quitButton.target = self
        quitButton.action = #selector(quitApp)
        addSubview(quitButton)
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let pad: CGFloat = 20
        let contentW = w - pad * 2
        var y = bounds.height - pad

        // Title
        y -= 20
        titleLabel.frame = NSRect(x: pad, y: y, width: contentW, height: 20)

        // Name section
        y -= 28
        viewWithTag(100)?.frame = NSRect(x: pad, y: y, width: contentW, height: 14)
        y -= 24
        nameField.frame = NSRect(x: pad, y: y, width: contentW, height: 22)
        y -= 16
        nameHint.frame = NSRect(x: pad, y: y, width: contentW, height: 14)

        // Divider
        y -= 16

        // Engine section
        y -= 14
        viewWithTag(101)?.frame = NSRect(x: pad, y: y, width: contentW, height: 14)
        y -= 18
        engineLabel.frame = NSRect(x: pad, y: y, width: contentW, height: 16)
        y -= 16
        engineHint.frame = NSRect(x: pad, y: y, width: contentW, height: 14)

        // Divider
        y -= 16

        // Gemini API key section
        y -= 14
        viewWithTag(103)?.frame = NSRect(x: pad, y: y, width: contentW, height: 14)
        y -= 24
        let clearW: CGFloat = 50
        apiKeyField.frame = NSRect(x: pad, y: y, width: contentW - clearW - 6, height: 22)
        apiKeyClearButton.frame = NSRect(x: pad + contentW - clearW, y: y, width: clearW, height: 22)
        y -= 16
        apiKeyStatus.frame = NSRect(x: pad, y: y, width: contentW, height: 14)

        // Divider
        y -= 16

        // Shortcuts section
        y -= 14
        viewWithTag(102)?.frame = NSRect(x: pad, y: y, width: contentW, height: 14)
        y -= 76
        hotkeyRecorder.frame = NSRect(x: pad, y: y, width: contentW, height: 76)

        // Divider
        y -= 16

        // LLM status
        y -= 16
        llmLabel.frame = NSRect(x: pad, y: y, width: contentW, height: 14)
        y -= 16
        llmHint.frame = NSRect(x: pad, y: y, width: contentW, height: 14)

        // Divider
        y -= 16

        // Feedback buttons
        let btnW: CGFloat = (contentW - 8) / 2
        y -= 24
        feedbackButton.frame = NSRect(x: pad, y: y, width: btnW, height: 24)
        copyLogsButton.frame = NSRect(x: pad + btnW + 8, y: y, width: btnW, height: 24)

        // Divider
        y -= 24

        // Quit
        quitButton.frame = NSRect(x: pad + (contentW - 100) / 2, y: max(pad, y), width: 100, height: 24)
    }

    func update(llmStatus: String) {
        if GeminiEngine.isAvailable {
            llmLabel.stringValue = "Drafting: Gemini 3 Flash"
            llmHint.stringValue = "Cloud drafting — local model used for style learning"
        } else {
            llmLabel.stringValue = "LLM: \(llmStatus)"
            llmHint.stringValue = "Add a Gemini API key above for cloud drafting"
        }
    }

    func updateAPIKeyStatus() {
        if GeminiEngine.hasAPIKey {
            apiKeyStatus.stringValue = "Gemini API key saved"
            apiKeyStatus.textColor = NSColor.systemGreen
            apiKeyClearButton.isHidden = false
        } else {
            apiKeyStatus.stringValue = "Free at aistudio.google.com"
            apiKeyStatus.textColor = MenuTokens.textSecondaryNS
            apiKeyClearButton.isHidden = true
        }
    }

    @objc private func nameChanged() {
        let trimmed = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            UserDefaults.standard.set(trimmed, forKey: "user-display-name")
        }
    }

    @objc private func apiKeyChanged() {
        let key = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            GeminiEngine.saveAPIKey(key)
            apiKeyField.stringValue = ""
            updateAPIKeyStatus()
        }
    }

    @objc private func clearAPIKey() {
        GeminiEngine.deleteAPIKey()
        updateAPIKeyStatus()
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
}
