import SwiftUI
import AppKit

/// Manages a small floating panel that displays the pill onboarding callout.
/// Positioned just above the pill's visual bounds (pill is pinned to the bottom of its window).
@available(macOS 26.0, *)
@MainActor
class PillCalloutController: NSWindowController {
    init(pillFrame: NSRect, onDismiss: @escaping () -> Void) {
        let calloutWidth: CGFloat = 320
        let calloutHeight: CGFloat = 120
        let arrowHeight: CGFloat = 14
        let gap: CGFloat = 12

        // The pill is pinned to the BOTTOM of its window with 10pt padding.
        // Its visual top is at: window.origin.y + 10 (bottom padding) + pill height
        let pillVisualTop = pillFrame.origin.y + 10 + PillDimensions.idleHeight
        let x = pillFrame.midX - calloutWidth / 2
        let y = pillVisualTop + gap

        let frame = NSRect(x: x, y: y, width: calloutWidth, height: calloutHeight + arrowHeight)

        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        super.init(window: panel)

        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isOpaque = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false

        let view = PillCalloutView(onDismiss: onDismiss)
        panel.contentView = NSHostingView(rootView: view)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }
}
