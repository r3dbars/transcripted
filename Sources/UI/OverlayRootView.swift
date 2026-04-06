// OverlayRootView.swift
// Root NSView for the floating overlay — dictation now uses a compact header-first
// layout, only expanding to show error or recovery states.

import AppKit

@MainActor
final class OverlayRootView: NSView {
    // MARK: - Always-visible children

    let headerView = OverlayHeaderView(frame: .zero)
    private let topDivider = NSView()
    private let contentContainer = NSView()
    private let bottomDivider = NSView()
    let toolbarView = OverlayToolbarView(frame: .zero)

    // MARK: - Lazy content children (only drafting/error is still used in the compact dictation flow)

    private var _draftingView: OverlayDraftingView?
    var draftingView: OverlayDraftingView {
        if let v = _draftingView { return v }
        let v = OverlayDraftingView(frame: .zero)
        v.isHidden = true
        contentContainer.addSubview(v)
        _draftingView = v
        return v
    }

    // MARK: - State tracking

    private var currentState: FloatingOverlayController.OverlayState = .idle
    private var currentMode: FloatingOverlayController.SessionMode = .dictation

    // MARK: - Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupViews() {
        // Dividers
        topDivider.wantsLayer = true
        topDivider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        addSubview(topDivider)

        bottomDivider.wantsLayer = true
        bottomDivider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        addSubview(bottomDivider)

        addSubview(headerView)
        contentContainer.wantsLayer = true
        contentContainer.layer?.masksToBounds = true
        addSubview(contentContainer)
    }

    // MARK: - Layout

    override func layout() {
        super.layout()

        let w = bounds.width
        let headerH = OverlayTokens.headerHeight
        let dividerH = OverlayTokens.dividerHeight
        let showContent = shouldShowContent()

        // Header at top
        headerView.frame = NSRect(x: 0, y: bounds.height - headerH, width: w, height: headerH)

        if showContent {
            // Top divider below header
            topDivider.frame = NSRect(x: 0, y: bounds.height - headerH - dividerH, width: w, height: dividerH)
            topDivider.isHidden = false

            bottomDivider.isHidden = true

            // Content fills the space beneath the header divider.
            let contentTop = bounds.height - headerH - dividerH
            let contentBottom: CGFloat = 0
            let contentH = max(0, contentTop - contentBottom)
            contentContainer.frame = NSRect(x: 0, y: contentBottom, width: w, height: contentH)
            contentContainer.isHidden = false

            // Size all content children to fill container
            for subview in contentContainer.subviews {
                subview.frame = contentContainer.bounds
            }
        } else {
            topDivider.isHidden = true
            bottomDivider.isHidden = true
            contentContainer.isHidden = true
        }
    }

    private func shouldShowContent() -> Bool {
        if currentState == .idle { return false }
        return currentState == .drafting
    }

    // MARK: - State Updates

    func updateForState(
        _ state: FloatingOverlayController.OverlayState,
        mode: FloatingOverlayController.SessionMode,
        transcriptExpanded: Bool,
        hasContext: Bool,
        draftShortcutHint: String,
        dictationShortcutHint: String,
        errorMessage: String,
        loadingElapsedSeconds: Int,
        isTranscribing: Bool,
        liveTranscript: String,
        originalDraft: String,
        reviewText: String
    ) {
        currentState = state
        currentMode = mode

        // Update header
        headerView.update(
            state: state,
            mode: mode,
            transcriptExpanded: transcriptExpanded,
            draftShortcutHint: draftShortcutHint,
            dictationShortcutHint: dictationShortcutHint
        )

        // Determine if content area should be visible
        let showContent = state == .drafting && !errorMessage.isEmpty

        contentContainer.isHidden = !showContent

        _draftingView?.isHidden = true

        if showContent {
            draftingView.isHidden = false
            let statusText = isTranscribing ? "Transcribing..." : "Processing..."
            draftingView.update(
                error: errorMessage.isEmpty ? nil : errorMessage,
                isTranscribing: isTranscribing,
                transcriptText: liveTranscript,
                statusText: statusText
            )
        }

        // Trigger relayout
        needsLayout = true
    }
}

// MARK: - Loading View (simple spinner + elapsed time)

@MainActor
final class OverlayLoadingView: NSView {
    private let spinner = NSProgressIndicator()
    private let titleLabel = NSTextField(labelWithString: "Preparing voice model...")
    private let elapsedLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupViews() {
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isIndeterminate = true
        spinner.startAnimation(nil)
        addSubview(spinner)

        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = OverlayTokens.textSecondary
        titleLabel.isBezeled = false
        titleLabel.isEditable = false
        titleLabel.drawsBackground = false
        titleLabel.alignment = .center
        addSubview(titleLabel)

        elapsedLabel.font = NSFont.systemFont(ofSize: 11)
        elapsedLabel.textColor = OverlayTokens.textMuted
        elapsedLabel.isBezeled = false
        elapsedLabel.isEditable = false
        elapsedLabel.drawsBackground = false
        elapsedLabel.alignment = .center
        addSubview(elapsedLabel)
    }

    override func layout() {
        super.layout()
        let cx = bounds.midX
        let cy = bounds.midY
        let spinSize: CGFloat = 24
        let titleSize = titleLabel.fittingSize
        let elapsedSize = elapsedLabel.fittingSize

        let totalHeight = spinSize + 12 + titleSize.height + (elapsedLabel.isHidden ? 0 : 8 + elapsedSize.height)
        var y = cy + totalHeight / 2

        y -= spinSize
        spinner.frame = NSRect(x: cx - spinSize / 2, y: y, width: spinSize, height: spinSize)
        y -= 12 + titleSize.height
        titleLabel.frame = NSRect(x: 0, y: y, width: bounds.width, height: titleSize.height)

        if !elapsedLabel.isHidden {
            y -= 8 + elapsedSize.height
            elapsedLabel.frame = NSRect(x: 0, y: y, width: bounds.width, height: elapsedSize.height)
        }
    }

    func update(elapsedSeconds: Int) {
        if elapsedSeconds > 0 {
            elapsedLabel.stringValue = "This may take a moment on first launch (\(elapsedSeconds)s)"
            elapsedLabel.isHidden = false
        } else {
            elapsedLabel.isHidden = true
        }
        spinner.startAnimation(nil)
        needsLayout = true
    }
}
