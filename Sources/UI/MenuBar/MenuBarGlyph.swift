// MenuBarGlyph.swift
// The menu bar icon: the app icon's outlined speech bubble with the hidden "T",
// drawn in code as a one-color template image so macOS tints it for light and
// dark menu bars (and for the highlighted state when the popover is open).
//
// Filled means capturing; the dot means a meeting. There is no color on
// purpose, so the always-visible icon stays quiet during screen sharing.
//
// MenuBarGlyphGeometry is the app icon's own, in its 1024-unit design space
// (docs/assets/app-icon-options/round8/H-mono-light.svg). It mirrors
// docs/assets/menu-bar-icon/make_menu_bar_icons.py — keep the numbers in sync.
// At menu bar size the icon's outer pair of bars smears into the wall, so the
// glyph keeps the stem and one pair of side bars.

import AppKit

enum MenuBarGlyph: CaseIterable {
    case idle
    case dictating
    case meetingRecording

    static let pointSize: CGFloat = 18

    /// One image per state and label, so refreshes keep AppKit's cached
    /// renders instead of redrawing the paths. The status item only asks from
    /// the main thread today; the lock keeps the cache safe if that changes.
    private static var imageCache: [String: NSImage] = [:]
    private static let imageCacheLock = NSLock()

    func image(accessibilityDescription: String?) -> NSImage {
        let cacheKey = "\(self)|\(accessibilityDescription ?? "")"
        Self.imageCacheLock.lock()
        defer { Self.imageCacheLock.unlock() }
        if let cached = Self.imageCache[cacheKey] {
            return cached
        }
        let glyph = self
        let size = NSSize(width: Self.pointSize, height: Self.pointSize)
        let image = NSImage(size: size, flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            glyph.draw(in: rect, context: context)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription
        Self.imageCache[cacheKey] = image
        return image
    }

    /// Draws into a y-down context. Knockouts happen inside a transparency
    /// layer so they only clear the glyph, never whatever is behind it.
    func draw(in rect: CGRect, context: CGContext) {
        let box = MenuBarGlyphGeometry.box
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: rect.width / box.width, y: rect.height / box.height)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.setLineWidth(MenuBarGlyphGeometry.strokeWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setStrokeColor(NSColor.black.cgColor)
        context.setFillColor(NSColor.black.cgColor)

        switch self {
        case .idle:
            context.addPath(MenuBarGlyphGeometry.outlinePath())
            context.addPath(MenuBarGlyphGeometry.crossbarPath())
            context.addPath(MenuBarGlyphGeometry.stemPath(from: MenuBarGlyphGeometry.top))
            context.addPath(MenuBarGlyphGeometry.sideBarsPath())
            context.strokePath()
        case .dictating, .meetingRecording:
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            context.addPath(MenuBarGlyphGeometry.bodyPath())
            context.drawPath(using: .fillStroke)
            context.setBlendMode(.clear)
            // The stem starts under the top edge, so the solid top edge reads
            // as the T's crossbar.
            context.addPath(MenuBarGlyphGeometry.stemPath(from: MenuBarGlyphGeometry.top + MenuBarGlyphGeometry.strokeWidth))
            context.addPath(MenuBarGlyphGeometry.sideBarsPath())
            context.strokePath()
            if self == .meetingRecording {
                context.fillEllipse(in: MenuBarGlyphGeometry.dotRect(radius: MenuBarGlyphGeometry.dotRadius + MenuBarGlyphGeometry.dotRing))
                context.setBlendMode(.normal)
                context.fillEllipse(in: MenuBarGlyphGeometry.dotRect(radius: MenuBarGlyphGeometry.dotRadius))
            }
            context.endTransparencyLayer()
        }
    }
}

/// Internal (not private) so the fast tests can check these numbers against
/// docs/assets/menu-bar-icon/make_menu_bar_icons.py.
enum MenuBarGlyphGeometry {
    static let strokeWidth: CGFloat = 60
    static let left: CGFloat = 236
    static let right: CGFloat = 788
    static let top: CGFloat = 246
    static let bottom: CGFloat = 676
    static let radius: CGFloat = 110
    static let centerX: CGFloat = 512
    static let barMidY: CGFloat = 450
    static let crossbarHalfLength: CGFloat = 110
    static let crossbarGap: CGFloat = 26
    static let stemBottom: CGFloat = 585
    static let sideBarOffset: CGFloat = 138
    static let sideBarHeight: CGFloat = 200
    static let dotCenter = CGPoint(x: 744, y: 757)
    static let dotRadius: CGFloat = 84
    static let dotRing: CGFloat = 44
    /// Square centred on the mark (bounds incl. stroke are x 206...818,
    /// y 216...834). The padding keeps the mark about 16 pt tall in the 18 pt
    /// image, like a menu bar SF Symbol.
    static let box = CGRect(x: 162, y: 175, width: 700, height: 700)

