// MenuOutlineButton.swift
// Compact labeled outline button for menubar secondary actions.

import AppKit

@MainActor
final class MenuOutlineButton: NSButton {
    enum Style {
        case standard
        case accent
    }

    private var trackingAreaRef: NSTrackingArea?
    private var symbolName: String?
    private var symbolLabel: String?
    private let style: Style
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

    init(
        title: String,
        symbolName: String? = nil,
        accessibilityLabel: String? = nil,
        toolTip: String? = nil,
        style: Style = .standard
    ) {
        self.style = style
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

    private func updateTitleAppearance(contentColor: NSColor? = nil) {
        let color = contentColor ?? (isEnabled ? MenuTokens.textPrimaryNS : MenuTokens.textMutedNS)
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
        } else {
            switch style {
            case .standard:
                if isPressing {
                    backgroundColor = MenuTokens.secondaryButtonPressedNS
                } else if isHovering {
                    backgroundColor = MenuTokens.secondaryButtonHoverNS
                } else {
                    backgroundColor = MenuTokens.secondaryButtonBackgroundNS
                }
                borderColor = MenuTokens.secondaryButtonBorderNS
            case .accent:
                if isPressing {
                    backgroundColor = MenuTokens.accentButtonPressedNS
                } else if isHovering {
                    backgroundColor = MenuTokens.accentButtonHoverNS
                } else {
                    backgroundColor = MenuTokens.accentButtonBackgroundNS
                }
                borderColor = MenuTokens.accentButtonBorderNS
            }
            contentColor = MenuTokens.textPrimaryNS
        }

        layer?.backgroundColor = backgroundColor.cgColor
        layer?.borderColor = borderColor.cgColor
        layer?.transform = isPressing
            ? CATransform3DMakeScale(0.96, 0.96, 1)
            : CATransform3DIdentity
        contentTintColor = contentColor
        alphaValue = isEnabled ? 1.0 : 0.55
        updateTitleAppearance(contentColor: contentColor)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isEnabled, !isHidden, alphaValue > 0.01 else { return nil }
        let localPoint = convert(point, from: superview)
        return minimumHitBounds.contains(localPoint) ? self : nil
    }

    private var minimumHitBounds: NSRect {
        let horizontalInset = max(0, (MenuTokens.minimumHitTargetSize - bounds.width) / 2)
        let verticalInset = max(0, (MenuTokens.minimumHitTargetSize - bounds.height) / 2)
        return bounds.insetBy(dx: -horizontalInset, dy: -verticalInset)
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
        let shouldPerformClick = trackPressInMinimumHitBounds()
        isPressing = false
        if shouldPerformClick, let action {
            NSApp.sendAction(action, to: target, from: self)
        }
    }

    private func trackPressInMinimumHitBounds() -> Bool {
        while let nextEvent = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let point = convert(nextEvent.locationInWindow, from: nil)
            let isInside = minimumHitBounds.contains(point)
            isPressing = isInside

            if nextEvent.type == .leftMouseUp {
                return isInside
            }
        }
        return false
    }
}
