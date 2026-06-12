// MeetingLiveTranscriptDrawerView.swift
// The embedded live transcript drawer shown below the meeting recording pill.
// A self-contained container so the overlay can fade and clip the whole
// drawer as one unit while the panel animates its height.
//
// Pure AppKit renderer per the overlay observation pattern: the controller
// pushes content through `update(...)`; the only callback is the
// open-in-browser action.

import AppKit

@available(macOS 14.0, *)
@MainActor
final class MeetingLiveTranscriptDrawerView: NSView {
    private let separator = NSView()
    private let titleLabel = NSTextField(labelWithString: MeetingLiveViewAffordancePolicy.drawerTitle)
    private let browserButton = NSButton()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let scrollView = NSScrollView()
    private let textView = NSTextView()

    private var statusText: String?
    private var hasEntries = false
    private var needsScrollToEnd = false

    var onOpenInBrowser: (() -> Void)?

    /// The browser button, exposed so the root view can attach its custom
    /// tooltip tracking to it.
    var browserActionView: NSView { browserButton }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Clip children while the panel height animates so partially laid
        // out content never draws over the recording strip above.
        wantsLayer = true
        layer?.masksToBounds = true

        separator.wantsLayer = true
        separator.layer?.backgroundColor = MeetingOverlayTokens.panelStroke.cgColor
        addSubview(separator)

        titleLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        titleLabel.textColor = MeetingOverlayTokens.textSecondary
        addSubview(titleLabel)

        browserButton.imageScaling = .scaleProportionallyDown
        browserButton.image = Self.browserButtonImage()
        browserButton.imagePosition = .imageOnly
        browserButton.contentTintColor = MeetingOverlayTokens.quietActionTint
        browserButton.isBordered = false
        browserButton.target = self
        browserButton.action = #selector(handleOpenInBrowser)
        browserButton.toolTip = nil
        browserButton.setAccessibilityIdentifier(MeetingLiveViewAffordancePolicy.browserAutomationIdentifier)
        browserButton.setAccessibilityLabel(MeetingLiveViewAffordancePolicy.browserTooltip)
        addSubview(browserButton)

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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(transcript: NSAttributedString, statusText: String?, hasEntries: Bool) {
        self.statusText = statusText
        self.hasEntries = hasEntries
        statusLabel.stringValue = statusText ?? ""
        statusLabel.isHidden = statusText == nil
        scrollView.isHidden = !hasEntries

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

    override func layout() {
        super.layout()
        let pad = MeetingOverlayTokens.drawerPad
        let top = bounds.height

        separator.frame = NSRect(x: pad, y: top - 1, width: bounds.width - pad * 2, height: 1)

        let browserSize = MeetingOverlayTokens.drawerBrowserButtonSize
        let titleSize = titleLabel.fittingSize
        let headerRowHeight = max(titleSize.height, browserSize)
        let headerRowTop = top - 8
        titleLabel.frame = NSRect(
            x: pad,
            y: headerRowTop - headerRowHeight + (headerRowHeight - titleSize.height) / 2,
            width: min(titleSize.width, bounds.width - pad * 2 - browserSize - 8),
            height: titleSize.height
        )
        browserButton.frame = NSRect(
            x: bounds.width - pad - browserSize,
            y: headerRowTop - headerRowHeight + (headerRowHeight - browserSize) / 2,
            width: browserSize,
            height: browserSize
        )

        var contentTop = headerRowTop - headerRowHeight - 6
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
            scrollView.frame = NSRect(
                x: pad,
                y: MeetingOverlayTokens.drawerBottomInset,
                width: bounds.width - pad * 2,
                height: max(0, contentTop - MeetingOverlayTokens.drawerBottomInset)
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

    @objc private func handleOpenInBrowser() {
        onOpenInBrowser?()
    }

    private static func browserButtonImage() -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        return NSImage(
            systemSymbolName: "safari",
            accessibilityDescription: MeetingLiveViewAffordancePolicy.browserTooltip
        )?.withSymbolConfiguration(config)
    }
}