    static let topLeft = CGPoint(x: left + radius, y: top + radius)
    static let bottomLeft = CGPoint(x: left + radius, y: bottom - radius)
    static let bottomRight = CGPoint(x: right - radius, y: bottom - radius)
    static let topRight = CGPoint(x: right - radius, y: top + radius)

    /// The open outline: it starts and ends on the top corner arcs, leaving a
    /// gap on each side of the crossbar.
    static func outlinePath() -> CGPath {
        let path = CGMutablePath()
        let endX = centerX - crossbarHalfLength - strokeWidth - crossbarGap
        let theta = asin(((left + radius) - endX) / radius)
        let up = -CGFloat.pi / 2
        addCorner(to: path, center: topLeft, from: up - theta, to: -.pi)
        path.addLine(to: CGPoint(x: left, y: bottom - radius))
        addCorner(to: path, center: bottomLeft, from: .pi, to: .pi / 2)
        addTail(to: path)
        addCorner(to: path, center: bottomRight, from: .pi / 2, to: 0)
        path.addLine(to: CGPoint(x: right, y: top + radius))
        addCorner(to: path, center: topRight, from: 0, to: up + theta)
        return path
    }

    /// The closed bubble silhouette for the filled states.
    static func bodyPath() -> CGPath {
        let path = CGMutablePath()
        addCorner(to: path, center: topLeft, from: -.pi / 2, to: -.pi)
        path.addLine(to: CGPoint(x: left, y: bottom - radius))
        addCorner(to: path, center: bottomLeft, from: .pi, to: .pi / 2)
        addTail(to: path)
        addCorner(to: path, center: bottomRight, from: .pi / 2, to: 0)
        path.addLine(to: CGPoint(x: right, y: top + radius))
        addCorner(to: path, center: topRight, from: 0, to: -.pi / 2)
        path.closeSubpath()
        return path
    }

    static func crossbarPath() -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: centerX - crossbarHalfLength, y: top))
        path.addLine(to: CGPoint(x: centerX + crossbarHalfLength, y: top))
        return path
    }

    static func stemPath(from startY: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: centerX, y: startY))
        path.addLine(to: CGPoint(x: centerX, y: stemBottom))
        return path
    }

    static func sideBarsPath() -> CGPath {
        let path = CGMutablePath()
        for x in [centerX - sideBarOffset, centerX + sideBarOffset] {
            path.move(to: CGPoint(x: x, y: barMidY - sideBarHeight / 2))
            path.addLine(to: CGPoint(x: x, y: barMidY + sideBarHeight / 2))
        }
        return path
    }

    static func dotRect(radius: CGFloat) -> CGRect {
        CGRect(x: dotCenter.x - radius, y: dotCenter.y - radius, width: radius * 2, height: radius * 2)
    }

    private static func addTail(to path: CGMutablePath) {
        path.addLine(to: CGPoint(x: 404, y: bottom))
        path.addQuadCurve(to: CGPoint(x: 350, y: 804), control: CGPoint(x: 396, y: 748))
        path.addQuadCurve(to: CGPoint(x: 504, y: bottom), control: CGPoint(x: 446, y: 770))
        path.addLine(to: CGPoint(x: right - radius, y: bottom))
    }

    /// Appends a circular arc as one cubic Bezier. Angles are radians in the
    /// y-down design space and may run either way, so there is no clockwise
    /// flag to get backwards in a flipped context.
    private static func addCorner(to path: CGMutablePath, center: CGPoint, from start: CGFloat, to end: CGFloat) {
        let k = 4 / 3 * tan((end - start) / 4)
        let p0 = CGPoint(x: center.x + radius * cos(start), y: center.y + radius * sin(start))
        let p3 = CGPoint(x: center.x + radius * cos(end), y: center.y + radius * sin(end))
        let c1 = CGPoint(x: p0.x - k * radius * sin(start), y: p0.y + k * radius * cos(start))
        let c2 = CGPoint(x: p3.x + k * radius * sin(end), y: p3.y - k * radius * cos(end))
        if path.isEmpty {
            path.move(to: p0)
        }
        path.addCurve(to: p3, control1: c1, control2: c2)
    }
}
