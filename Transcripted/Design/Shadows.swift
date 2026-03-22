import SwiftUI

// MARK: - Card Style (Laws of UX)

struct CardStyle {
    static let shadowSubtle = (color: Color.black.opacity(0.10), radius: CGFloat(2), x: CGFloat(0), y: CGFloat(1))
    static let shadowCard = (color: Color.black.opacity(0.15), radius: CGFloat(8), x: CGFloat(0), y: CGFloat(4))
    static let shadowHover = (color: Color.black.opacity(0.20), radius: CGFloat(12), x: CGFloat(0), y: CGFloat(6))
    static let hoverScale: CGFloat = 1.02
    static let borderColor = Color.accentBlue.opacity(0.15)
    static let borderWidth: CGFloat = 1
}

// MARK: - Shadow Style

struct ShadowStyle {
    let color: Color
    let radius: CGFloat
    let x: CGFloat
    let y: CGFloat

    static let subtle = ShadowStyle(color: Color.black.opacity(0.04), radius: 8, x: 0, y: 2)
    static let medium = ShadowStyle(color: Color.black.opacity(0.08), radius: 16, x: 0, y: 4)
    static let elevated = ShadowStyle(color: Color.black.opacity(0.12), radius: 24, x: 0, y: 8)
    static let buttonGlow = ShadowStyle(color: Color.terracotta.opacity(0.3), radius: 16, x: 0, y: 4)
    static let successGlow = ShadowStyle(color: Color.successGreen.opacity(0.3), radius: 12, x: 0, y: 2)
    static let recordingGlow = ShadowStyle(color: Color.recordingCoral.opacity(0.5), radius: 12, x: 0, y: 0)
    static let auroraMicGlow = ShadowStyle(color: Color.auroraCoral.opacity(0.6), radius: 16, x: 0, y: 0)
    static let auroraSystemGlow = ShadowStyle(color: Color.auroraTeal.opacity(0.6), radius: 16, x: 0, y: 0)
    static let recordingGlowSubtle = ShadowStyle(color: Color.recordingCoral.opacity(0.3), radius: 8, x: 0, y: 0)
    static let idleHint = ShadowStyle(color: Color.white.opacity(0.15), radius: 4, x: 0, y: 0)
}

// MARK: - Shadow View Modifier

extension View {
    func shadowStyle(_ style: ShadowStyle) -> some View {
        self.shadow(color: style.color, radius: style.radius, x: style.x, y: style.y)
    }
}

// MARK: - Premium Card Style ("Night Studio")

struct PremiumCardStyle {
    static let gradientTop = Color(hex: "#292929")
    static let gradientBottom = Color(hex: "#232323")
    static let highlightOpacity: Double = 0.06
    static let borderOpacityTop: Double = 0.08
    static let borderOpacityBottom: Double = 0.02
    static let hoverGlowOpacity: Double = 0.15
    static let hoverGlowRadius: CGFloat = 20
    static let shadowRest = ShadowStyle(color: Color.black.opacity(0.3), radius: 8, x: 0, y: 4)
    static let shadowHover = ShadowStyle(color: Color.black.opacity(0.4), radius: 12, x: 0, y: 6)
}
