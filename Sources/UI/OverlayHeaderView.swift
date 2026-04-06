// OverlayHeaderView.swift
// Header bar for the floating overlay — mode label, waveform, chevron, shortcut hint

import AppKit

@MainActor
final class OverlayHeaderView: NSView {
    private let modeLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    let waveformHost = WaveformHostView(frame: .zero)
    private let chevronButton = NSButton()
    private let shortcutHint = NSTextField(labelWithString: "")

    /// Called when user clicks the chevron to expand/collapse transcript
    var onToggleTranscript: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupViews() {
        // Mode label
        modeLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        modeLabel.textColor = OverlayTokens.textSecondary
        modeLabel.isBezeled = false
        modeLabel.isEditable = false
        modeLabel.drawsBackground = false
        modeLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        addSubview(modeLabel)

        // Spinner (hidden by default)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isHidden = true
        addSubview(spinner)

        // Waveform (hidden by default)
        waveformHost.isHidden = true
        addSubview(waveformHost)

        // Chevron button (hidden by default)
        chevronButton.bezelStyle = .inline
        chevronButton.isBordered = false
        chevronButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Expand")
        chevronButton.contentTintColor = OverlayTokens.textMuted
        chevronButton.target = self
        chevronButton.action = #selector(chevronTapped)
        chevronButton.isHidden = true
        addSubview(chevronButton)

        // Shortcut hint
        shortcutHint.font = NSFont.systemFont(ofSize: 10)
        shortcutHint.textColor = OverlayTokens.textMuted
        shortcutHint.isBezeled = false
        shortcutHint.isEditable = false
        shortcutHint.drawsBackground = false
        shortcutHint.alignment = .right
        shortcutHint.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        addSubview(shortcutHint)
    }

    override func layout() {
        super.layout()
        let pad = OverlayTokens.contentPadding
        let h = bounds.height
        let labelSize = modeLabel.fittingSize
        let hintSize = shortcutHint.fittingSize

        // Mode label — left aligned, vertically centered
        modeLabel.frame = NSRect(
            x: pad,
            y: (h - labelSize.height) / 2,
            width: labelSize.width,
            height: labelSize.height
        )

        // Spinner — right of mode label
        let spinnerSize: CGFloat = 16
        if !spinner.isHidden {
            spinner.frame = NSRect(
                x: modeLabel.frame.maxX + 6,
                y: (h - spinnerSize) / 2,
                width: spinnerSize,
                height: spinnerSize
            )
        }

        // Shortcut hint — right aligned
        shortcutHint.frame = NSRect(
            x: bounds.width - pad - hintSize.width,
            y: (h - hintSize.height) / 2,
            width: hintSize.width,
            height: hintSize.height
        )

        // Chevron — left of shortcut hint (or right edge if no hint)
        let chevronSize: CGFloat = 20
        if !chevronButton.isHidden {
            let chevronX = shortcutHint.stringValue.isEmpty
                ? bounds.width - pad - chevronSize
                : shortcutHint.frame.minX - chevronSize - 4
            chevronButton.frame = NSRect(
                x: chevronX,
                y: (h - chevronSize) / 2,
                width: chevronSize,
                height: chevronSize
            )
        }

        // Waveform — fills space between mode label and chevron/hint
        if !waveformHost.isHidden {
            let waveLeft = modeLabel.frame.maxX + 8
            let waveRight: CGFloat
            if !chevronButton.isHidden {
                waveRight = chevronButton.frame.minX - 4
            } else if !shortcutHint.stringValue.isEmpty {
                waveRight = shortcutHint.frame.minX - 8
            } else {
                waveRight = bounds.width - pad
            }
            waveformHost.frame = NSRect(
                x: waveLeft,
                y: (h - 20) / 2,
                width: max(0, waveRight - waveLeft),
                height: 20
            )
        }
    }

    @objc private func chevronTapped() {
        onToggleTranscript?()
    }

    // MARK: - Update Methods

    func updateWaveformLevel(_ level: Float) {
        waveformHost.level = level
    }

    func update(
        state: FloatingOverlayController.OverlayState,
        mode: FloatingOverlayController.SessionMode,
        transcriptExpanded: Bool,
        draftShortcutHint: String,
        dictationShortcutHint: String
    ) {
        // Mode label text + color
        switch (state, mode) {
        case (.listening, .draft):
            modeLabel.stringValue = "Draft"
            modeLabel.textColor = OverlayTokens.textSecondary
        case (.listening, .dictation):
            modeLabel.stringValue = "Dictate"
            modeLabel.textColor = OverlayTokens.textSecondary
        case (.drafting, .dictation):
            modeLabel.stringValue = "Polishing..."
            modeLabel.textColor = OverlayTokens.textPrimary
        case (.drafting, _), (.streaming, _):
            modeLabel.stringValue = "Drafting..."
            modeLabel.textColor = OverlayTokens.textSecondary
        case (.loading, _):
            modeLabel.stringValue = "Loading voice model..."
            modeLabel.textColor = OverlayTokens.textSecondary
        case (.review, _):
            modeLabel.stringValue = "Draft"
            modeLabel.textColor = OverlayTokens.textSecondary
        case (.diffFlash, _):
            modeLabel.stringValue = "Review Edits"
            modeLabel.textColor = OverlayTokens.accentGreen
        case (.idle, _):
            modeLabel.stringValue = "Draft"
            modeLabel.textColor = OverlayTokens.textMuted
        }

        // Spinner visibility
        let showSpinner = state == .drafting || state == .streaming || state == .loading
        spinner.isHidden = !showSpinner
        if showSpinner { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }

        // Waveform visibility
        let showWaveform = state == .listening
        waveformHost.isHidden = !showWaveform
        waveformHost.isActive = showWaveform

        // Dictation is now intentionally compact: waveform + timer/shortcut
        // provide enough confidence without opening a live transcript pane.
        chevronButton.isHidden = !(state == .listening && mode == .draft)
        let chevronImage = transcriptExpanded ? "chevron.up" : "chevron.down"
        chevronButton.image = NSImage(systemSymbolName: chevronImage, accessibilityDescription: nil)

        // Shortcut hint
        switch (state, mode) {
        case (.listening, .draft):
            shortcutHint.stringValue = "\(draftShortcutHint) to stop"
        case (.listening, .dictation):
            shortcutHint.stringValue = "\(dictationShortcutHint) to stop"
        case (.loading, _):
            shortcutHint.stringValue = "Esc to cancel"
        default:
            shortcutHint.stringValue = ""
        }

        needsLayout = true
    }
}
