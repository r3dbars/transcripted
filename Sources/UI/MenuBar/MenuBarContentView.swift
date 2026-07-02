// MenuBarContentView.swift
// Root NSView for the menubar popover.

import AppKit

struct MenuBarContentSmokeSnapshot: Codable, Equatable {
    let header: MenuBarHeaderSmokeSnapshot
    let updateCallout: MenuBarActionRowSmokeSnapshot
    let primaryActions: [String: MenuBarActionRowSmokeSnapshot]
    let utilityActions: [String: MenuBarActionRowSmokeSnapshot]
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
        wantsLayer = true
        layer?.cornerRadius = MenuTokens.surfaceCornerRadius
        layer?.masksToBounds = true
        layer?.borderWidth = 1

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = documentView
        addSubview(scrollView)

        [headerDivider, sectionDivider].forEach {
            $0.wantsLayer = true
            documentView.addSubview($0)
        }

        updateCalloutRow.isHidden = true
        [headerView, updateCalloutRow, primaryActionsView, utilityActionsView].forEach(documentView.addSubview(_:))

        applyLayerColors()
    }

    // Layer colors are appearance-resolved snapshots, so they must be
    // re-applied whenever the popover's effective appearance flips.
    private func applyLayerColors() {
        layer?.backgroundColor = menuResolvedCGColor(MenuTokens.surfaceBackgroundNS)
        layer?.borderColor = menuResolvedCGColor(MenuTokens.surfaceStrokeNS)
        [headerDivider, sectionDivider].forEach {
            $0.layer?.backgroundColor = menuResolvedCGColor(MenuTokens.sectionDividerNS)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyLayerColors()
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

        configureKeyViewLoop()
    }

    /// Chains the visible action rows into one explicit key-view loop so Tab
    /// travels them in visual order — update callout (when shown), then the
    /// primary section, then the utility section — matching
    /// `FocusOrderContract.menuBarPopoverOrder`. AppKit's inferred loop is
    /// unreliable for these manually laid-out flipped rows, so we set it.
    private func configureKeyViewLoop() {
        var chain: [MenuBarActionRowView] = []
        if !updateCalloutRow.isHidden {
            chain.append(updateCalloutRow)
        }
        chain.append(contentsOf: primaryActionsView.keyboardFocusableRows)
        chain.append(contentsOf: utilityActionsView.keyboardFocusableRows)

        for (index, row) in chain.enumerated() {
            row.nextKeyView = index + 1 < chain.count ? chain[index + 1] : chain.first
        }

        window?.initialFirstResponder = chain.first
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
            updateCallout: updateCalloutRow.smokeSnapshot,
            primaryActions: primaryActionsView.smokeSnapshot,
            utilityActions: utilityActionsView.smokeSnapshot
        )
    }
}

private final class FlippedMenuDocumentView: NSView {
    override var isFlipped: Bool { true }
}
