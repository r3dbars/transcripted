// NotchIslandAppIconCache.swift
// The "Insert into <app>" button's app icon, drawn once per take.
//
// The icon from NSRunningApplication is an IconServices image: drawing it at
// a new size can mean IconServices renders it right then. The dictation
// drop-down used to be rebuilt on every hover, and its button drew the icon
// through a drawing handler on every display pass. Now the icon is drawn
// once per take into a small bitmap at the button's size and the button
// shows that bitmap.

import AppKit

@MainActor
final class NotchIslandAppIconCache {
    private weak var owner: AnyObject?
    private var icon: NSImage?

    /// The icon for `owner` (the take's target app). `render` runs the first
    /// time for an owner; later calls for the same owner get the same image.
    /// No owner, no icon.
    func icon(for owner: AnyObject?, render: () -> NSImage?) -> NSImage? {
        guard let owner else { return nil }
        if let icon, self.owner === owner { return icon }
        let rendered = render()
        self.owner = owner
        icon = rendered
        return rendered
    }

    /// `icon` drawn into `side`-point bitmaps at 1x and 2x, in `colorSpace`
    /// (the island's screen). Float samples keep it within one level of
    /// drawing the icon straight onto the screen.
    static func bitmap(of icon: NSImage, side: CGFloat, colorSpace: NSColorSpace) -> NSImage {
        let size = NSSize(width: side, height: side)
        let image = NSImage(size: size)
        for scale in [CGFloat(1), 2] {
            let pixels = Int((side * scale).rounded())
            guard pixels > 0,
                  let blank = NSBitmapImageRep(
                      bitmapDataPlanes: nil,
                      pixelsWide: pixels,
                      pixelsHigh: pixels,
                      bitsPerSample: 32,
                      samplesPerPixel: 4,
                      hasAlpha: true,
                      isPlanar: false,
                      colorSpaceName: .deviceRGB,
                      bitmapFormat: .floatingPointSamples,
                      bytesPerRow: 0,
                      bitsPerPixel: 0
                  ),
                  let rep = blank.retagging(with: colorSpace) else { continue }
            rep.size = size
            guard let context = NSGraphicsContext(bitmapImageRep: rep) else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            icon.draw(in: NSRect(origin: .zero, size: size))
            context.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(rep)
        }
        return image
    }
}
