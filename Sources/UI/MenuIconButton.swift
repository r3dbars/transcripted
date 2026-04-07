// MenuIconButton.swift
// Shared compact secondary action button for the menubar panel.

import AppKit

@MainActor
final class MenuIconButton: NSButton {
    private var trackingAreaRef: NSTrackingArea?
    private var symbolName: String
    private var symbolLabel: String
    private var tintOverride: NSColor?
    private var isHovering = false { didSet { updateAppearance() } }
    private var isPressing = false { didSet { updateAppearance() } }

    override var isEnabled: Bool {
        didSet { updateAppearance() }
    }

    init(symbolName: String, accessibilityLabel: String, toolTip: String? = nil) {
        self.symbolName = symbolName
        self.symbolLabel = accessibilityLabel
        super.init(frame: .zero)
        self.toolTip = toolTip
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: MenuTokens.secondaryButtonSize, height: MenuTokens.secondaryButtonSize)
    }

    func setSymbol(_ symbolName: String, accessibilityLabel: String, tintOverride: NSColor? = nil) {
        self.symbolName = symbolName
        self.symbolLabel = accessibilityLabel
        self.tintOverride = tintOverride
        setAccessibilityLabel(accessibilityLabel)
        updateSymbolImage()
        updateAppearance()
    }

    private func setupViews() {
        wantsLayer = true
        isBordered = false
        title = ""
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        focusRingType = .none
        setButtonType(.momentaryChange)
        layer?.cornerRadius = MenuTokens.secondaryButtonCornerRadius
        layer?.borderWidth = 1

        setAccessibilityLabel(symbolLabel)
        updateSymbolImage()
        updateAppearance()
    }

    private func updateSymbolImage() {
        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: symbolLabel)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(
                    pointSize: MenuTokens.secondaryButtonIconPointSize,
                    weight: .semibold
                )
            )
    }

    private func updateAppearance() {
        let backgroundColor: NSColor
        let borderColor: NSColor
        let iconTint: NSColor

        if !isEnabled {
            backgroundColor = MenuTokens.actionDisabledNS
            borderColor = MenuTokens.sectionDividerNS
            iconTint = MenuTokens.textMutedNS
        } else if isPressing {
            backgroundColor = MenuTokens.secondaryButtonPressedNS
            borderColor = MenuTokens.secondaryButtonBorderNS
            iconTint = tintOverride ?? MenuTokens.textPrimaryNS
        } else if isHovering {
            backgroundColor = MenuTokens.secondaryButtonHoverNS
            borderColor = MenuTokens.secondaryButtonBorderNS
            iconTint = tintOverride ?? MenuTokens.textPrimaryNS
        } else {
            backgroundColor = MenuTokens.secondaryButtonBackgroundNS
            borderColor = MenuTokens.secondaryButtonBorderNS
            iconTint = tintOverride ?? MenuTokens.textSecondaryNS
        }

        layer?.backgroundColor = backgroundColor.cgColor
        layer?.borderColor = borderColor.cgColor
        contentTintColor = iconTint
        alphaValue = isEnabled ? 1.0 : 0.55
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
