import Foundation

/// Where the main Transcripted window should open.
///
/// The window is built at contentRect origin (0, 0) and `center()` runs only
/// in the controller's `init`, before the window is on a screen. `present()`
/// then just orders it front. That is how a first launch (and a saved frame
/// from a display that is gone) can land in a corner instead of on a
/// connected screen. This type is the placement decision, with no AppKit, so
/// tests can feed it screens.
enum MainWindowFramePolicy {
    static let defaultSize = CGSize(width: 980, height: 760)

    static func frame(
        savedFrame: CGRect?,
        windowSize: CGSize,
        visibleFrames: [CGRect],
        preferredVisibleFrame: CGRect
    ) -> CGRect {
        // Pre-fix: trust a saved frame even when it is off every connected
        // screen, and use the constructor origin (0, 0) when there is none.
        _ = visibleFrames
        _ = preferredVisibleFrame
        if let savedFrame {
            return savedFrame
        }
        let size = windowSize.width >= 1 && windowSize.height >= 1 ? windowSize : defaultSize
        return CGRect(origin: .zero, size: size)
    }
}
