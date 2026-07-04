import AppKit

enum CapturePillPlacementPolicy {
    static func selectedScreenFrame(
        mouseLocation: NSPoint,
        screenFrames: [NSRect],
        fallbackScreenFrame: NSRect?
    ) -> NSRect? {
        screenFrames.first { NSMouseInRect(mouseLocation, $0, false) }
            ?? fallbackScreenFrame
            ?? screenFrames.first
    }

    static func origin(panelSize: NSSize, visibleFrame: NSRect, inset: CGFloat = 18) -> NSPoint {
        NSPoint(
            x: visibleFrame.midX - panelSize.width / 2,
            y: visibleFrame.maxY - panelSize.height - inset
        )
    }
}
