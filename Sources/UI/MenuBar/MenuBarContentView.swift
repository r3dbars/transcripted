// MenuBarContentView.swift
// Root NSView for the menubar popover.

import AppKit

@MainActor
final class MenuBarContentView: NSView {
    private let scrollView = NSScrollView()
    private let documentView = FlippedMenuDocumentView()

    let headerView = MenuBarHeaderView(frame: .zero)
    let primaryActionsView = MenuBarPrimaryActionsView(frame: .zero)
    let utilityActionsView = MenuBarUtilityActionsView(frame: .zero)

    weak var appState: TranscriptedAppState? {
        didSet {
            utilityActionsView.appState = appState
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupViews() {
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.cornerRadius = MenuTokens.surfaceCornerRadius
        layer?.masksToBounds = true
        layer?.backgroundColor = MenuTokens.surfaceBackgroundNS.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = MenuTokens.surfaceStrokeNS.cgColor

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = documentView
        addSubview(scrollView)

        [headerView, primaryActionsView, utilityActionsView].forEach(documentView.addSubview(_:))
    }

    override func layout() {
        super.layout()

        scrollView.frame = bounds

        let pad = MenuTokens.innerPadding
        let width = bounds.width - pad * 2
        var y = pad

        let headerHeight = headerView.intrinsicHeight
        headerView.frame = NSRect(x: pad, y: y, width: width, height: headerHeight)
        y += headerHeight + 12

        let primaryHeight = primaryActionsView.intrinsicHeight
        primaryActionsView.frame = NSRect(x: pad, y: y, width: width, height: primaryHeight)
        y += primaryHeight + MenuTokens.sectionSpacing

        let utilityHeight = utilityActionsView.intrinsicHeight
        utilityActionsView.frame = NSRect(x: pad, y: y, width: width, height: utilityHeight)
        y += utilityHeight + pad

        documentView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(y, bounds.height))
    }

    func scrollToTop() {
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

private final class FlippedMenuDocumentView: NSView {
    override var isFlipped: Bool { true }
}
