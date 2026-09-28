#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif

/// Maps one OCR text block back to the window it most likely came from.
/// Pure geometry — no ScreenCaptureKit or Vision types — so it is testable
/// with synthetic window lists, independent of a live display or a granted
/// Screen Recording permission.
enum WindowAttribution {
    struct WindowInfo: Equatable, Sendable {
        let bundleIdentifier: String?
        let windowIdentifier: UInt32?
        let title: String?
        /// Same top-left-origin space, normalized to the captured display,
        /// as the OCR block's `boundingBox`.
        let frame: NormalizedDisplayRect

        init(
            bundleIdentifier: String?,
            windowIdentifier: UInt32? = nil,
            title: String?,
            frame: NormalizedDisplayRect
        ) {
            self.bundleIdentifier = bundleIdentifier
            self.windowIdentifier = windowIdentifier
            self.title = title
            self.frame = frame
        }
    }

    /// `windows` must be front-to-back ordered (frontmost first) — Apple
    /// does not document an ordering guarantee for
    /// `SCShareableContent.windows`, so the caller is responsible for
    /// sorting (ScreenCaptureService sorts by `windowLayer`) before calling
    /// this. The first window whose frame contains the block's center point
    /// wins, so a block sitting in the overlap of two windows attributes to
    /// whichever is actually on top, not whichever the OS happened to
    /// enumerate first.
    static func attribute(boundingBox: NormalizedDisplayRect, frontToBackWindows windows: [WindowInfo]) -> WindowInfo? {
        windows.first { $0.frame.contains(x: boundingBox.centerX, y: boundingBox.centerY) }
    }

    /// Maps a Vision OCR box back to display-relative space when the capture
    /// itself was scoped to a single window (`SCContentFilter(desktopIndependentWindow:)`).
    /// In that path Vision's `boundingBox` is normalized 0...1 against the
    /// *captured window image*, not the display — every downstream consumer
    /// (attribution, `ScreenScene`'s bubble-width gates, speaker bucketing)
    /// assumes display-relative boxes, so this affine-transforms the
    /// window-relative box through the window's own display-normalized frame
    /// before a `ScreenSnapshot.TextBlock` is ever built. Pure geometry, no
    /// ScreenCaptureKit/Vision types, so it is testable without a live
    /// display.
    static func mapWindowRelativeBox(
        _ box: NormalizedDisplayRect,
        windowFrame: NormalizedDisplayRect
    ) -> NormalizedDisplayRect {
        NormalizedDisplayRect(
            x: windowFrame.x + box.x * windowFrame.width,
            y: windowFrame.y + box.y * windowFrame.height,
            width: box.width * windowFrame.width,
            height: box.height * windowFrame.height
        )
    }
}
