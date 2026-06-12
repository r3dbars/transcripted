// MeetingLiveTranscriptDrawerView.swift
// The embedded live transcript drawer shown below the meeting recording pill.
// A self-contained container so the overlay can fade and clip the whole
// drawer as one unit while the panel animates its height.
//
// The header is hover-revealed: copy and an overflow menu float over the
// transcript's top-right corner only while the pointer is inside the drawer,
// keeping the resting surface chrome-free.
//
// Pure AppKit renderer per the overlay observation pattern: the controller
// pushes content through `update(...)`; callbacks cover copy, the
// open-in-browser menu action, and resize drags.

import AppKit

@available(macOS 14.0, *)
@MainActor
final class MeetingLiveTranscriptDrawerView: NSView {
    private let separator = NSView()
    private let hoverBar = NSView()
    private let copyButton = NSButton()
    private let moreButton = NSButton()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private let resizeHandle = MeetingLiveTranscriptResizeHandle()

    private var statusText: String?
    private var hasEntries = false
    private var needsScrollToEnd = false
    private var copyFeedbackTask: Task<Void, Never>?
    private var hoverTrackingArea: NSTrackingArea?

    var onOpenInBrowser: (() -> Void)?
    var onCopyTranscript: (() -> Void)?
    var onResizeDragBegan: (() -> Void)?
    var onResizeDragChanged: ((CGFloat) -> Void)?
    var onResizeDragEnded: (() -> Void)?

    /// Header action views, exposed so the root view can attach its custom
    /// tooltip tracking to them.
    var copyActionView: NSView { copyButton }
    var moreActionView: NSView { moreButton }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Clip children while the panel height animates so partially laid
        // out content never draws over the recording strip above.
        wantsLayer = true
        layer?.masksToBounds = true

