import AppKit
import QuartzCore

struct MenuBarActionRowSmokeSnapshot: Codable, Equatable {
    let title: String
    /// What the row shows on screen; a `.button` shows a shorter title.
    let displayTitle: String
    let detail: String
    /// A button's setup or failure detail, shown on hover.
    let toolTip: String
    let trailingText: String
    let automationIdentifier: String
    let isVisible: Bool
    let isEnabled: Bool
}

@MainActor
final class MenuBarActionRowView: NSControl {
    enum Tone {
        case standard
        case warning
        case recording
    }

    enum Size {
        case primary
        case utility
        /// A small filled button, laid out two to a row. Shows a short title
        /// and, when it fits, the shortcut; the full title stays the
        /// accessibility label and the detail moves to the tooltip.
        case button
    }

    var onPress: (() -> Void)?

    private let symbolWellView = NSView()
    private let symbolView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let trailingLabel = NSTextField(labelWithString: "")

    // Hover eases in and out; presses snap so activation feels immediate.
    private var isHovering = false { didSet { updateAppearance(animated: true) } }
    private var isPressing = false { didSet { updateAppearance() } }
    private var trackingAreaRef: NSTrackingArea?
    private var rowTone: Tone = .standard
    private var rowSize: Size = .utility
    private var currentHeight: CGFloat = 26
    private var rowTitle = ""

    override var isEnabled: Bool {
        didSet {
            setAccessibilityEnabled(isEnabled)
            updateAppearance()
            window?.invalidateCursorRects(for: self)
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: currentHeight)
    }

