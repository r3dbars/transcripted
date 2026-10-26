import AppKit

/// A small tab on the card's top edge: grab it to move the card anywhere on screen. It reports points
/// on screen, because the card's window moves under the pointer.
final class NextSentenceMoveTab: NextSentenceFlippedView {
    static let size = CGSize(width: 44, height: 14)
    var onDragStart: ((NSPoint) -> Void)?
    var onDrag: ((NSPoint) -> Void)?
    var onDragEnd: (() -> Void)?
    private let bar = NSView()
    private var dragging = false
    private var hovering = false

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(origin: frameRect.origin, size: Self.size))
        wantsLayer = true
        // Barely there, but solid enough that a click on it lands here.
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.01).cgColor
        bar.wantsLayer = true
        addSubview(bar)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .cursorUpdate, .inVisibleRect],
                                       owner: self))
        paint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { isHidden ? nil : super.hitTest(point) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        NSCursor.openHand.set()
        paint()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        if !dragging { NSCursor.arrow.set() }
        paint()
    }

    override func cursorUpdate(with event: NSEvent) { (dragging ? NSCursor.closedHand : NSCursor.openHand).set() }

    override func mouseDown(with event: NSEvent) {
        dragging = true
        NSCursor.closedHand.set()
        paint()
        onDragStart?(NSEvent.mouseLocation)
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        onDrag?(NSEvent.mouseLocation)
    }

    override func mouseUp(with event: NSEvent) {
        dragging = false
        (hovering ? NSCursor.openHand : NSCursor.arrow).set()
        paint()
        onDragEnd?()
    }

    private func paint() {
        let active = hovering || dragging
        let size = CGSize(width: active ? 32 : 24, height: 4)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.allowsImplicitAnimation = true
            bar.frame = NSRect(x: (Self.size.width - size.width) / 2, y: (Self.size.height - size.height) / 2, width: size.width, height: size.height)
            bar.layer?.cornerRadius = size.height / 2
            bar.layer?.backgroundColor = NSColor(white: 1, alpha: active ? 0.55 : 0.2).cgColor
        }
    }
}
