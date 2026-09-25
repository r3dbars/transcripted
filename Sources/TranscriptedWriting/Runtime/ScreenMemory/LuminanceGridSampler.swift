#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif
import CoreGraphics

/// Downsamples a captured `CGImage` into the coarse grayscale grid
/// `CaptureChangeDetector` diffs frame-to-frame. Thin CoreGraphics shim, same
/// tested-boundary convention as the rest of this file's neighbors
/// (`ScreenTextRecognizer`, `WindowAttribution`'s callers): the geometry math
/// is Core and unit-tested, the CGContext/CGImage plumbing that produces its
/// input is not, because it cannot run without a real bitmap.
enum LuminanceGridSampler {
    static func sample(
        _ image: CGImage,
        columns: Int = CaptureChangeDetector.LuminanceGrid.defaultColumns,
        rows: Int = CaptureChangeDetector.LuminanceGrid.defaultRows
    ) -> CaptureChangeDetector.LuminanceGrid? {
        guard columns > 0, rows > 0, image.width > 0, image.height > 0 else { return nil }

        guard let context = CGContext(
            data: nil,
            width: columns,
            height: rows,
            bitsPerComponent: 8,
            bytesPerRow: columns,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        // CGContext's default coordinate space is y-up, origin bottom-left,
        // while both the CGImage's own raster order and every convention in
        // this codebase (`NormalizedDisplayRect`, `ScreenTextRecognizer`'s
        // Vision-box flip) are top-left, y-down. Flipping the context before
        // drawing — translate to the top, then scale y by -1 — makes the
        // resulting raw buffer's row 0 the top of the image, so reading it
        // out row-major below lines up with that shared convention without
        // every caller having to remember to flip it themselves.
        context.interpolationQuality = .high
        context.translateBy(x: 0, y: CGFloat(rows))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: columns, height: rows))

        guard let data = context.data else { return nil }
        let buffer = data.bindMemory(to: UInt8.self, capacity: columns * rows)
        var tiles = [Double](repeating: 0, count: columns * rows)
        for index in 0..<(columns * rows) {
            tiles[index] = Double(buffer[index]) / 255.0
        }
        return CaptureChangeDetector.LuminanceGrid(columns: columns, rows: rows, tiles: tiles)
    }
}
