#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif

/// Coordinate mapping for the window-only capture. Pure geometry — no
/// ScreenCaptureKit or Vision types — so it is testable without a live
/// display or a granted Screen Recording permission. (Per-block attribution
/// across several windows went away with full-display capture: Screen
/// Memory reads only the focused window now.)
enum WindowAttribution {
    /// Maps a Vision OCR box back to display-relative space when the capture
    /// itself was scoped to a single window (`SCContentFilter(desktopIndependentWindow:)`).
    /// In that path Vision's `boundingBox` is normalized 0...1 against the
    /// *captured window image*, not the display — every downstream consumer
    /// (`ScreenScene`'s bubble-width gates, speaker bucketing)
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