        separator.wantsLayer = true
        separator.layer?.backgroundColor = MeetingOverlayTokens.panelStroke.cgColor
        addSubview(separator)

        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = MeetingOverlayTokens.textSecondary
        statusLabel.maximumNumberOfLines = 4
        statusLabel.isHidden = true
        addSubview(statusLabel)

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 2, height: 6)
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor.white.withAlphaComponent(0.22)
        ]
        textView.setAccessibilityLabel(MeetingLiveViewAffordancePolicy.drawerTitle)

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.scrollerKnobStyle = .light
        scrollView.isHidden = true
        addSubview(scrollView)

        resizeHandle.onDragBegan = { [weak self] in self?.onResizeDragBegan?() }
        resizeHandle.onDragChanged = { [weak self] delta in self?.onResizeDragChanged?(delta) }
        resizeHandle.onDragEnded = { [weak self] in self?.onResizeDragEnded?() }
        addSubview(resizeHandle)

        configureHeaderButton(
            copyButton,
            image: Self.copyButtonImage(),
            action: #selector(handleCopyTranscript),
            automationIdentifier: MeetingLiveViewAffordancePolicy.copyAutomationIdentifier,
            accessibilityLabel: MeetingLiveViewAffordancePolicy.copyTooltip
        )
        copyButton.isEnabled = false

        configureHeaderButton(
            moreButton,
            image: Self.moreButtonImage(),
            action: #selector(handleMoreMenu),
            automationIdentifier: MeetingLiveViewAffordancePolicy.moreAutomationIdentifier,
            accessibilityLabel: MeetingLiveViewAffordancePolicy.moreTooltip
        )

        // Hover-revealed header: floats above the transcript's top-right
        // corner and only appears while the pointer is inside the drawer.
        hoverBar.alphaValue = 0
        hoverBar.addSubview(copyButton)
        hoverBar.addSubview(moreButton)
        addSubview(hoverBar)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        copyFeedbackTask?.cancel()
    }

    private func configureHeaderButton(
        _ button: NSButton,
        image: NSImage?,
        action: Selector,
        automationIdentifier: String,
        accessibilityLabel: String
    ) {
        button.imageScaling = .scaleProportionallyDown
        button.image = image
        button.imagePosition = .imageOnly
        button.contentTintColor = MeetingOverlayTokens.quietActionTint
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.layer?.backgroundColor = MeetingOverlayTokens.panelBg.withAlphaComponent(0.85).cgColor
        button.target = self
        button.action = action
        button.toolTip = nil
        button.setAccessibilityIdentifier(automationIdentifier)
        button.setAccessibilityLabel(accessibilityLabel)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard event.trackingArea === hoverTrackingArea else {
            super.mouseEntered(with: event)
            return
        }
        setHeaderRevealed(true)
    }

    override func mouseExited(with event: NSEvent) {
        guard event.trackingArea === hoverTrackingArea else {
            super.mouseExited(with: event)
            return
        }
        setHeaderRevealed(false)
    }

    private func setHeaderRevealed(_ revealed: Bool) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            hoverBar.animator().alphaValue = revealed ? 1 : 0
        }
    }

    func update(transcript: NSAttributedString, statusText: String?, hasEntries: Bool) {
        self.statusText = statusText
        self.hasEntries = hasEntries
        statusLabel.stringValue = statusText ?? ""
        statusLabel.isHidden = statusText == nil
        scrollView.isHidden = !hasEntries
        copyButton.isEnabled = hasEntries

        let wasPinnedToBottom: Bool = {
            guard let documentView = scrollView.documentView else { return true }
            let visible = scrollView.contentView.documentVisibleRect
            return visible.maxY >= documentView.frame.height - 28
        }()
        textView.textStorage?.setAttributedString(transcript)
        if wasPinnedToBottom {
            textView.scrollToEndOfDocument(nil)
        }
        needsLayout = true
    }

    /// Called right before the drawer becomes visible so the latest lines
    /// are on screen once the first real layout lands.
    func prepareForReveal() {
        needsScrollToEnd = true
        needsLayout = true
    }

    /// Brief checkmark feedback after a successful copy.
    func flashCopyFeedback() {
        copyFeedbackTask?.cancel()
        copyButton.image = Self.copyConfirmationImage()
        copyButton.contentTintColor = OverlayTokens.accentGreen
        copyFeedbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled, let self else { return }
            self.copyButton.image = Self.copyButtonImage()
            self.copyButton.contentTintColor = MeetingOverlayTokens.quietActionTint
        }
    }

    override func layout() {
        super.layout()
        let pad = MeetingOverlayTokens.drawerPad
        let top = bounds.height

        separator.frame = NSRect(x: pad, y: top - 1, width: bounds.width - pad * 2, height: 1)

        let buttonSize = MeetingOverlayTokens.drawerBrowserButtonSize
        let barWidth = buttonSize * 2 + 6
        hoverBar.frame = NSRect(
            x: bounds.width - pad - barWidth,
            y: top - 8 - buttonSize,
            width: barWidth,
            height: buttonSize
        )
        copyButton.frame = NSRect(x: 0, y: 0, width: buttonSize, height: buttonSize)
        moreButton.frame = NSRect(x: buttonSize + 6, y: 0, width: buttonSize, height: buttonSize)

        resizeHandle.frame = NSRect(
            x: 0,
            y: 0,
            width: bounds.width,
            height: MeetingOverlayTokens.drawerResizeHandleHeight
        )

        var contentTop = top - 7
        if statusLabel.isHidden {
            statusLabel.frame = .zero
        } else {
            let statusWidth = bounds.width - pad * 2
            let statusHeight = statusLabel.sizeThatFits(
                NSSize(width: statusWidth, height: .greatestFiniteMagnitude)
            ).height
            statusLabel.frame = NSRect(
                x: pad,
                y: contentTop - statusHeight,
                width: statusWidth,
                height: statusHeight
            )
            contentTop -= statusHeight + 6
        }

        if scrollView.isHidden {
            scrollView.frame = .zero
        } else {
            let bottom = MeetingOverlayTokens.drawerResizeHandleHeight + 2
            scrollView.frame = NSRect(
                x: pad,
                y: bottom,
                width: bounds.width - pad * 2,
                height: max(0, contentTop - bottom)
            )
            // Wait for the drawer to have real height before consuming the
            // pin — the first layout ticks of the reveal animation are only
            // a few points tall.
            if needsScrollToEnd, scrollView.frame.height > 40 {
                needsScrollToEnd = false
                textView.scrollToEndOfDocument(nil)
            }
        }
    }

    @objc private func handleCopyTranscript() {
        onCopyTranscript?()
    }

    @objc private func handleMoreMenu() {
        let menu = NSMenu()
        let copyItem = NSMenuItem(
            title: MeetingLiveViewAffordancePolicy.copyTranscriptMenuTitle,
            action: #selector(handleMenuCopy),
            keyEquivalent: ""
        )
        copyItem.target = self
        copyItem.isEnabled = hasEntries
        menu.addItem(copyItem)

        let browserItem = NSMenuItem(
            title: MeetingLiveViewAffordancePolicy.openInBrowserMenuTitle,
            action: #selector(handleMenuOpenInBrowser),
            keyEquivalent: ""
        )
        browserItem.target = self
        menu.addItem(browserItem)

        menu.popUp(
            positioning: nil,
            at: NSPoint(x: moreButton.frame.minX, y: moreButton.frame.minY - 4),
            in: hoverBar
        )
    }

    @objc private func handleMenuCopy() {
        onCopyTranscript?()
    }

    @objc private func handleMenuOpenInBrowser() {
        onOpenInBrowser?()
    }

    private static func copyButtonImage() -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        return NSImage(
            systemSymbolName: "doc.on.doc",
            accessibilityDescription: MeetingLiveViewAffordancePolicy.copyTooltip
        )?.withSymbolConfiguration(config)
    }

    private static func moreButtonImage() -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        return NSImage(
            systemSymbolName: "ellipsis",
            accessibilityDescription: MeetingLiveViewAffordancePolicy.moreTooltip
        )?.withSymbolConfiguration(config)
    }

    private static func copyConfirmationImage() -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        return NSImage(
            systemSymbolName: "checkmark",
            accessibilityDescription: "Copied"
        )?.withSymbolConfiguration(config)
    }
}

/// Bottom-edge grip that turns vertical drags into drawer-height deltas.
/// Swallows the drag so the movable-by-background panel does not move.
@available(macOS 14.0, *)
@MainActor
private final class MeetingLiveTranscriptResizeHandle: NSView {
    private let grabber = NSView()
    private var dragStartScreenY: CGFloat?

    var onDragBegan: (() -> Void)?
    var onDragChanged: ((CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        grabber.wantsLayer = true
        grabber.layer?.cornerRadius = 2
        grabber.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
        addSubview(grabber)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }

    override func layout() {
        super.layout()
        grabber.frame = NSRect(
            x: (bounds.width - 36) / 2,
            y: (bounds.height - 4) / 2,
            width: 36,
            height: 4
        )
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        // Screen coordinates, not window coordinates: the window's own
        // origin moves as the drawer resizes, which would feed back into a
        // window-relative drag delta.
        dragStartScreenY = NSEvent.mouseLocation.y
        onDragBegan?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartScreenY else { return }
        // Dragging downward (negative y) makes the drawer taller.
        onDragChanged?(dragStartScreenY - NSEvent.mouseLocation.y)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStartScreenY != nil else { return }
        dragStartScreenY = nil
        onDragEnded?()
    }
}