    /// `displayTitle` is the shorter text a `.button` shows; `title` stays
    /// the smoke snapshot title. Voice Control matches the words on screen,
    /// so the accessibility label is whatever the row shows.
    func update(
        symbolName: String,
        title: String,
        displayTitle: String? = nil,
        detail: String,
        trailingText: String? = nil,
        tone: Tone = .standard,
        size: Size = .utility,
        isEnabled: Bool = true
    ) {
        rowTone = tone
        rowSize = size
        rowTitle = title
        self.isEnabled = isEnabled
        let visibleTitle = displayTitle ?? title
        setAccessibilityLabel(visibleTitle)
        setAccessibilityHelp(detail.isEmpty ? nil : detail)
        toolTip = size == .button && !detail.isEmpty ? detail : nil

        titleLabel.stringValue = visibleTitle
        // A button has no room for a second line; its detail is the tooltip.
        detailLabel.stringValue = size == .button ? "" : detail
        detailLabel.isHidden = detailLabel.stringValue.isEmpty
        trailingLabel.stringValue = trailingText ?? ""
        trailingLabel.isHidden = trailingText?.isEmpty ?? true
        currentHeight = resolvedHeight()

        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title) {
            symbolView.image = image.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: size == .utility ? 12 : 14, weight: .semibold)
            )
        }

        invalidateIntrinsicContentSize()
        needsLayout = true
        updateAppearance()
    }

    func setAutomationIdentifier(_ rawValue: String) {
        identifier = NSUserInterfaceItemIdentifier(rawValue)
        setAccessibilityIdentifier(rawValue)
    }

    private func setupViews() {
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityEnabled(isEnabled)

        wantsLayer = true
        layer?.cornerRadius = MenuTokens.cardCornerRadius

        addSubview(symbolWellView)

        symbolView.imageScaling = .scaleProportionallyDown
        symbolWellView.addSubview(symbolView)

        titleLabel.textColor = MenuTokens.textPrimaryNS
        addSubview(titleLabel)

        detailLabel.textColor = MenuTokens.textSecondaryNS
        detailLabel.lineBreakMode = .byTruncatingTail
        addSubview(detailLabel)

        trailingLabel.textColor = MenuTokens.textMutedNS
        trailingLabel.alignment = .right
        addSubview(trailingLabel)

        updateAppearance()
    }

    private func updateAppearance(animated: Bool = false) {
        let backgroundColor: NSColor
        let iconTint: NSColor
        let titleColor: NSColor
        let detailColor: NSColor
        let trailingColor: NSColor

        if !isEnabled {
            // A disabled row often says what it is waiting on ("Restart to
            // Update / After this recording finishes"), so it stays readable:
            // secondary text, no extra fade on top.
            backgroundColor = MenuTokens.flatRowDisabledNS
            iconTint = MenuTokens.textMutedNS
            titleColor = MenuTokens.textSecondaryNS
            detailColor = MenuTokens.textSecondaryNS
            trailingColor = MenuTokens.textMutedNS
        } else if isPressing {
            backgroundColor = MenuTokens.flatRowPressedNS
            iconTint = toneColors().pressed
            titleColor = MenuTokens.textPrimaryNS
            detailColor = MenuTokens.textSecondaryNS
            trailingColor = MenuTokens.textSecondaryNS
        } else if isHovering {
            // A button's resting fill is already hover-strength, so its hover
            // steps up to the pressed fill.
            backgroundColor = rowSize == .button ? MenuTokens.flatRowPressedNS : MenuTokens.flatRowHoverNS
            iconTint = toneColors().pressed
            titleColor = MenuTokens.textPrimaryNS
            detailColor = MenuTokens.textSecondaryNS
            trailingColor = MenuTokens.textSecondaryNS
        } else {
            // Buttons keep a quiet fill at rest so they read as buttons.
            backgroundColor = rowSize == .button ? MenuTokens.buttonBackgroundNS : .clear
            iconTint = toneColors().normal
            titleColor = MenuTokens.textPrimaryNS
            detailColor = MenuTokens.textSecondaryNS
            trailingColor = MenuTokens.textMutedNS
        }

        setLayerBackground(menuResolvedCGColor(backgroundColor), animated: animated)
        layer?.borderWidth = 0
        symbolView.contentTintColor = iconTint
        titleLabel.textColor = titleColor
        detailLabel.textColor = detailColor
        trailingLabel.textColor = trailingColor
    }

    private func toneColors() -> (normal: NSColor, pressed: NSColor) {
        switch rowTone {
        case .standard:
            return (MenuTokens.textSecondaryNS, MenuTokens.textPrimaryNS)
        case .warning:
            return (MenuTokens.statusOrangeNS, MenuTokens.statusOrangeNS)
        case .recording:
            return (MenuTokens.statusRedNS, MenuTokens.statusRedNS)
        }
    }

    override func layout() {
        super.layout()

        if rowSize == .button {
            layoutButton()
            return
        }

        let hasDetail = !detailLabel.isHidden
        let padX: CGFloat = 6
        let iconWidth: CGFloat = rowSize == .primary ? 17 : 16
        let symbolSize: CGFloat = rowSize == .primary ? 14 : 12
        let trailingWidth: CGFloat = trailingLabel.isHidden ? 0 : (rowSize == .primary ? 76 : 64)
        let trailingSpacing: CGFloat = trailingWidth > 0 ? 8 : 0
        let contentWidth = bounds.width - (padX * 2) - iconWidth - 8 - trailingWidth - trailingSpacing
        let textWidth = max(CGFloat(0), contentWidth)

        updateTypography()

        symbolWellView.frame = NSRect(x: padX, y: floor((bounds.height - symbolSize) / 2), width: iconWidth, height: symbolSize)
        symbolView.frame = NSRect(
            x: max(0, floor((iconWidth - symbolSize) / 2)),
            y: 0,
            width: symbolSize,
            height: symbolSize
        )

        let textX = symbolWellView.frame.maxX + 8
        if !hasDetail {
            let centeredY = (bounds.height - 16) / 2
            titleLabel.frame = NSRect(x: textX, y: centeredY, width: textWidth, height: 16)
            detailLabel.frame = .zero
        } else {
            let textBlockHeight: CGFloat = 30
            let titleY = floor((bounds.height - textBlockHeight) / 2)
            titleLabel.frame = NSRect(x: textX, y: titleY, width: textWidth, height: 16)
            detailLabel.frame = NSRect(x: textX, y: titleLabel.frame.maxY + 1, width: textWidth, height: 13)
        }

        if trailingWidth > 0 {
            let trailingX = bounds.width - padX - trailingWidth
            let trailingY = hasDetail ? titleLabel.frame.minY + 1 : (bounds.height - 14) / 2
            trailingLabel.frame = NSRect(x: trailingX, y: trailingY, width: trailingWidth, height: 14)
        }
    }

    private func layoutButton() {
        updateTypography()
        detailLabel.frame = .zero

        let padX: CGFloat = 10
        let symbolSize: CGFloat = 14
        let gap: CGFloat = 6
        symbolWellView.frame = NSRect(x: padX, y: floor((bounds.height - symbolSize) / 2), width: symbolSize, height: symbolSize)
        symbolView.frame = NSRect(x: 0, y: 0, width: symbolSize, height: symbolSize)

        let textX = symbolWellView.frame.maxX + gap
        let available = max(0, bounds.width - textX - padX)
        let titleWidth = ceil(titleLabel.intrinsicContentSize.width)
        let trailingWidth = ceil(trailingLabel.intrinsicContentSize.width)
        // The shortcut shows only when it fits beside the title; a long one
        // ("Fn / Right ⌥") stays in the Settings shortcut editor instead.
        let showsTrailing = !(trailingLabel.stringValue.isEmpty)
            && titleWidth + gap + trailingWidth <= available
        trailingLabel.isHidden = !showsTrailing

        let titleY = floor((bounds.height - 16) / 2)
        titleLabel.frame = NSRect(x: textX, y: titleY, width: min(titleWidth, available), height: 16)
        if showsTrailing {
            trailingLabel.frame = NSRect(
                x: bounds.width - padX - trailingWidth,
                y: floor((bounds.height - 14) / 2),
                width: trailingWidth,
                height: 14
            )
        } else {
            trailingLabel.frame = .zero
        }
    }

    private func updateTypography() {
        switch rowSize {
        case .button:
            titleLabel.font = MenuTokens.Font.rowTitlePrimary
            detailLabel.font = MenuTokens.Font.rowDetail
            trailingLabel.font = MenuTokens.Font.rowTrailingUtility
        case .primary:
            titleLabel.font = MenuTokens.Font.rowTitlePrimary
            detailLabel.font = MenuTokens.Font.rowDetail
            trailingLabel.font = MenuTokens.Font.rowTrailingPrimary
        case .utility:
            titleLabel.font = MenuTokens.Font.rowTitleUtility
            detailLabel.font = MenuTokens.Font.rowDetail
            trailingLabel.font = MenuTokens.Font.rowTrailingUtility
        }
    }

    private func resolvedHeight() -> CGFloat {
        let hasDetail = !detailLabel.stringValue.isEmpty
        switch rowSize {
        case .primary:
            return hasDetail ? MenuTokens.compactActionRowHeight : MenuTokens.minimumHitTargetSize
        case .utility:
            return hasDetail ? MenuTokens.utilityActionRowHeight : MenuTokens.minimumHitTargetSize
        case .button:
            return MenuTokens.minimumHitTargetSize
        }
    }

    private func setLayerBackground(_ color: CGColor, animated: Bool) {
        guard let layer else { return }
        let duration = AccessibilityDisplayPolicy.motionDuration(0.12)
        if animated, duration > 0 {
            let fade = CABasicAnimation(keyPath: "backgroundColor")
            fade.fromValue = layer.presentation()?.backgroundColor ?? layer.backgroundColor
            fade.toValue = color
            fade.duration = duration
            layer.add(fade, forKey: "backgroundFade")
        }
        layer.backgroundColor = color
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
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
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard isEnabled else { return }
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) {
        guard isEnabled else { return }
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        isPressing = false
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressing = true
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        defer { isPressing = false }
        guard isEnabled, inside else { return }
        onPress?()
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        onPress?()
        return true
    }

    // MARK: - Keyboard focus

    // Rows are real controls, so they join the popover's key-view loop and stay
    // reachable by keyboard. An enabled, visible row can take focus; a disabled
    // or hidden one is skipped so Tab never lands on a dead control.
    override var acceptsFirstResponder: Bool { isEnabled && !isHidden }

    override var canBecomeKeyView: Bool { acceptsFirstResponder }

    override func keyDown(with event: NSEvent) {
        // Space (49) and Return / keypad Enter (36 / 76) activate the focused row,
        // matching how AppKit buttons respond to keyboard activation.
        if isEnabled, event.keyCode == 49 || event.keyCode == 36 || event.keyCode == 76 {
            onPress?()
            return
        }
        super.keyDown(with: event)
    }

    override func drawFocusRingMask() {
        NSBezierPath(
            roundedRect: bounds,
            xRadius: MenuTokens.cardCornerRadius,
            yRadius: MenuTokens.cardCornerRadius
        ).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    var smokeSnapshot: MenuBarActionRowSmokeSnapshot {
        MenuBarActionRowSmokeSnapshot(
            title: rowTitle,
            displayTitle: titleLabel.stringValue,
            detail: detailLabel.stringValue,
            toolTip: toolTip ?? "",
            trailingText: trailingLabel.stringValue,
            automationIdentifier: accessibilityIdentifier(),
            isVisible: !isHidden,
            isEnabled: isEnabled
        )
    }
}
