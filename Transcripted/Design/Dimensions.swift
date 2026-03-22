import Foundation

// MARK: - Settings Window Dimensions

struct SettingsDimensions {
    static let windowWidth: CGFloat = 800
    static let windowHeight: CGFloat = 600
    static let sidebarWidth: CGFloat = 180
    static let contentWidth: CGFloat = 619
    static let statsCardHeight: CGFloat = 120
    static let statsCardMinWidth: CGFloat = 140
    static let heatMapCellSize: CGFloat = 24
    static let heatMapCellSpacing: CGFloat = 4
}

// MARK: - Design Tokens Namespace

enum DesignTokens {
    static let spacing = Spacing.self
    static let radius = Radius.self
    static let shadow = ShadowStyle.self
    static let animation = AnimationTiming.self
    static let accessibility = AccessibilityTokens.self
    static let pill = PillDimensions.self
    static let settings = SettingsDimensions.self
}
