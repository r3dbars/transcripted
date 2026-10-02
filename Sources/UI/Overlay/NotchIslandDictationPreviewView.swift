// NotchIslandDictationPreviewView.swift
// The dictation hover's live words: the whole take so far, scrolled to the
// newest line, with older text fading out at the top. Scroll up to read
// back; it stops following until you scroll to the bottom again. Words the
// decoder may still rewrite are dimmed. When the take is written, the rough
// words crossfade into the real text. Kept alive by the island controller
// across drop-down rebuilds and updated in place, like the meeting's live
// transcript view.

import AppKit

@MainActor
final class NotchIslandDictationPreviewView: NSView {
    static let visibleLines = 3
    static let lineHeight: CGFloat = 20
    static var height: CGFloat { CGFloat(visibleLines) * lineHeight }
    /// The last words of the partial are still settling.
    static let tentativeWordCount = 2

    private static let font = NSFont.systemFont(ofSize: 14)
    private static let settledColor = NotchIslandPalette.bodyText
    private static let tentativeColor = NSColor(white: 1, alpha: 0.42)
    private static let paragraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        return style
    }()

    private let scrollView = NSScrollView()
    private let textView: NSTextView
    private let placeholder: NSTextField
    private let fade = CAGradientLayer()
    /// The latest words while the drop-down is closed. Laying out text no
    /// one can see would only cost main-thread time during the dictation.
    private var pending: (preview: LiveDictationPreview, settling: Bool)?
    /// The written text, once the take landed; nil while it's still rough.
    private(set) var finalText: String?
    private(set) var hasWords = false

    init(width: CGFloat) {
        let size = NSSize(width: width, height: Self.height)
        textView = NSTextView(frame: NSRect(origin: .zero, size: size))
        placeholder = NotchIslandPalette.label("Listening…", font: Self.font, color: NotchIslandPalette.secondaryText)
        super.init(frame: NSRect(origin: .zero, size: size))
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: Self.height),
        ])

        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = false
        textView.isRichText = true
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.scrollerKnobStyle = .light
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        addSubview(scrollView)

        // Older lines fade out under the top edge instead of being cut.
        wantsLayer = true
        fade.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor]
        fade.locations = [0, 0.28, 1]
        layer?.mask = fade

        let placeholderHeight = ceil(placeholder.fittingSize.height)
        placeholder.frame = NSRect(x: 0, y: 0, width: width, height: placeholderHeight)
        addSubview(placeholder)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Live dictation")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        fade.frame = bounds
    }

    /// The rough words so far. A new take (nothing heard yet) also clears
    /// the last take's written text.
    func apply(_ preview: LiveDictationPreview, settling: Bool) {
        if preview.isEmpty {
            finalText = nil
            textView.alphaValue = 1
        }
        guard finalText == nil else { return }
        hasWords = !preview.isEmpty
        guard window != nil else {
            pending = (preview, settling)
            return
        }
        pending = nil
        placeholder.isHidden = hasWords
        setText(Self.attributed(preview, settling: settling), forceFollow: !hasWords)
        setAccessibilityValue(hasWords ? "\(preview.settled) \(preview.tentative)" : "Listening")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, let pending {
            apply(pending.preview, settling: pending.settling)
        }
    }

    /// The take was written: show the real text in place of the rough words.
    func showFinal(_ text: String) {
        guard hasWords, finalText != text else { return }
        finalText = text
        pending = nil
        setAccessibilityValue(text)
        let final = NSAttributedString(string: text, attributes: Self.attributes(Self.settledColor))
        guard window != nil, !NotchIslandPalette.reduceMotion else {
            setText(final, forceFollow: true)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14
            textView.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.finalText == text else { return }
                self.setText(final, forceFollow: true)
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    self.textView.animator().alphaValue = 1
                }
            }
        })
    }

    /// Shows the newest words, as when the drop-down opens.
    func scrollToNewest() {
        guard let container = textView.textContainer else { return }
        textView.layoutManager?.ensureLayout(for: container)
        textView.scrollToEndOfDocument(nil)
    }

    private func setText(_ text: NSAttributedString, forceFollow: Bool) {
        let follows = forceFollow || isScrolledToBottom
        textView.textStorage?.setAttributedString(text)
        // A short take sits on the bottom line, where the newest words of a
        // long one are.
        if let container = textView.textContainer, let layoutManager = textView.layoutManager {
            layoutManager.ensureLayout(for: container)
            let used = ceil(layoutManager.usedRect(for: container).height)
            textView.textContainerInset = NSSize(width: 0, height: max(0, Self.height - used))
        }
        if follows { scrollToNewest() }
    }

    private var isScrolledToBottom: Bool {
        let visible = scrollView.contentView.documentVisibleRect
        return visible.maxY >= textView.frame.height - Self.lineHeight / 2
    }

    static func attributed(_ preview: LiveDictationPreview, settling: Bool) -> NSAttributedString {
        let parts = preview.split(dimmingLast: settling ? tentativeWordCount : 0)
        let result = NSMutableAttributedString(string: parts.settled, attributes: attributes(settledColor))
        if !parts.tentative.isEmpty {
            result.append(NSAttributedString(
                string: (result.length > 0 ? " " : "") + parts.tentative,
                attributes: attributes(tentativeColor)
            ))
        }
        return result
    }

    private static func attributes(_ color: NSColor) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
    }
}
