import AppKit

@MainActor
final class MenuBarShortcutsView: NSView {
    var onStartDictation: (() -> Void)?
    var onStartMeeting: (() -> Void)?

    private let dictationButton = MenuPrimaryActionButton()
    private let meetingButton = MenuPrimaryActionButton()
    private let hintLabel = NSTextField(labelWithString: "Shortcut editing moved to Settings.")

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func setupViews() {
        dictationButton.onTrigger = { [weak self] in
            self?.onStartDictation?()
        }
        addSubview(dictationButton)

        meetingButton.onTrigger = { [weak self] in
            self?.onStartMeeting?()
        }
        addSubview(meetingButton)

        hintLabel.font = NSFont.systemFont(ofSize: 10)
        hintLabel.textColor = MenuTokens.textMutedNS
        addSubview(hintLabel)
    }

    override func layout() {
        super.layout()

        dictationButton.frame = NSRect(x: 0, y: 0, width: bounds.width, height: MenuTokens.actionRowHeight)
        meetingButton.frame = NSRect(
            x: 0,
            y: dictationButton.frame.maxY + 8,
            width: bounds.width,
            height: MenuTokens.actionRowHeight
        )
        hintLabel.frame = NSRect(
            x: 0,
            y: meetingButton.frame.maxY + 10,
            width: bounds.width,
            height: 14
        )
    }

    func update(
        dictationKey: String,
        meetingKey: String,
        dictationState: MenuBarPrimaryActionState,
        meetingState: MenuBarPrimaryActionState
    ) {
        dictationButton.update(
            symbolName: "mic.fill",
            title: "Start dictation",
            subtitle: dictationState.subtitle,
            key: dictationKey,
            isEnabled: dictationState.isEnabled
        )

        meetingButton.update(
            symbolName: "record.circle.fill",
            title: "Record meeting",
            subtitle: meetingState.subtitle,
            key: meetingKey,
            isEnabled: meetingState.isEnabled
        )

        needsLayout = true
    }

    func cancelEditing() {}

    var intrinsicHeight: CGFloat {
        MenuTokens.actionRowHeight * 2 + 32
    }
}

@MainActor
private final class MenuPrimaryActionButton: NSButton {
    var onTrigger: (() -> Void)?

    private let symbolWellView = NSView()
    private let symbolView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let keyBadge = NSTextField(labelWithString: "")
    private var trackingAreaRef: NSTrackingArea?
    private var rowEnabled = true
    private var isHovering = false {
        didSet { updateAppearance() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func setupViews() {
        wantsLayer = true
        isBordered = false
        title = ""
        focusRingType = .none
        layer?.cornerRadius = 14
        layer?.borderWidth = 1

        symbolWellView.wantsLayer = true
        symbolWellView.layer?.cornerRadius = MenuTokens.symbolWellSize / 2
        symbolWellView.layer?.backgroundColor = MenuTokens.symbolBackgroundNS.cgColor
        symbolWellView.layer?.borderWidth = 1
        symbolWellView.layer?.borderColor = MenuTokens.symbolBorderNS.cgColor
        addSubview(symbolWellView)

        symbolView.contentTintColor = MenuTokens.textPrimaryNS
        symbolWellView.addSubview(symbolView)

        titleLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        titleLabel.textColor = MenuTokens.textPrimaryNS
        addSubview(titleLabel)

        subtitleLabel.font = NSFont.systemFont(ofSize: 10)
        subtitleLabel.textColor = MenuTokens.textSecondaryNS
        addSubview(subtitleLabel)

        keyBadge.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold)
        keyBadge.textColor = MenuTokens.textPrimaryNS
        keyBadge.alignment = .center
        keyBadge.wantsLayer = true
        keyBadge.layer?.cornerRadius = 8
        keyBadge.layer?.backgroundColor = MenuTokens.badgeBackgroundNS.cgColor
        keyBadge.layer?.borderWidth = 1
        keyBadge.layer?.borderColor = MenuTokens.badgeBorderNS.cgColor
        keyBadge.lineBreakMode = .byTruncatingTail
        addSubview(keyBadge)
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

    override func layout() {
        super.layout()

        let pad: CGFloat = 14
        symbolWellView.frame = NSRect(
            x: pad,
            y: (bounds.height - MenuTokens.symbolWellSize) / 2,
            width: MenuTokens.symbolWellSize,
            height: MenuTokens.symbolWellSize
        )
        symbolView.frame = symbolWellView.bounds

        let badgeWidth = max(84, keyBadge.fittingSize.width + 18)
        keyBadge.frame = NSRect(
            x: bounds.width - pad - badgeWidth,
            y: (bounds.height - MenuTokens.badgeHeight) / 2,
            width: badgeWidth,
            height: MenuTokens.badgeHeight
        )

        let textX = symbolWellView.frame.maxX + 10
        let textWidth = keyBadge.frame.minX - textX - 12
        titleLabel.frame = NSRect(x: textX, y: 10, width: textWidth, height: 15)
        subtitleLabel.frame = NSRect(x: textX, y: 26, width: textWidth, height: 13)
    }

    func update(symbolName: String, title: String, subtitle: String, key: String, isEnabled: Bool) {
        rowEnabled = isEnabled
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle
        keyBadge.stringValue = key
        symbolView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold))

        updateAppearance()
        titleLabel.alphaValue = isEnabled ? 1.0 : 0.55
        subtitleLabel.alphaValue = isEnabled ? 1.0 : 0.55
        keyBadge.alphaValue = isEnabled ? 1.0 : 0.55
        needsLayout = true
    }

    private func updateAppearance() {
        let backgroundColor: NSColor
        if !rowEnabled {
            backgroundColor = MenuTokens.actionDisabledNS
        } else if isHovering {
            backgroundColor = MenuTokens.actionPressedNS
        } else {
            backgroundColor = MenuTokens.actionBackgroundNS
        }

        layer?.backgroundColor = backgroundColor.cgColor
        layer?.borderColor = MenuTokens.actionBorderNS.cgColor
    }

    override func mouseEntered(with event: NSEvent) {
        guard rowEnabled else { return }
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
    }

    override func mouseDown(with event: NSEvent) {
        guard rowEnabled else { return }
        onTrigger?()
    }
}
