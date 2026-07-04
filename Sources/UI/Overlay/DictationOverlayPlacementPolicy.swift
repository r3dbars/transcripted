import AppKit

enum DictationOverlayPlacementPolicy {
    static func cocoaRect(fromAccessibilityRect rect: CGRect, primaryScreenFrame: NSRect) -> NSRect? {
        guard rect.width > 0, rect.height > 0 else { return nil }
        return NSRect(
            x: rect.origin.x,
            y: primaryScreenFrame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    static func screenFrame(
        containing rect: NSRect?,
        mouseLocation: NSPoint,
        screenFrames: [NSRect],
        fallbackScreenFrame: NSRect?
    ) -> NSRect? {
        if let rect,
           let screen = screenFrames.first(where: { $0.contains(NSPoint(x: rect.midX, y: rect.midY)) }) {
            return screen
        }
        if let screen = screenFrames.first(where: { NSMouseInRect(mouseLocation, $0, false) }) {
            return screen
        }
        return fallbackScreenFrame ?? screenFrames.first
    }

    static func validatedTargetRect(_ rect: NSRect?, on screenFrame: NSRect?) -> NSRect? {
        guard let rect, let screenFrame else { return nil }
        guard rect.width > 0, rect.height > 0 else { return nil }
        guard rect.width <= screenFrame.width, rect.height <= screenFrame.height else { return nil }
        return rect
    }

    static func originAboveTarget(targetRect: NSRect, panelSize: NSSize) -> NSPoint {
        NSPoint(
            x: targetRect.midX - panelSize.width / 2,
            y: targetRect.maxY + 12
        )
    }
}
