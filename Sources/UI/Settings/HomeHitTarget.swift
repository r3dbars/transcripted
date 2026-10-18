import CoreGraphics

enum HomeHitTarget {
    static let minimum: CGFloat = 40
    static let compactVisibleSize: CGFloat = 26

    /// The hit shape for a control drawn at `visibleSize`: never under the
    /// floor, and never smaller than what's drawn.
    static func hitSize(forVisibleSize visibleSize: CGFloat) -> CGFloat {
        max(visibleSize, minimum)
    }
}
