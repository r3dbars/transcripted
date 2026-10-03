import AppKit

extension NotchIslandView {
    /// Puts the show-time blur filter on the content once at launch, while
    /// the panel is drawn at alpha 0, so the first real show doesn't pay to
    /// set up Core Image. The caller drops it again with `resetBlur()`.
    static func prewarmBlur(on view: NSView) {
        guard !NotchIslandPalette.reduceMotion,
              let filter = CIFilter(name: "CIGaussianBlur") else { return }
        view.layerUsesCoreImageFilters = true
        filter.name = "islandBlur"
        filter.setValue(NotchIslandMotion.blurRadius, forKey: kCIInputRadiusKey)
        view.contentFilters = [filter]
    }
}
