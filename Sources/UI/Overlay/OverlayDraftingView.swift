// OverlayDraftingView.swift
// Content view during drafting/processing state — spinner + status or error

import AppKit

@MainActor
private final class OverlaySecondaryButton: NSButton {
    override var title: String {
        didSet {
            updateTitleAppearance()
            invalidateIntrinsicContentSize()
        }
    }

    override var intrinsicContentSize: NSSize {
        let base = super.intrinsicContentSize
        return NSSize(width: base.width + 20, height: max(28, base.height + 8))
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
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: OverlayTokens.textPrimary
            ]
        )
    }

    private func updateLayerAppearance() {
        layer?.backgroundColor = (isHighlighted
            ? NSColor.white.withAlphaComponent(0.12)
            : NSColor.white.withAlphaComponent(0.07)
        ).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
    }
}

@MainActor
final class OverlayDraftingView: NSView {
    private let spinner = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private let errorIcon = NSImageView()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let errorActionButton = OverlaySecondaryButton(frame: .zero)
    private let errorDismissButton = NSButton(frame: .zero)

    // Secondary state: dimmed transcript + "Refining..." spinner
    private let dimmedTranscript = NSTextField(wrappingLabelWithString: "")
    private let refiningSpinner = NSProgressIndicator()
    private let refiningLabel = NSTextField(labelWithString: "")
    private var errorAction: (() -> Void)?
    private var errorDismiss: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupViews() {
        // Main spinner
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        addSubview(spinner)

        // Status text
        statusLabel.font = NSFont.systemFont(ofSize: 12)
        // The loading/processing status is the sole readable message in this
        // state, so it tracks the secondary text token (matching the error and
        // "Refining…" labels) instead of the weakest muted token, which kept it
        // a notch under contrast on the translucent overlay over bright windows.
        statusLabel.textColor = OverlayTokens.textSecondary
        statusLabel.isBezeled = false
        statusLabel.isEditable = false
        statusLabel.drawsBackground = false
        statusLabel.alignment = .center
        addSubview(statusLabel)

        // Error icon
        applyMessageIcon(isNotice: false)
        errorIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        errorIcon.isHidden = true
        addSubview(errorIcon)

        // Error label — wraps so "press ⌘V" instructions never truncate mid-sentence
        errorLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        errorLabel.textColor = OverlayTokens.textSecondary
        errorLabel.isBezeled = false
        errorLabel.isEditable = false
        errorLabel.drawsBackground = false
        errorLabel.alignment = .center
        errorLabel.maximumNumberOfLines = 3
        errorLabel.isHidden = true
        addSubview(errorLabel)

        errorActionButton.isHidden = true
        errorActionButton.target = self
        errorActionButton.action = #selector(handleErrorAction)
        addSubview(errorActionButton)

        if let closeImage = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Dismiss error") {
            errorDismissButton.image = closeImage
            errorDismissButton.imagePosition = .imageOnly
        } else {
            errorDismissButton.title = "x"
        }
        errorDismissButton.isBordered = false
        errorDismissButton.contentTintColor = OverlayTokens.textSecondary
        errorDismissButton.target = self
        errorDismissButton.action = #selector(handleErrorDismiss)
        errorDismissButton.isHidden = true
        errorDismissButton.setAccessibilityLabel("Dismiss error")
        addSubview(errorDismissButton)

        // Dimmed transcript (for showing text at reduced opacity during processing)
        dimmedTranscript.font = NSFont.systemFont(ofSize: 13)
        dimmedTranscript.textColor = OverlayTokens.textPrimary
        dimmedTranscript.alphaValue = 0.45
        dimmedTranscript.isBezeled = false
        dimmedTranscript.isEditable = false
        dimmedTranscript.drawsBackground = false
        dimmedTranscript.lineBreakMode = .byWordWrapping
        dimmedTranscript.maximumNumberOfLines = 0
        dimmedTranscript.isHidden = true
        addSubview(dimmedTranscript)

        // Refining spinner + label
        refiningSpinner.style = .spinning
        refiningSpinner.controlSize = .mini
        refiningSpinner.isIndeterminate = true
        refiningSpinner.isHidden = true
        addSubview(refiningSpinner)

        refiningLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        refiningLabel.textColor = OverlayTokens.textSecondary
        refiningLabel.stringValue = "Refining..."
        refiningLabel.isBezeled = false
        refiningLabel.isEditable = false
        refiningLabel.drawsBackground = false
        refiningLabel.isHidden = true
        addSubview(refiningLabel)
    }

    override func layout() {
        super.layout()
        let pad = OverlayTokens.contentPadding
        let centerX = bounds.midX
        let centerY = bounds.midY

        if !errorIcon.isHidden {
            // Error mode: icon + label centered
            let iconSize: CGFloat = 24
            errorLabel.preferredMaxLayoutWidth = bounds.width - pad * 2
            let labelSize = errorLabel.fittingSize
            let buttonSize = errorActionButton.isHidden ? .zero : errorActionButton.fittingSize
            let hasAction = !errorActionButton.isHidden
            let buttonSpacing: CGFloat = hasAction ? 10 : 0
            let totalHeight = iconSize + 8 + labelSize.height + buttonSpacing + buttonSize.height
            let startY = centerY - totalHeight / 2
            let dismissSize: CGFloat = 22

            errorDismissButton.frame = NSRect(
                x: bounds.width - pad - dismissSize,
                y: bounds.height - pad - dismissSize,
                width: dismissSize,
                height: dismissSize
            )

            errorIcon.frame = NSRect(
                x: centerX - iconSize / 2,
                y: startY + buttonSize.height + buttonSpacing + labelSize.height + 8,
                width: iconSize,
                height: iconSize
            )
            errorLabel.frame = NSRect(
                x: pad,
                y: startY + buttonSize.height + buttonSpacing,
                width: bounds.width - pad * 2,
                height: labelSize.height
            )
            if hasAction {
                errorActionButton.frame = NSRect(
                    x: centerX - buttonSize.width / 2,
                    y: startY,
                    width: buttonSize.width,
                    height: buttonSize.height
                )
            } else {
                errorActionButton.frame = .zero
            }
        } else if !dimmedTranscript.isHidden {
            // Dimmed transcript mode
            dimmedTranscript.preferredMaxLayoutWidth = bounds.width - pad * 2
            let transcriptSize = dimmedTranscript.fittingSize
            dimmedTranscript.frame = NSRect(x: pad, y: bounds.height - pad - transcriptSize.height, width: bounds.width - pad * 2, height: transcriptSize.height)

            // Refining label at bottom
            let refSize = refiningLabel.fittingSize
            let spinSize: CGFloat = 14
            let refTotalWidth = spinSize + 6 + refSize.width
            refiningSpinner.frame = NSRect(x: centerX - refTotalWidth / 2, y: pad, width: spinSize, height: spinSize)
            refiningLabel.frame = NSRect(x: refiningSpinner.frame.maxX + 6, y: pad, width: refSize.width, height: refSize.height)
        } else {
            // Default spinner + status
            let spinSize: CGFloat = 20
            let labelSize = statusLabel.fittingSize
            let totalHeight = spinSize + 8 + labelSize.height
            spinner.frame = NSRect(x: centerX - spinSize / 2, y: centerY - totalHeight / 2 + labelSize.height + 8, width: spinSize, height: spinSize)
            statusLabel.frame = NSRect(x: pad, y: centerY - totalHeight / 2, width: bounds.width - pad * 2, height: labelSize.height)
        }
    }

    /// Swap between the warning triangle for real problems and a calm clipboard
    /// glyph for "your text is on the clipboard" fallback notices.
    private func applyMessageIcon(isNotice: Bool) {
        let symbolName = isNotice ? "doc.on.clipboard" : "exclamationmark.triangle"
        let description = isNotice ? "Copied to clipboard" : "Error"
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: description) {
            errorIcon.image = image
        }
        errorIcon.contentTintColor = isNotice ? OverlayTokens.textSecondary : OverlayTokens.warningColor
    }

    func update(
        error: String?,
        errorActionTitle: String?,
        onErrorAction: (() -> Void)?,
        isNotice: Bool = false,
        onErrorDismiss: (() -> Void)?,
        isTranscribing: Bool,
        transcriptText: String,
        statusText: String
    ) {
        if let error = error, !error.isEmpty {
            // Error mode
            errorAction = onErrorAction
            applyMessageIcon(isNotice: isNotice)
            errorDismiss = onErrorDismiss
            errorIcon.isHidden = false
            errorLabel.isHidden = false
            errorLabel.stringValue = error
            errorDismissButton.isHidden = false
            if let errorActionTitle, !errorActionTitle.isEmpty {
                errorActionButton.title = errorActionTitle
                errorActionButton.isHidden = false
            } else {
                errorActionButton.isHidden = true
            }
            spinner.isHidden = true
            spinner.stopAnimation(nil)
            statusLabel.isHidden = true
            dimmedTranscript.isHidden = true
            refiningSpinner.isHidden = true
            refiningLabel.isHidden = true
        } else if isTranscribing, !transcriptText.isEmpty {
            // Dimmed transcript + refining
            errorAction = nil
            errorDismiss = nil
            dimmedTranscript.isHidden = false
            dimmedTranscript.stringValue = transcriptText
            refiningSpinner.isHidden = false
            refiningSpinner.startAnimation(nil)
            refiningLabel.isHidden = false
            spinner.isHidden = true
            spinner.stopAnimation(nil)
            statusLabel.isHidden = true
            errorIcon.isHidden = true
            errorLabel.isHidden = true
            errorActionButton.isHidden = true
            errorDismissButton.isHidden = true
        } else {
            // Default: spinner + status
            errorAction = nil
            errorDismiss = nil
            spinner.isHidden = false
            spinner.startAnimation(nil)
            statusLabel.isHidden = false
            statusLabel.stringValue = statusText
            errorIcon.isHidden = true
            errorLabel.isHidden = true
            dimmedTranscript.isHidden = true
            refiningSpinner.isHidden = true
            refiningLabel.isHidden = true
            errorActionButton.isHidden = true
            errorDismissButton.isHidden = true
        }
        needsLayout = true
    }

    @objc
    private func handleErrorAction() {
        errorAction?()
    }

    @objc
    private func handleErrorDismiss() {
        errorDismiss?()
    }
}
