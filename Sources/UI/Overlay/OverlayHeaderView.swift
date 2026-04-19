// OverlayHeaderView.swift
// Header bar for the floating overlay — status label, waveform, shortcut hint

import AppKit

@MainActor
private final class OverlayPrimaryButton: NSButton {
    override var title: String {
        didSet {
            updateTitleAppearance()
            invalidateIntrinsicContentSize()
        }
    }

    override var intrinsicContentSize: NSSize {
        let base = super.intrinsicContentSize
        return NSSize(width: base.width + 16, height: max(24, base.height + 6))
    }

    override var isHighlighted: Bool {
        didSet { updateLayerAppearance() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func commonInit() {
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryPushIn)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        focusRingType = .none
        updateTitleAppearance()
        updateLayerAppearance()
    }

    private func updateTitleAppearance() {
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.black.withAlphaComponent(0.88)
            ]
        )
    }

    private func updateLayerAppearance() {
        layer?.backgroundColor = (isHighlighted
            ? NSColor.white.withAlphaComponent(0.78)
            : NSColor.white.withAlphaComponent(0.94)
        ).cgColor
        layer?.borderColor = NSColor.black.withAlphaComponent(0.10).cgColor
    }
}

@MainActor
final class OverlayHeaderView: NSView {
    private let modeLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    let waveformHost = WaveformHostView(frame: .zero)
    private let shortcutHint = NSTextField(labelWithString: "")
    private let stopButton = OverlayPrimaryButton(frame: .zero)
    var onStopRequested: (() -> Void)?

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

        stopButton.title = "Stop"
        stopButton.isHidden = true
        stopButton.target = self
        stopButton.action = #selector(stopButtonPressed)
        stopButton.toolTip = "Stop dictation"
        addSubview(stopButton)
    }

    override func layout() {
        super.layout()
        let pad = OverlayTokens.contentPadding
        let h = bounds.height
        let labelSize = modeLabel.fittingSize
        let hintSize = shortcutHint.fittingSize
        let stopSize = stopButton.fittingSize
        let isCenteredListeningLayout = !waveformHost.isHidden && !stopButton.isHidden && shortcutHint.stringValue.isEmpty && spinner.isHidden

        if isCenteredListeningLayout {
            let compactPad: CGFloat = 10
            let spacing: CGFloat = 6
            let preferredWaveWidth: CGFloat = 124
            let availableWaveWidth = max(0, bounds.width - compactPad * 2 - labelSize.width - stopSize.width - spacing * 2)
            let waveWidth = min(preferredWaveWidth, availableWaveWidth)
            let groupWidth = labelSize.width + spacing + waveWidth + spacing + stopSize.width
            let groupOriginX = max(compactPad, (bounds.width - groupWidth) / 2)

            modeLabel.frame = NSRect(
                x: groupOriginX,
                y: (h - labelSize.height) / 2,
                width: labelSize.width,
                height: labelSize.height
            )

            waveformHost.frame = NSRect(
                x: modeLabel.frame.maxX + spacing,
                y: (h - 20) / 2,
                width: waveWidth,
                height: 20
            )

            stopButton.frame = NSRect(
                x: waveformHost.frame.maxX + spacing,
                y: (h - stopSize.height) / 2,
                width: stopSize.width,
                height: stopSize.height
            )

            shortcutHint.frame = .zero
            return
        }

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

        var rightEdge = bounds.width - pad
        if !stopButton.isHidden {
            stopButton.frame = NSRect(
                x: rightEdge - stopSize.width,
                y: (h - stopSize.height) / 2,
                width: stopSize.width,
                height: stopSize.height
            )
            rightEdge = stopButton.frame.minX - 8
        } else {
            stopButton.frame = .zero
        }

        if !shortcutHint.stringValue.isEmpty {
            let hintWidth = min(hintSize.width, max(0, rightEdge - pad))
            shortcutHint.frame = NSRect(
                x: max(pad, rightEdge - hintWidth),
                y: (h - hintSize.height) / 2,
                width: hintWidth,
                height: hintSize.height
            )
        } else {
            shortcutHint.frame = .zero
        }

        // Waveform — fills space between mode label and hint
        if !waveformHost.isHidden {
            let waveLeft = modeLabel.frame.maxX + 8
            let waveRight: CGFloat
            if !shortcutHint.stringValue.isEmpty {
                waveRight = shortcutHint.frame.minX - 8
            } else if !stopButton.isHidden {
                waveRight = stopButton.frame.minX - 8
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

    // MARK: - Update Methods

    @objc
    private func stopButtonPressed() {
        onStopRequested?()
    }

    func updateWaveformLevel(_ level: Float) {
        waveformHost.level = level
    }

    func update(
        state: FloatingOverlayController.OverlayState,
        dictationShortcutHint: String,
        loadingTitle: String?
    ) {
        // Mode label text + color
        switch state {
        case .listening:
            modeLabel.stringValue = "Listening"
            modeLabel.textColor = OverlayTokens.textPrimary
        case .drafting:
            modeLabel.stringValue = "Transcribing"
            modeLabel.textColor = OverlayTokens.textPrimary
        case .success:
            modeLabel.stringValue = "Pasted"
            modeLabel.textColor = OverlayTokens.textPrimary
        case .loading:
            modeLabel.stringValue = loadingTitle ?? "Loading dictation"
            modeLabel.textColor = OverlayTokens.textSecondary
        case .idle:
            modeLabel.stringValue = "Dictation"
            modeLabel.textColor = OverlayTokens.textMuted
        }

        // Spinner visibility
        let showSpinner = state == .drafting || state == .loading
        spinner.isHidden = !showSpinner
        if showSpinner { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }

        // Waveform visibility
        let showWaveform = state == .listening
        waveformHost.isHidden = !showWaveform
        waveformHost.isActive = showWaveform
        stopButton.isHidden = state != .listening

        // Shortcut hint
        switch state {
        case .listening:
            shortcutHint.stringValue = ""
            shortcutHint.textColor = OverlayTokens.textMuted
        case .success:
            shortcutHint.stringValue = ""
            shortcutHint.textColor = OverlayTokens.textMuted
        case .loading:
            shortcutHint.stringValue = "Cancel: \(dictationShortcutHint)"
            shortcutHint.textColor = OverlayTokens.textSecondary
        case .drafting:
            shortcutHint.stringValue = ""
            shortcutHint.textColor = OverlayTokens.textMuted
        default:
            shortcutHint.stringValue = ""
            shortcutHint.textColor = OverlayTokens.textMuted
        }

        needsLayout = true
    }
}
