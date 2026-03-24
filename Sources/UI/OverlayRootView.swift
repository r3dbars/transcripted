// OverlayRootView.swift
// Root NSView for the floating overlay — composes header, content, toolbar
// Manages state-based visibility of child content views (lazy creation, never destruction)

import AppKit

@MainActor
final class OverlayRootView: NSView {
    // MARK: - Always-visible children

    let headerView = OverlayHeaderView(frame: .zero)
    private let topDivider = NSView()
    private let contentContainer = NSView()
    private let bottomDivider = NSView()
    let toolbarView = OverlayToolbarView(frame: .zero)

    // MARK: - Lazy content children (created on first use, reused across state transitions)

    private var _loadingView: OverlayLoadingView?
    var loadingView: OverlayLoadingView {
        if let v = _loadingView { return v }
        let v = OverlayLoadingView(frame: .zero)
        v.isHidden = true
        contentContainer.addSubview(v)
        _loadingView = v
        return v
    }

    private var _listeningView: OverlayListeningView?
    var listeningView: OverlayListeningView {
        if let v = _listeningView { return v }
        let v = OverlayListeningView(frame: .zero)
        v.isHidden = true
        contentContainer.addSubview(v)
        _listeningView = v
        return v
    }

    private var _draftingView: OverlayDraftingView?
    var draftingView: OverlayDraftingView {
        if let v = _draftingView { return v }
        let v = OverlayDraftingView(frame: .zero)
        v.isHidden = true
        contentContainer.addSubview(v)
        _draftingView = v
        return v
    }

    private var _streamingView: OverlayStreamingView?
    var streamingView: OverlayStreamingView {
        if let v = _streamingView { return v }
        let v = OverlayStreamingView(frame: .zero)
        v.isHidden = true
        contentContainer.addSubview(v)
        _streamingView = v
        return v
    }

    private var _reviewView: OverlayReviewView?
    var reviewView: OverlayReviewView {
        if let v = _reviewView { return v }
        let v = OverlayReviewView(frame: .zero)
        v.isHidden = true
        contentContainer.addSubview(v)
        _reviewView = v
        return v
    }

    // MARK: - State tracking

    private var currentState: FloatingOverlayController.OverlayState = .idle
    private var currentMode: FloatingOverlayController.SessionMode = .draft

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

        // Content container clips children
        contentContainer.wantsLayer = true
        contentContainer.layer?.masksToBounds = true
        addSubview(contentContainer)

        addSubview(headerView)
        addSubview(toolbarView)
    }

    // MARK: - Layout

    override func layout() {
        super.layout()

        let w = bounds.width
        let headerH = OverlayTokens.headerHeight
        let dividerH = OverlayTokens.dividerHeight
        let showContent = shouldShowContent()
        let toolbarH = showContent ? toolbarHeight() : 0

        // Header at top
        headerView.frame = NSRect(x: 0, y: bounds.height - headerH, width: w, height: headerH)

        if showContent {
            // Top divider below header
            topDivider.frame = NSRect(x: 0, y: bounds.height - headerH - dividerH, width: w, height: dividerH)
            topDivider.isHidden = false

            // Bottom divider above toolbar
            bottomDivider.frame = NSRect(x: 0, y: toolbarH, width: w, height: dividerH)
            bottomDivider.isHidden = toolbarH == 0

            // Toolbar at bottom
            toolbarView.frame = NSRect(x: 0, y: 0, width: w, height: toolbarH)

            // Content fills middle
            let contentTop = bounds.height - headerH - dividerH
            let contentBottom = toolbarH + (toolbarH > 0 ? dividerH : 0)
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
            toolbarView.frame = .zero
        }
    }

    private func shouldShowContent() -> Bool {
        if currentState == .idle { return false }
        // Listening stays compact unless transcript is expanded
        // (transcriptExpanded is managed via updateForState)
        if currentState == .listening, contentContainer.isHidden { return false }
        // Dictation drafting stays compact
        if currentState == .drafting, currentMode == .dictation { return false }
        return true
    }

    private func toolbarHeight() -> CGFloat {
        if currentState == .review || currentState == .diffFlash {
            return OverlayTokens.toolbarHeight
        }
        return 0
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
        let showContent: Bool
        switch state {
        case .idle:
            showContent = false
        case .listening:
            showContent = transcriptExpanded
        case .drafting:
            showContent = mode != .dictation
        case .loading, .streaming, .review, .diffFlash:
            showContent = true
        }

        contentContainer.isHidden = !showContent

        // Hide all content children, show the active one
        _loadingView?.isHidden = true
        _listeningView?.isHidden = true
        _draftingView?.isHidden = true
        _streamingView?.isHidden = true
        _reviewView?.isHidden = true

        if showContent {
            switch state {
            case .loading:
                loadingView.isHidden = false
                loadingView.update(elapsedSeconds: loadingElapsedSeconds)

            case .listening:
                listeningView.isHidden = false
                listeningView.updateTranscript(liveTranscript)
                listeningView.updatePlaceholder(
                    mode: mode,
                    draftHint: draftShortcutHint,
                    dictationHint: dictationShortcutHint
                )

            case .drafting:
                draftingView.isHidden = false
                let statusText = isTranscribing ? "Transcribing..." : "Processing..."
                draftingView.update(
                    error: errorMessage.isEmpty ? nil : errorMessage,
                    isTranscribing: isTranscribing,
                    transcriptText: liveTranscript,
                    statusText: statusText
                )

            case .streaming:
                streamingView.isHidden = false
                // Streaming tokens are appended separately via appendStreamToken()

            case .review:
                reviewView.isHidden = false
                reviewView.setEditable(true)
                // Text is set via showReview() in the controller, not here

            case .diffFlash:
                reviewView.isHidden = false
                reviewView.setEditable(false)

            case .idle:
                break
            }
        }

        // Update toolbar
        let hasEdits = !originalDraft.isEmpty && reviewText != originalDraft
        toolbarView.update(state: state, hasEdits: hasEdits, hasContext: hasContext)

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
