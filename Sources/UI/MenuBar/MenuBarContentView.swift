// MenuBarContentView.swift
// Root NSView for the menubar popover.

import AppKit

struct MenuBarContentSmokeSnapshot: Codable, Equatable {
    let header: MenuBarHeaderSmokeSnapshot
    let primaryActions: [String: MenuBarActionRowSmokeSnapshot]
}

@MainActor
final class MenuBarContentView: NSView {
    private let scrollView = NSScrollView()
    private let documentView = FlippedMenuDocumentView()
    private let headerDivider = NSView()
    private let sectionDivider = NSView()
    private var documentHeight: CGFloat = MenuTokens.panelHeight

    let headerView = MenuBarHeaderView(frame: .zero)
    let updateCalloutRow = MenuBarActionRowView(frame: .zero)
    let primaryActionsView = MenuBarPrimaryActionsView(frame: .zero)
    let utilityActionsView = MenuBarUtilityActionsView(frame: .zero)

    var onUpdateAction: (() -> Void)? {
        didSet {
            updateCalloutRow.onPress = { [weak self] in
                self?.onUpdateAction?()
            }
        }
    }

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

        [headerDivider, sectionDivider].forEach {
            $0.wantsLayer = true
            $0.layer?.backgroundColor = MenuTokens.sectionDividerNS.cgColor
            documentView.addSubview($0)
        }

        updateCalloutRow.isHidden = true
        [headerView, updateCalloutRow, primaryActionsView, utilityActionsView].forEach(documentView.addSubview(_:))
    }

    override func layout() {
        super.layout()

        scrollView.frame = bounds

        let pad = MenuTokens.innerPadding
        let width = bounds.width - pad * 2
        var y = pad

        let headerHeight = headerView.intrinsicHeight
        headerView.isHidden = headerHeight <= 0
        headerDivider.isHidden = headerHeight <= 0
        if headerHeight > 0 {
            headerView.frame = NSRect(x: pad, y: y, width: width, height: headerHeight)
            y += headerHeight + 8

            headerDivider.frame = NSRect(x: pad, y: y, width: width, height: 1)
            y += 7
        } else {
            headerView.frame = .zero
            headerDivider.frame = .zero
        }

        if !updateCalloutRow.isHidden {
            let updateHeight = updateCalloutRow.intrinsicContentSize.height
            updateCalloutRow.frame = NSRect(x: pad, y: y, width: width, height: updateHeight)
            y += updateHeight + 7
        } else {
            updateCalloutRow.frame = .zero
        }

        let primaryHeight = primaryActionsView.intrinsicHeight
        primaryActionsView.frame = NSRect(x: pad, y: y, width: width, height: primaryHeight)
        y += primaryHeight + MenuTokens.sectionSpacing

        sectionDivider.frame = NSRect(x: pad, y: y, width: width, height: 1)
        y += 7

        let utilityHeight = utilityActionsView.intrinsicHeight
        utilityActionsView.frame = NSRect(x: pad, y: y, width: width, height: utilityHeight)
        y += utilityHeight + pad

        documentHeight = y
        documentView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: y)
    }

    func scrollToTop() {
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func updateProminentUpdate(
        symbolName: String,
        title: String,
        detail: String,
        trailingText: String?,
        tone: MenuBarActionRowView.Tone,
        isVisible: Bool,
        isEnabled: Bool
    ) {
        updateCalloutRow.isHidden = !isVisible
        if isVisible {
            updateCalloutRow.update(
                symbolName: symbolName,
                title: title,
                detail: detail,
                trailingText: trailingText,
                tone: tone,
                size: .primary,
                isEnabled: isEnabled
            )
        }
        needsLayout = true
    }

    var preferredPanelSize: NSSize {
        NSSize(width: MenuTokens.panelWidth, height: min(documentHeight, MenuTokens.panelHeight))
    }

    var smokeSnapshot: MenuBarContentSmokeSnapshot {
        MenuBarContentSmokeSnapshot(
            header: headerView.smokeSnapshot,
            primaryActions: primaryActionsView.smokeSnapshot
        )
    }
}

private final class FlippedMenuDocumentView: NSView {
    override var isFlipped: Bool { true }
}
