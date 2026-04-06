// OverlayHeaderView.swift
// Header bar for the floating overlay — status label, waveform, shortcut hint

import AppKit

@MainActor
final class OverlayHeaderView: NSView {
    private let modeLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    let waveformHost = WaveformHostView(frame: .zero)
    private let shortcutHint = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupViews() {
        // Mode label
        modeLabel.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
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

        // Shortcut hint
        shortcutHint.font = NSFont.systemFont(ofSize: 10, weight: .medium)
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

        // Waveform — fills space between mode label and hint
        if !waveformHost.isHidden {
            let waveLeft = modeLabel.frame.maxX + 8
            let waveRight: CGFloat = !shortcutHint.stringValue.isEmpty
                ? shortcutHint.frame.minX - 8
                : bounds.width - pad
            waveformHost.frame = NSRect(
                x: waveLeft,
                y: (h - 20) / 2,
                width: max(0, waveRight - waveLeft),
                height: 20
            )
        }
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
        let _ = transcriptExpanded
        let _ = draftShortcutHint
        // Mode label text + color
        switch (state, mode) {
        case (.listening, .dictation):
            modeLabel.stringValue = "Listening"
            modeLabel.textColor = OverlayTokens.textPrimary
        case (.drafting, .dictation):
            modeLabel.stringValue = "Transcribing"
            modeLabel.textColor = OverlayTokens.textPrimary
        case (.loading, _):
            modeLabel.stringValue = "Preparing"
            modeLabel.textColor = OverlayTokens.textSecondary
        case (.idle, _):
            modeLabel.stringValue = "Dictation"
            modeLabel.textColor = OverlayTokens.textMuted
        default:
            modeLabel.stringValue = "Dictation"
            modeLabel.textColor = OverlayTokens.textSecondary
        }

        // Spinner visibility
        let showSpinner = state == .drafting || state == .streaming || state == .loading
        spinner.isHidden = !showSpinner
        if showSpinner { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }

        // Waveform visibility
        let showWaveform = state == .listening
        waveformHost.isHidden = !showWaveform
        waveformHost.isActive = showWaveform

        // Shortcut hint
        switch (state, mode) {
        case (.listening, .dictation):
            shortcutHint.stringValue = "\(dictationShortcutHint) to stop"
            shortcutHint.textColor = OverlayTokens.textSecondary.withAlphaComponent(0.96)
        case (.loading, _):
            shortcutHint.stringValue = "Please wait"
            shortcutHint.textColor = OverlayTokens.textSecondary
        case (.drafting, .dictation):
            shortcutHint.stringValue = ""
            shortcutHint.textColor = OverlayTokens.textMuted
        default:
            shortcutHint.stringValue = ""
            shortcutHint.textColor = OverlayTokens.textMuted
        }

        needsLayout = true
    }
}
