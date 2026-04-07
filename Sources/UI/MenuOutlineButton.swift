// MenuOutlineButton.swift
// Compact labeled outline button for menubar secondary actions.

import AppKit

@MainActor
final class MenuOutlineButton: NSButton {
    private var trackingAreaRef: NSTrackingArea?
    private var symbolName: String?
    private var symbolLabel: String?
    private var isHovering = false { didSet { updateAppearance() } }
    private var isPressing = false { didSet { updateAppearance() } }

    override var title: String {
        didSet {
            updateTitleAppearance()
            invalidateIntrinsicContentSize()
        }
    }

    override var isEnabled: Bool {
        didSet { updateAppearance() }
    }

    init(title: String, symbolName: String? = nil, accessibilityLabel: String? = nil, toolTip: String? = nil) {
        self.symbolName = symbolName
        self.symbolLabel = accessibilityLabel
        super.init(frame: .zero)
        self.title = title
        self.toolTip = toolTip
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        let base = super.intrinsicContentSize
        return NSSize(width: base.width + 20, height: MenuTokens.secondaryButtonSize)
    }

    func setSymbol(_ symbolName: String?, accessibilityLabel: String? = nil) {
        self.symbolName = symbolName
        self.symbolLabel = accessibilityLabel
        if let accessibilityLabel {
            setAccessibilityLabel(accessibilityLabel)
        }
        updateSymbolImage()
        updateAppearance()
        invalidateIntrinsicContentSize()
    }

    private func setupViews() {
        wantsLayer = true
        isBordered = false
        bezelStyle = .inline
        focusRingType = .none
        setButtonType(.momentaryChange)
        imagePosition = .imageLeading
        imageHugsTitle = true
        layer?.cornerRadius = MenuTokens.secondaryButtonCornerRadius
        layer?.borderWidth = 1

        if let symbolLabel {
            setAccessibilityLabel(symbolLabel)
        }

        updateSymbolImage()
        updateAppearance()
    }

    private func updateSymbolImage() {
        guard let symbolName else {
            image = nil
            return
        }

        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: symbolLabel)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(
                    pointSize: MenuTokens.secondaryButtonIconPointSize,
                    weight: .semibold
                )
            )
    }

    private func updateTitleAppearance() {
        let color = isEnabled ? MenuTokens.textPrimaryNS : MenuTokens.textMutedNS
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
                .foregroundColor: color
            ]
        )
    }

    private func updateAppearance() {
        let backgroundColor: NSColor
        let borderColor: NSColor
        let contentColor: NSColor

        if !isEnabled {
            backgroundColor = MenuTokens.actionDisabledNS
            borderColor = MenuTokens.sectionDividerNS
            contentColor = MenuTokens.textMutedNS
        } else if isPressing {
            backgroundColor = MenuTokens.secondaryButtonPressedNS
            borderColor = MenuTokens.secondaryButtonBorderNS
            contentColor = MenuTokens.textPrimaryNS
        } else if isHovering {
            backgroundColor = MenuTokens.secondaryButtonHoverNS
            borderColor = MenuTokens.secondaryButtonBorderNS
            contentColor = MenuTokens.textPrimaryNS
        } else {
            backgroundColor = MenuTokens.secondaryButtonBackgroundNS
            borderColor = MenuTokens.secondaryButtonBorderNS
            contentColor = MenuTokens.textPrimaryNS
        }

        layer?.backgroundColor = backgroundColor.cgColor
        layer?.borderColor = borderColor.cgColor
        contentTintColor = contentColor
        alphaValue = isEnabled ? 1.0 : 0.55
        updateTitleAppearance()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressing = true
        super.mouseDown(with: event)
        isPressing = false
    }
}
