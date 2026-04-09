// OverlayReviewView.swift
// Content view during review state — editable draft + live diff strip

import AppKit

@MainActor
final class OverlayReviewView: NSView {
    private let scrollView = NSScrollView()
    let reviewTextView: ReviewTextView
    private let diffDivider = NSView()
    let diffStrip = OverlayDiffStripView()

    /// The original AI draft, used for diff computation
    private var originalDraft: String = ""

    override init(frame: NSRect) {
        // Create ReviewTextView with text container
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)
        reviewTextView = ReviewTextView(frame: .zero, textContainer: textContainer)

        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupViews() {
        // Draft text view
        reviewTextView.isVerticallyResizable = true
        reviewTextView.isHorizontallyResizable = false
        reviewTextView.textContainerInset = NSSize(width: 8, height: 8)

        // Scroll view
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.documentView = reviewTextView
        addSubview(scrollView)

        // Diff divider
        diffDivider.wantsLayer = true
        diffDivider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        diffDivider.isHidden = true
        addSubview(diffDivider)

        // Diff strip (below editor)
        diffStrip.isHidden = true
        addSubview(diffStrip)

        // Listen for text changes to update diff
        reviewTextView.onTextChange = { [weak self] text in
            self?.updateDiffStrip(editedText: text)
        }
    }

    override func layout() {
        super.layout()
        let pad = OverlayTokens.contentPadding
        let diffVisible = !diffStrip.isHidden
        let diffHeight: CGFloat = diffVisible ? 28 : 0
        let dividerHeight: CGFloat = diffVisible ? 1 : 0

        // Diff strip at bottom
        diffStrip.frame = NSRect(
            x: 0,
            y: 0,
            width: bounds.width,
            height: diffHeight
        )

        // Divider above diff strip
        diffDivider.frame = NSRect(
            x: 0,
            y: diffHeight,
            width: bounds.width,
            height: dividerHeight
        )

        // Scroll view fills rest
        let scrollTop = diffHeight + dividerHeight
        scrollView.frame = NSRect(
            x: pad - 8,
            y: scrollTop + 4,
            width: bounds.width - (pad - 8) * 2,
            height: bounds.height - scrollTop - 4
        )

        // Size text view to fit scroll content
        reviewTextView.minSize = NSSize(width: scrollView.contentSize.width, height: 0)
        reviewTextView.maxSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        reviewTextView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
    }

    func update(text: String, originalDraft: String) {
        self.originalDraft = originalDraft
        reviewTextView.string = text
        updateDiffStrip(editedText: text)
    }

    func setEditable(_ editable: Bool) {
        reviewTextView.isEditable = editable
    }

    private func updateDiffStrip(editedText: String) {
        guard !originalDraft.isEmpty else {
            diffStrip.isHidden = true
            diffDivider.isHidden = true
            needsLayout = true
            return
        }

        let hasEdits = DiffSummary.hasSubstantiveEdits(original: originalDraft, edited: editedText)
        diffStrip.isHidden = !hasEdits
        diffDivider.isHidden = !hasEdits

        if hasEdits {
            diffStrip.update(original: originalDraft, edited: editedText)
        }
        needsLayout = true
    }
}
