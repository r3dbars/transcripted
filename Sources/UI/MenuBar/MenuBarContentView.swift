// MenuBarContentView.swift
// Root NSView for the menubar popover — one unified surface with four zones.

import AppKit

@MainActor
final class MenuBarContentView: NSView {
    enum Page {
        case main
        case agentConnect
    }

    private let scrollView = NSScrollView()
    private let documentView = FlippedMenuDocumentView()

    let headerView = MenuBarHeaderView(frame: .zero)
    let shortcutsView = MenuBarShortcutsView(frame: .zero)
    let recentMeetingsView = MenuBarRecentMeetingsView(frame: .zero)
    let settingsView = MenuBarSettingsView(frame: .zero)
    let agentConnectView = MenuAgentConnectPageView(frame: .zero)

    private let recentsDivider = NSView()
    private let footerDivider = NSView()
    private var currentPage: Page = .main

    weak var appState: TranscriptedAppState?

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

        [recentsDivider, footerDivider].forEach {
            $0.wantsLayer = true
            $0.layer?.backgroundColor = MenuTokens.sectionDividerNS.cgColor
            documentView.addSubview($0)
        }

        documentView.addSubview(headerView)
        documentView.addSubview(shortcutsView)
        documentView.addSubview(recentMeetingsView)
        documentView.addSubview(settingsView)
        documentView.addSubview(agentConnectView)
        updatePageVisibility()
    }

    override func layout() {
        super.layout()

        scrollView.frame = bounds

        let pad = MenuTokens.innerPadding
        let width = bounds.width - pad * 2
        if currentPage == .agentConnect {
            let contentHeight = agentConnectView.intrinsicHeight
            agentConnectView.frame = NSRect(x: pad, y: pad, width: width, height: contentHeight)
            documentView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(contentHeight + pad * 2, bounds.height))
            return
        }

        let dividerHeight: CGFloat = 1
        var y = pad
        let headerHeight = headerView.intrinsicHeight
        headerView.frame = NSRect(x: pad, y: y, width: width, height: headerHeight)
        y += headerHeight + MenuTokens.sectionSpacing

        let shortcutsHeight = shortcutsView.intrinsicHeight
        shortcutsView.frame = NSRect(x: pad, y: y, width: width, height: shortcutsHeight)
        y += shortcutsHeight + MenuTokens.sectionSpacing

        if recentMeetingsView.hasContent {
            recentsDivider.isHidden = false
            recentsDivider.frame = NSRect(x: pad, y: y - (MenuTokens.sectionSpacing / 2), width: width, height: dividerHeight)

            let recentsHeight = recentMeetingsView.intrinsicHeight
            recentMeetingsView.isHidden = false
            recentMeetingsView.frame = NSRect(x: pad, y: y, width: width, height: recentsHeight)
            y += recentsHeight + MenuTokens.sectionSpacing
        } else {
            recentsDivider.isHidden = true
            recentMeetingsView.isHidden = true
        }

        footerDivider.frame = NSRect(x: pad, y: y - (MenuTokens.sectionSpacing / 2), width: width, height: dividerHeight)

        let footerHeight = settingsView.intrinsicHeight
        settingsView.frame = NSRect(x: pad, y: y, width: width, height: footerHeight)
        y += footerHeight + pad

        documentView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(y, bounds.height))
    }

    func showMainPage() {
        currentPage = .main
        updatePageVisibility()
        scrollToTop()
        needsLayout = true
    }

    func showAgentConnectPage() {
        currentPage = .agentConnect
        updatePageVisibility()
        scrollToTop()
        needsLayout = true
    }

    private func updatePageVisibility() {
        let isMain = currentPage == .main
        [headerView, shortcutsView, recentMeetingsView, settingsView, recentsDivider, footerDivider].forEach {
            $0.isHidden = !isMain
        }
        agentConnectView.isHidden = isMain
    }

    private func scrollToTop() {
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

private final class FlippedMenuDocumentView: NSView {
    override var isFlipped: Bool { true }
}
