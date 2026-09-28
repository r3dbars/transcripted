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
        // No painted surface: the content stays transparent so NSPopover's
        // native material provides the background, corner chrome, and the
        // Reduce Transparency behavior — the popover blends like system menus.
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = documentView
        addSubview(scrollView)

        sectionDivider.wantsLayer = true
        documentView.addSubview(sectionDivider)

        updateCalloutRow.isHidden = true
        updateCalloutRow.restsFilled = true
        for row in primaryActionsView.keyboardFocusableRows + [updateCalloutRow] {
            row.onHoverStart = { [weak self] in self?.playHoverTick(.menuHover) }
        }
        // Dictate has its own start and stop sounds, so it gets no press click.
        for row in [primaryActionsView.meetingButton, updateCalloutRow] {
            row.onPressStart = { [weak self] in self?.playPressClick() }
        }
        utilityActionsView.onRowHoverStart = { [weak self] in self?.playHoverTick(.menuRowHover) }
        utilityActionsView.onRowPressStart = { [weak self] in self?.playPressClick() }
        [headerView, updateCalloutRow, primaryActionsView, utilityActionsView].forEach(documentView.addSubview(_:))

        applyLayerColors()
    }

    // Layer colors are appearance-resolved snapshots, so they must be
    // re-applied whenever the popover's effective appearance flips.
    private func applyLayerColors() {
        sectionDivider.layer?.backgroundColor = menuResolvedCGColor(MenuTokens.sectionDividerNS)
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
        if headerHeight > 0 {
            headerView.frame = NSRect(x: pad, y: y, width: width, height: headerHeight)
            y += headerHeight + 10
        } else {
            headerView.frame = .zero
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

    /// A pointer already resting on a button when the menu opens shouldn't tick.
    func menuWillAppear() {
        hoverTickQuietUntil = ProcessInfo.processInfo.systemUptime + 0.35
    }

    // A very quiet tick when the pointer lands on Record, Dictate, or
    // Restart to Update, and a softer, lower one on the rows below. Sweeping
    // down the menu ticks once per row, never a buzz. Pressing Record, a row,
    // or Restart to Update adds a soft click. Silent while recording.
    private var hoverTickQuietUntil: TimeInterval = 0

    private func playHoverTick(_ cue: AppSoundPlayer.Cue) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= hoverTickQuietUntil, !isCapturing else { return }
        hoverTickQuietUntil = now + 0.08
        AppSoundPlayer.shared.play(cue)
    }

    private func playPressClick() {
        guard !isCapturing else { return }
        AppSoundPlayer.shared.play(.menuPress)
    }

    // The room mic could catch a menu sound mid-meeting or mid-dictation, so
    // they all stay silent while anything is recording.
    private var isCapturing: Bool {
        guard let appState else { return false }
        return appState.meetingSession.isRecording
            || appState.meetingSession.isCaptureSessionActive
            || appState.sttRouter.isRecording
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
