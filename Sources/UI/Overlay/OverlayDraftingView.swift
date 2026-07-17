// OverlayDraftingView.swift
// Legacy-named content view for actionable dictation errors and clipboard notices.

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
    private let errorIcon = NSImageView()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let errorActionButton = OverlaySecondaryButton(frame: .zero)
    private let errorDismissButton = NSButton(frame: .zero)

    private var errorAction: (() -> Void)?
    private var errorDismiss: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupViews() {
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

    }

    override func layout() {
        super.layout()
        let pad = OverlayTokens.contentPadding
        let centerX = bounds.midX
        let centerY = bounds.midY

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
        message: String,
        errorActionTitle: String?,
        onErrorAction: (() -> Void)?,
        isNotice: Bool = false,
        onErrorDismiss: (() -> Void)?
    ) {
        errorAction = onErrorAction
        applyMessageIcon(isNotice: isNotice)
        errorDismiss = onErrorDismiss
        errorIcon.isHidden = false
        errorLabel.isHidden = false
        errorLabel.stringValue = message
        errorDismissButton.isHidden = false
        if let errorActionTitle, !errorActionTitle.isEmpty {
            errorActionButton.title = errorActionTitle
            errorActionButton.isHidden = false
        } else {
            errorActionButton.isHidden = true
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
