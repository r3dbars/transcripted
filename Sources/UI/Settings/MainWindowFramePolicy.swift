import Foundation

/// Where the main Transcripted window should open.
///
/// The window is built at contentRect origin (0, 0) and `center()` used to
/// run only in the controller's `init`, before the window is on a screen.
/// `present()` then just ordered it front. On recent macOS that pre-show
/// `center()` is ignored, and the first `orderFront` of a window with no
/// restored frame gets the system default — the bottom-trailing corner.
/// This type is the placement decision, with no AppKit, so tests can feed
/// it screens. The controller applies it at present-time, and again after
/// `orderFront` if AppKit moved the window.
enum MainWindowFramePolicy {
    static let defaultSize = CGSize(width: 980, height: 760)
    /// AppKit titlebar strip used to decide whether the user can still drag
    /// a restored window. Unified chrome is taller; 22 pt is enough to tell
    /// "the top of the window is on a connected screen" from "it is not".
    static let titlebarHeight: CGFloat = 22
    static let minTitlebarOverlapWidth: CGFloat = 50

    static func frame(
        savedFrame: CGRect?,
        windowSize: CGSize,
        visibleFrames: [CGRect],
        preferredVisibleFrame: CGRect
    ) -> CGRect {
        let size = resolvedSize(windowSize)
        if let savedFrame, isUsable(savedFrame, on: visibleFrames) {
            return savedFrame
        }
        return centered(size: size, in: preferredVisibleFrame)
    }

    private static func isUsable(_ frame: CGRect, on visibleFrames: [CGRect]) -> Bool {
        guard frame.width >= 1, frame.height >= 1,
              frame.width.isFinite, frame.height.isFinite,
              frame.origin.x.isFinite, frame.origin.y.isFinite else {
            return false
        }
        let barHeight = min(titlebarHeight, frame.height)
        let titlebar = CGRect(
            x: frame.minX,
            y: frame.maxY - barHeight,
            width: frame.width,
            height: barHeight
        )
        return visibleFrames.contains { screen in
            guard screen.width >= 1, screen.height >= 1 else { return false }
            let hit = screen.intersection(titlebar)
            return !hit.isNull && hit.width >= minTitlebarOverlapWidth && hit.height > 0
        }
    }

    private static func resolvedSize(_ size: CGSize) -> CGSize {
        size.width >= 1 && size.height >= 1 ? size : defaultSize
    }

    private static func centered(size: CGSize, in visible: CGRect) -> CGRect {
        let width = min(max(size.width, 1), max(visible.width, 1))
        let height = min(max(size.height, 1), max(visible.height, 1))
        let x = visible.minX + (visible.width - width) / 2
        let y = visible.minY + (visible.height - height) / 2
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
