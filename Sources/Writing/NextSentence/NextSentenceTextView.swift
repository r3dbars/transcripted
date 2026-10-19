import AppKit

/// The card's text. Read-only until the user clicks or types into it; then a normal editable text
/// view. Hovering reports the word under the pointer (for other words, or where a fact came from);
/// scrolling over a word that has options rolls it. Dragging across several words, or double-clicking
/// one, picks it. Return inserts (held, it sends), Shift-Return adds a line, Esc stops editing.
final class NextSentenceTextView: NSTextView {
    var onBeginEditing: (() -> Void)?
    var onReturnDown: (() -> Void)?
    var onReturnUp: (() -> Void)?
    var onEscape: (() -> Void)?
    /// A word double-clicked, or a span of several words dragged across.
    var onPickSelection: ((NSRange) -> Void)?
    var onTextChange: (() -> Void)?
    /// The card's text style. While editing, everything in the box is kept in it, however the text
    /// got there (typing, paste, dictation, autocorrect), so edits never look different.
    var bodyStyle: [NSAttributedString.Key: Any] = [:]
    /// The word under the pointer and its rect in this view, or nil when it's over no word.
    var onHoverWord: ((NSRange, NSRect)?) -> Void = { _ in }
    /// Whether scrolling should roll the picked word or part (its options are showing) rather than scroll the text.
    var canRoll: () -> Bool = { false }
    /// One step of a roll: +1 brings in the option nearest the text, -1 the farthest.
    var onRoll: ((Int) -> Void)?
    /// A click that left nothing selected.
    var onSelectionCleared: (() -> Void)?
    private var hovered: NSRange?
    private var rollAccumulator: CGFloat = 0
    private var lastRoll = Date.distantPast
    private var rolledThisGesture = false

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        configure()
    }

    convenience init(width: CGFloat) {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        self.init(frame: NSRect(x: 0, y: 0, width: width, height: 22), textContainer: container)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configure() {
        drawsBackground = false
        isRichText = false
        isEditable = false
        isSelectable = true
        allowsUndo = true
        textContainerInset = .zero
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        insertionPointColor = NextSentenceCardStyle.accent
        selectedTextAttributes = [.backgroundColor: NextSentenceCardStyle.accent.withAlphaComponent(0.42)]
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextCompletionEnabled = false
        if #available(macOS 14.0, *) { inlinePredictionType = .no }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
                                       owner: self))
    }

    /// The height the text needs at the current width.
    var neededHeight: CGFloat {
        guard let layoutManager, let textContainer else { return 22 }
        layoutManager.ensureLayout(for: textContainer)
        return max(22, ceil(layoutManager.usedRect(for: textContainer).height))
    }

    // MARK: Geometry

    /// The word (letters, digits, apostrophes) under `point`, if the point is on one.
    func wordRange(at point: NSPoint) -> NSRange? {
        guard let layoutManager, let textContainer, layoutManager.numberOfGlyphs > 0 else { return nil }
        let inContainer = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let glyph = layoutManager.glyphIndex(for: inContainer, in: textContainer, fractionOfDistanceThroughGlyph: &fraction)
        let glyphRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        guard glyphRect.insetBy(dx: -1, dy: -2).contains(inContainer) else { return nil }
        let text = string as NSString
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        guard index < text.length, Self.isWordCharacter(text.character(at: index)) else { return nil }
        var start = index
        var end = index + 1
        while start > 0, Self.isWordCharacter(text.character(at: start - 1)) { start -= 1 }
        while end < text.length, Self.isWordCharacter(text.character(at: end)) { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    /// The rect of `range`'s first line, in this view's coordinates.
    func rect(for range: NSRange) -> NSRect {
        guard let layoutManager, let textContainer else { return .zero }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var first = NSRect.zero
        layoutManager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                              in: textContainer) { rect, stop in
            first = rect
            stop.pointee = true
        }
        return first.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    /// Where the text ends: just after the last character, on its line.
    var endPoint: NSPoint {
        let length = (string as NSString).length
        guard length > 0 else { return NSPoint(x: 0, y: 0) }
        let last = rect(for: NSRange(location: length - 1, length: 1))
        return NSPoint(x: last.maxX, y: last.minY)
    }

    /// `range` without spaces or punctuation at either end.
    static func trimmed(_ range: NSRange, in text: NSString) -> NSRange {
        var start = range.location
        var end = NSMaxRange(range)
        let edge = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        func isEdge(_ index: Int) -> Bool { Unicode.Scalar(text.character(at: index)).map { edge.contains($0) } ?? false }
        while start < end, isEdge(start) { start += 1 }
        while end > start, isEdge(end - 1) { end -= 1 }
        return NSRange(location: start, length: end - start)
    }

    private static func isWordCharacter(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet.alphanumerics.contains(scalar) || unit == 0x27 || unit == 0x2019
    }

    // MARK: Pointer

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateHover(event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hover(at: nil)
    }

    private func updateHover(_ event: NSEvent) {
        hover(at: convert(event.locationInWindow, from: nil))
    }

    /// The card also calls this from its own pointer tracking: NSTextView manages its tracking
    /// areas itself and can drop the one added here.
    func hover(at point: NSPoint?) {
        let range = point.flatMap { wordRange(at: $0) }
        guard range != hovered else { return }
        hovered = range
        rollAccumulator = 0
        onHoverWord(range.map { ($0, rect(for: $0)) })
    }

    override func scrollWheel(with event: NSEvent) {
        guard canRoll() else { return super.scrollWheel(with: event) }
        // Momentum doesn't keep rolling: one flick or one wheel notch is one option.
        guard event.momentumPhase.isEmpty else { return }
        if event.phase == .began { rollAccumulator = 0; rolledThisGesture = false }
        rollAccumulator += event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 12)
        // The first movement of a gesture rolls at once; after that, every 10pt or so.
        let needed: CGFloat = rolledThisGesture ? 10 : 2
        guard abs(rollAccumulator) >= needed, Date().timeIntervalSince(lastRoll) > 0.07 else { return }
        rolledThisGesture = event.hasPreciseScrollingDeltas
        // Fingers moving up (content scrolling down) brings in the option nearest the word.
        let step = rollAccumulator < 0 ? 1 : -1
        rollAccumulator = 0
        lastRoll = Date()
        onRoll?(step)
    }

    override func mouseDown(with event: NSEvent) {
        if !isEditable { onBeginEditing?() }
        super.mouseDown(with: event) // tracks until mouse up
        let range = Self.trimmed(selectedRange(), in: string as NSString)
        guard range.length > 0 else { return onSelectionCleared?() ?? () }
        // A word or several, highlighted by double-click or drag: offer other words for it.
        setSelectedRange(range)
        onPickSelection?(range)
    }

    // MARK: Keys while editing

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn && !event.modifierFlags.contains(.shift) {
            if !event.isARepeat { onReturnDown?() }
            return
        }
        if event.keyCode == 53 { return onEscape?() ?? () }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn && !event.modifierFlags.contains(.shift) { return onReturnUp?() ?? () }
        super.keyUp(with: event)
    }

    override func didChangeText() {
        super.didChangeText()
        if isEditable { applyBodyStyle() }
        onTextChange?()
    }

    /// Restyles all of the text (outside any text still being composed) and what's typed next.
    func applyBodyStyle() {
        guard !bodyStyle.isEmpty, let storage = textStorage, storage.length > 0, !hasMarkedText() else {
            if !bodyStyle.isEmpty { typingAttributes = bodyStyle }
            return
        }
        storage.beginEditing()
        storage.setAttributes(bodyStyle, range: NSRange(location: 0, length: storage.length))
        storage.endEditing()
        typingAttributes = bodyStyle
    }
}
