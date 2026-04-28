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
    private let dockGlyphContainer = NSView()
    private let dockGlyph = NSImageView()
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
        dockGlyphContainer.wantsLayer = true
        dockGlyphContainer.layer?.cornerRadius = 9
        dockGlyphContainer.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
        dockGlyphContainer.layer?.borderWidth = 1
        dockGlyphContainer.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        dockGlyphContainer.isHidden = true
        addSubview(dockGlyphContainer)

        if let image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Dictation") {
            dockGlyph.image = image
            dockGlyph.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
            dockGlyph.contentTintColor = OverlayTokens.accentGreen
        }
        dockGlyphContainer.addSubview(dockGlyph)

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
        if !dockGlyphContainer.isHidden {
            layoutDockShelf(
                height: h,
                labelSize: labelSize,
                stopSize: stopSize
            )
            return
        }
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

        dockGlyphContainer.frame = .zero

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

    private func layoutDockShelf(
        height: CGFloat,
        labelSize: NSSize,
        stopSize: NSSize
    ) {
        let pad: CGFloat = 10
        let glyphSize: CGFloat = 36
        let spacing: CGFloat = 9
        let stopWidth = stopButton.isHidden ? 0 : stopSize.width
        let spinnerSize: CGFloat = 16
        let labelWidth = min(max(labelSize.width, 62), 82)

        dockGlyphContainer.frame = NSRect(
            x: pad,
            y: (height - glyphSize) / 2,
            width: glyphSize,
            height: glyphSize
        )
        dockGlyph.frame = NSRect(x: 9, y: 9, width: 18, height: 18)

        modeLabel.frame = NSRect(
            x: dockGlyphContainer.frame.maxX + spacing,
            y: (height - labelSize.height) / 2,
            width: labelWidth,
            height: labelSize.height
        )

        var rightEdge = bounds.width - pad
        if !stopButton.isHidden {
            stopButton.frame = NSRect(
                x: rightEdge - stopWidth,
                y: (height - stopSize.height) / 2,
                width: stopWidth,
                height: stopSize.height
            )
            rightEdge = stopButton.frame.minX - spacing
        } else {
            stopButton.frame = .zero
        }

        if !spinner.isHidden {
            spinner.frame = NSRect(
                x: rightEdge - spinnerSize,
                y: (height - spinnerSize) / 2,
                width: spinnerSize,
                height: spinnerSize
            )
            rightEdge = spinner.frame.minX - spacing
        } else {
            spinner.frame = .zero
        }

        let waveLeft = modeLabel.frame.maxX + spacing
        waveformHost.frame = waveformHost.isHidden
            ? .zero
            : NSRect(
                x: waveLeft,
                y: (height - 28) / 2,
                width: max(0, rightEdge - waveLeft),
                height: 28
            )
        shortcutHint.frame = .zero
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
        presentation: DictationOverlayPresentation,
        dictationShortcutHint: String,
        loadingTitle: String?,
        isError: Bool = false,
        meterPresentation: DictationMeterPolicy.Presentation
    ) {
        // Mode label text + color
        switch state {
        case .listening:
            modeLabel.stringValue = "Listening"
            modeLabel.textColor = OverlayTokens.textPrimary
        case .drafting:
            modeLabel.stringValue = isError ? "Dictation issue" : "Transcribing"
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
        let showSpinner = (state == .drafting && !isError) || state == .loading
        spinner.isHidden = !showSpinner
        if showSpinner { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }

        // Waveform visibility
        waveformHost.isHidden = !meterPresentation.isVisible
        waveformHost.isActive = meterPresentation.isVisible
        waveformHost.level = meterPresentation.level
        if presentation == .dockShelf {
            waveformHost.tintColor = OverlayTokens.accentGreen
            waveformHost.visualizationStyle = .mirrored(anchor: .fromBottom, phaseOffset: 0)
            waveformHost.mirroredBarCount = 34
            waveformHost.mirroredBarWidth = 2.4
            waveformHost.mirroredBarSpacing = 2
        } else {
            waveformHost.tintColor = .white
            waveformHost.visualizationStyle = .scrolling
            waveformHost.mirroredBarCount = 26
            waveformHost.mirroredBarWidth = 2
            waveformHost.mirroredBarSpacing = 1.5
        }
        dockGlyphContainer.isHidden = presentation != .dockShelf
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
