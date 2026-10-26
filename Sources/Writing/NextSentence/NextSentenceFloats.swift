import AppKit

/// Other words for the picked word or part, stacked just above it, the closest one nearest the text.
/// Click one to use it; scrolling rolls the nearest one in.
final class NextSentenceWordFloat: NextSentenceFlippedView {
    var onPick: ((String) -> Void)?
    private var chips: [NextSentenceOptionChip] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }


    /// Lays the options out top to bottom, and sizes itself so its bottom sits `gap` above `word`
    /// (a rect in the superview's coordinates).
    func show(_ options: [String], above word: NSRect, within limit: NSRect, gap: CGFloat = 6) {
        chips.forEach { $0.removeFromSuperview() }
        chips = options.map { option in
            let chip = NextSentenceOptionChip(text: option)
            chip.onPick = { [weak self] in self?.onPick?(option) }
            return chip
        }
        var y: CGFloat = 0
        var width: CGFloat = 0
        for chip in chips {
            let size = chip.fittingSize
            chip.frame = NSRect(x: 0, y: y, width: min(size.width, limit.width), height: size.height)
            addSubview(chip)
            y += size.height + 2
            width = max(width, min(size.width, limit.width))
        }
        let height = max(0, y - 2)
        let x = min(max(word.minX - 9, limit.minX), limit.maxX - width)
        frame = NSRect(x: x, y: max(limit.minY, word.minY - gap - height), width: width, height: height)
    }
}

final class NextSentenceOptionChip: NextSentenceFlippedView {
    var onPick: (() -> Void)?
    private let label = NextSentenceCardStyle.label(.systemFont(ofSize: 15, weight: .medium), NSColor(white: 1, alpha: 0.92))

    init(text: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.16, alpha: 1).cgColor
        layer?.cornerRadius = 7
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor(white: 1, alpha: 0.14).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.4
        layer?.shadowRadius = 6
        layer?.shadowOffset = CGSize(width: 0, height: -3)
        label.stringValue = text
        addSubview(label)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Measured from the text itself, so no option is ever cut short.
    private var textSize: NSSize {
        let size = (label.stringValue as NSString).size(withAttributes: [.font: label.font ?? NSFont.systemFont(ofSize: 15)])
        return NSSize(width: ceil(size.width) + 4, height: ceil(size.height))
    }

    override var fittingSize: NSSize {
        NSSize(width: textSize.width + 18, height: textSize.height + 6)
    }

    override func layout() {
        super.layout()
        let size = textSize
        label.frame = NSRect(x: 9, y: (bounds.height - size.height) / 2, width: min(size.width, bounds.width - 18), height: size.height)
    }

    override func mouseEntered(with event: NSEvent) {
        label.textColor = .white
        layer?.backgroundColor = NextSentenceCardStyle.accent.withAlphaComponent(0.85).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        label.textColor = NSColor(white: 1, alpha: 0.92)
        layer?.backgroundColor = NSColor(white: 0.16, alpha: 1).cgColor
    }

    override func mouseDown(with event: NSEvent) { onPick?() }
}

/// Where a shaded phrase came from: the meeting, dictation or note, and what was said.
final class NextSentenceSourceTip: NextSentenceFlippedView {
    private let heading = NextSentenceCardStyle.label(.systemFont(ofSize: 11, weight: .semibold), NSColor(white: 1, alpha: 0.6))
    private let quote = NSTextField(wrappingLabelWithString: "")
    static let maxWidth: CGFloat = 300

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.11, alpha: 1).cgColor
        layer?.cornerRadius = 10
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.4
        layer?.shadowRadius = 11
        quote.font = .systemFont(ofSize: 12)
        quote.textColor = NSColor(white: 1, alpha: 0.9)
        quote.maximumNumberOfLines = 4
        quote.lineBreakMode = .byTruncatingTail
        addSubview(heading)
        addSubview(quote)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Sizes to the text and sits just above `phrase` (a rect in the superview's coordinates),
    /// kept inside `limit`.
    func show(heading text: String, quote said: String, above phrase: NSRect, within limit: NSRect) {
        heading.stringValue = text
        quote.stringValue = said.isEmpty ? "" : "“\(said)”"
        let inner = Self.maxWidth - 20
        let headingWidth = min(inner, ceil(heading.intrinsicContentSize.width))
        quote.preferredMaxLayoutWidth = inner
        let quoteSize = said.isEmpty ? .zero : quote.sizeThatFits(NSSize(width: inner, height: 80))
        let width = max(headingWidth, min(inner, ceil(quoteSize.width))) + 20
        heading.frame = NSRect(x: 10, y: 7, width: width - 20, height: 14)
        quote.frame = NSRect(x: 10, y: 23, width: width - 20, height: ceil(quoteSize.height))
        let height = (said.isEmpty ? 21 : 25 + ceil(quoteSize.height)) + 7
        var origin = NSPoint(x: phrase.minX, y: phrase.minY - 8 - height)
        origin.x = min(max(origin.x, limit.minX), limit.maxX - width)
        origin.y = max(origin.y, limit.minY)
        frame = NSRect(origin: origin, size: NSSize(width: width, height: height))
    }
}
