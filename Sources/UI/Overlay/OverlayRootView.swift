// OverlayRootView.swift
// Root NSView for the floating overlay — dictation now uses a compact header-first
// layout, only expanding to show error or recovery states.

import AppKit

@MainActor
final class OverlayRootView: NSView {
    override var allowsVibrancy: Bool { true }

    // MARK: - Always-visible children

    let headerView = OverlayHeaderView(frame: .zero)
    private let contentContainer = NSView()
    private let contentGlassView = NSGlassEffectView()
    private let contentGlassHostView = NSView()
    private let contentInnerContainer = NSView()

    // MARK: - Lazy content children (only drafting/error is still used in the compact dictation flow)

    private var _draftingView: OverlayDraftingView?
    var draftingView: OverlayDraftingView {
        if let v = _draftingView { return v }
        let v = OverlayDraftingView(frame: .zero)
        v.isHidden = true
        contentInnerContainer.addSubview(v)
        _draftingView = v
        return v
    }

    private var _loadingView: OverlayLoadingView?
    var loadingView: OverlayLoadingView {
        if let v = _loadingView { return v }
        let v = OverlayLoadingView(frame: .zero)
        v.isHidden = true
        contentInnerContainer.addSubview(v)
        _loadingView = v
        return v
    }

    // MARK: - State tracking

    private var currentState: FloatingOverlayController.OverlayState = .idle
    private var currentErrorMessage: String = ""

    // MARK: - Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupViews() {
        addSubview(headerView)

        contentContainer.wantsLayer = true
        contentContainer.layer?.masksToBounds = false

        contentGlassView.style = .regular
        contentGlassView.cornerRadius = OverlayTokens.contentCardCornerRadius
        contentGlassView.tintColor = OverlayTokens.contentCardTint
        contentContainer.addSubview(contentGlassView)

        contentGlassHostView.autoresizingMask = [.width, .height]
        contentGlassView.contentView = contentGlassHostView

        contentInnerContainer.wantsLayer = false
        contentGlassHostView.addSubview(contentInnerContainer)
        addSubview(contentContainer)
    }

    // MARK: - Layout

    override func layout() {
        super.layout()

        let w = bounds.width
        let headerH = OverlayTokens.headerHeight
        let showContent = shouldShowContent()

        if showContent {
            headerView.frame = NSRect(x: 0, y: bounds.height - headerH, width: w, height: headerH)

            let contentTop = bounds.height - headerH - OverlayTokens.contentGap
            let contentBottom = OverlayTokens.panelChromeInset
            let contentH = max(0, contentTop - contentBottom)
            let contentW = max(0, w - (OverlayTokens.panelChromeInset * 2))
            contentContainer.frame = NSRect(
                x: OverlayTokens.panelChromeInset,
                y: contentBottom,
                width: contentW,
                height: contentH
            )
            contentContainer.isHidden = false

            contentGlassView.frame = contentContainer.bounds
            contentGlassHostView.frame = contentGlassView.bounds
            contentInnerContainer.frame = contentGlassHostView.bounds.insetBy(
                dx: OverlayTokens.contentPadding,
                dy: OverlayTokens.contentPadding
            )

            for subview in contentInnerContainer.subviews {
                subview.frame = contentInnerContainer.bounds
            }
        } else {
            headerView.frame = bounds
            contentContainer.isHidden = true
        }
    }

    private func shouldShowContent() -> Bool {
        currentState == .loading || currentState == .drafting
    }

    // MARK: - State Updates

    func updateForState(
        _ state: FloatingOverlayController.OverlayState,
        dictationShortcutHint: String,
        errorMessage: String,
        errorActionTitle: String?,
        onErrorAction: (() -> Void)?,
        loadingPresentation: FloatingOverlayController.LoadingPresentation,
        loadingElapsedSeconds: Int,
        isTranscribing: Bool,
        liveTranscript: String
    ) {
        currentState = state
        currentErrorMessage = errorMessage

        // Update header
        headerView.update(
            state: state,
            dictationShortcutHint: dictationShortcutHint,
            loadingTitle: state == .loading ? loadingPresentation.title : nil
        )

        let showLoading = state == .loading
        let showDrafting = state == .drafting
        let showContent = showLoading || showDrafting

        contentContainer.isHidden = !showContent

        _loadingView?.isHidden = true
        _draftingView?.isHidden = true

        if showLoading {
            loadingView.isHidden = false
            loadingView.update(
                presentation: loadingPresentation,
                elapsedSeconds: loadingElapsedSeconds
            )
            contentGlassView.tintColor = OverlayTokens.contentCardTint
        }

        if showDrafting {
            draftingView.isHidden = false
            let statusText = isTranscribing ? "Transcribing..." : "Processing..."
            draftingView.update(
                error: errorMessage.isEmpty ? nil : errorMessage,
                errorActionTitle: errorActionTitle,
                onErrorAction: onErrorAction,
                isTranscribing: isTranscribing,
                transcriptText: liveTranscript,
                statusText: statusText
            )
            contentGlassView.tintColor = errorMessage.isEmpty
                ? OverlayTokens.processingGlassTint
                : OverlayTokens.warningGlassTint
        }

        if !showContent {
            contentGlassView.tintColor = OverlayTokens.contentCardTint
        }

        // Trigger relayout
        needsLayout = true
    }
}

// MARK: - Loading View (simple spinner + elapsed time)

@MainActor
final class OverlayLoadingView: NSView {
    override var allowsVibrancy: Bool { true }

    private let titleLabel = NSTextField(labelWithString: "Getting ready")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let progressBar = NSProgressIndicator()

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
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 14
        let contentWidth = max(0, bounds.width - pad * 2)

        titleLabel.frame = NSRect(x: pad, y: 12, width: contentWidth, height: 16)
        detailLabel.frame = NSRect(x: pad, y: 32, width: contentWidth, height: 16)
        progressBar.frame = NSRect(x: pad, y: 54, width: contentWidth, height: 6)
    }

    func update(
        presentation: FloatingOverlayController.LoadingPresentation,
        elapsedSeconds: Int
    ) {
        titleLabel.stringValue = presentation.title
        detailLabel.stringValue = presentation.detail
        progressBar.doubleValue = presentation.progress
        needsLayout = true
    }
}
