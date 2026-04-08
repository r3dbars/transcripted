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

    private var _loadingView: OverlayLoadingView?
    var loadingView: OverlayLoadingView {
        if let v = _loadingView { return v }
        let v = OverlayLoadingView(frame: .zero)
        v.isHidden = true
        contentContainer.addSubview(v)
        _loadingView = v
        return v
    }

    // MARK: - State tracking

    private var currentState: FloatingOverlayController.OverlayState = .idle
    private var currentMode: FloatingOverlayController.SessionMode = .dictation
    private var currentErrorMessage: String = ""

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
        if currentState == .loading { return true }
        return currentState == .drafting && !currentErrorMessage.isEmpty
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
        loadingPresentation: FloatingOverlayController.LoadingPresentation,
        loadingElapsedSeconds: Int,
        isTranscribing: Bool,
        liveTranscript: String,
        originalDraft: String,
        reviewText: String
    ) {
        currentState = state
        currentMode = mode
        currentErrorMessage = errorMessage

        // Update header
        headerView.update(
            state: state,
            mode: mode,
            transcriptExpanded: transcriptExpanded,
            draftShortcutHint: draftShortcutHint,
            dictationShortcutHint: dictationShortcutHint,
            loadingTitle: state == .loading ? loadingPresentation.title : nil
        )

        let showLoading = state == .loading
        let showError = state == .drafting && !errorMessage.isEmpty
        let showContent = showLoading || showError

        contentContainer.isHidden = !showContent

        _loadingView?.isHidden = true
        _draftingView?.isHidden = true

        if showLoading {
            loadingView.isHidden = false
            loadingView.update(
                presentation: loadingPresentation,
                elapsedSeconds: loadingElapsedSeconds
            )
        }

        if showError {
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
    private let titleLabel = NSTextField(labelWithString: "Loading dictation")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let progressBar = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private let elapsedLabel = NSTextField(labelWithString: "First launch can take a minute or two.")

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupViews() {
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = OverlayTokens.textPrimary
        titleLabel.isBezeled = false
        titleLabel.isEditable = false
        titleLabel.drawsBackground = false
        addSubview(titleLabel)

        detailLabel.font = NSFont.systemFont(ofSize: 11)
        detailLabel.textColor = OverlayTokens.textSecondary
        detailLabel.maximumNumberOfLines = 2
        addSubview(detailLabel)

        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.doubleValue = 0
        addSubview(progressBar)

        statusLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        statusLabel.textColor = OverlayTokens.textSecondary
        addSubview(statusLabel)

        elapsedLabel.font = NSFont.systemFont(ofSize: 11)
        elapsedLabel.textColor = OverlayTokens.textMuted
        elapsedLabel.isBezeled = false
        elapsedLabel.isEditable = false
        elapsedLabel.drawsBackground = false
        addSubview(elapsedLabel)
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 14
        let contentWidth = max(0, bounds.width - pad * 2)

        titleLabel.frame = NSRect(x: pad, y: 10, width: contentWidth, height: 16)
        detailLabel.frame = NSRect(x: pad, y: 30, width: contentWidth, height: 28)
        progressBar.frame = NSRect(x: pad, y: 64, width: contentWidth, height: 8)
        statusLabel.frame = NSRect(x: pad, y: 76, width: contentWidth, height: 12)
        elapsedLabel.frame = NSRect(x: pad, y: 88, width: contentWidth, height: 12)
    }

    func update(
        presentation: FloatingOverlayController.LoadingPresentation,
        elapsedSeconds: Int
    ) {
        titleLabel.stringValue = presentation.title
        detailLabel.stringValue = presentation.detail
        progressBar.doubleValue = presentation.progress
        statusLabel.stringValue = presentation.status
        if elapsedSeconds > 0 {
            elapsedLabel.stringValue = "First launch can take a minute or two. \(elapsedSeconds)s elapsed."
        } else {
            elapsedLabel.stringValue = "First launch can take a minute or two."
        }
        needsLayout = true
    }
}
