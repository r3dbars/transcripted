import AppKit

/// Turns an Accessibility rect (top-left origin) into Cocoa screen
/// coordinates; the Notch island uses it to find the focused field's display.
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
}
