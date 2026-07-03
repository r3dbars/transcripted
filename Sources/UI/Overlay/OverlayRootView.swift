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
        topDivider.layer?.backgroundColor = OverlayTokens.dividerColor.cgColor
        addSubview(topDivider)

        bottomDivider.wantsLayer = true
        bottomDivider.layer?.backgroundColor = OverlayTokens.dividerColor.cgColor
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

        if showContent {
            // Header at top when content is visible underneath it.
            headerView.frame = NSRect(x: 0, y: bounds.height - headerH, width: w, height: headerH)

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
            // Compact state: let the header occupy the full height so its contents can sit
            // perfectly centered within the pill.
            headerView.frame = bounds
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
        dictationShortcutHint: String,
        errorMessage: String,
        errorActionTitle: String?,
        onErrorAction: (() -> Void)?,
        onErrorDismiss: (() -> Void)?,
        loadingPresentation: FloatingOverlayController.LoadingPresentation,
        loadingElapsedSeconds: Int,
        successTitle: String,
        isTranscribing: Bool,
        isRecording: Bool,
        isMiniCursorMode: Bool,
        audioLevel: Float,
        liveTranscript: String
    ) {
        currentState = state
        currentErrorMessage = errorMessage

        let showLoading = state == .loading
        let showError = state == .drafting && !errorMessage.isEmpty
        let showContent = showLoading || showError

        // Update header
        headerView.update(
            state: state,
            dictationShortcutHint: dictationShortcutHint,
            loadingTitle: state == .loading ? "Dictation" : nil,
            successTitle: successTitle,
            isError: showError,
            isMiniCursorMode: isMiniCursorMode,
            meterPresentation: DictationMeterPolicy.presentation(
                isListening: state == .listening,
                sttIsRecording: isRecording,
                rawLevel: audioLevel,
                showsQuietStartupWaveform: state == .starting && isMiniCursorMode
            )
        )

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
                errorActionTitle: errorActionTitle,
                onErrorAction: onErrorAction,
                onErrorDismiss: onErrorDismiss,
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

        titleLabel.frame = NSRect(x: pad, y: 9, width: contentWidth, height: 16)
        detailLabel.frame = NSRect(x: pad, y: 29, width: contentWidth, height: 28)
        progressBar.frame = NSRect(x: pad, y: 59, width: contentWidth, height: 6)
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
