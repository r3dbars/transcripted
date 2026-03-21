import SwiftUI

// MARK: - Dark Panel Theme Colors + Attention/Notification Colors

extension Color {
    // MARK: - Dark Panel Theme
    static let panelCharcoal = Color(hex: "#1A1A1A")
    static let panelCharcoalElevated = Color(hex: "#242424")
    static let panelCharcoalSurface = Color(hex: "#2E2E2E")
    static let panelTextPrimary = Color(hex: "#FFFFFF")
    static let panelTextSecondary = Color(hex: "#B0B0B0")
    static let panelTextMuted = Color(hex: "#8A8A8A")
    static let chatBubbleUser = Color(hue: 0.583, saturation: 0.45, brightness: 0.28)
    static let recordingCoral = Color(hex: "#FF6B6B")
    static let recordingCoralDeep = Color(hex: "#E85555")

    // MARK: - Attention/Notification Colors
    static let attentionGreen = Color(hex: "#22C55E")
    static let attentionGreenDeep = Color(hex: "#16A34A")
    static let attentionGreenGlow = Color(hex: "#22C55E").opacity(0.5)
    static let errorRed = Color(hex: "#EF4444")
    static let errorRedGlow = Color(hex: "#EF4444").opacity(0.5)

    // MARK: - Premium UI Colors
    static let premiumCoral = Color(hex: "#FF8F75")
    static let softWhite = Color(hex: "#F5F5F7")
    static let glassBorder = Color.white.opacity(0.15)
    static let glassBackground = Color.black.opacity(0.4)
}
