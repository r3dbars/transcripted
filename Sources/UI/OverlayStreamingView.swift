// OverlayStreamingView.swift
// Content view during streaming state — tokens stream in with auto-scroll

import AppKit

@MainActor
final class OverlayStreamingView: NSView {
    private let scrollView = NSScrollView()
    private let textView: NSTextView

    override init(frame: NSRect) {
        // Create text view with text container
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)
        textView = NSTextView(frame: .zero, textContainer: textContainer)

        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupViews() {
        // Text view config
        textView.isEditable = false
        textView.isSelectable = false
        textView.isRichText = false
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.textColor = OverlayTokens.textPrimary
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(width: 8, height: 8)

        // Scroll view
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        scrollView.automaticallyAdjustsContentInsets = false
        addSubview(scrollView)
    }

    override func layout() {
        super.layout()
        let pad = OverlayTokens.contentPadding
        scrollView.frame = NSRect(
            x: pad - 8,  // Offset for textContainerInset
            y: 8,
            width: bounds.width - (pad - 8) * 2,
            height: bounds.height - 16
        )
        textView.minSize = NSSize(width: scrollView.contentSize.width, height: 0)
        textView.maxSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
    }

    func appendToken(_ token: String) {
        guard let storage = textView.textStorage else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: OverlayTokens.textPrimary
        ]
        storage.append(NSAttributedString(string: token, attributes: attrs))
        textView.scrollToEndOfDocument(nil)
    }

    func clear() {
        textView.string = ""
    }
}
