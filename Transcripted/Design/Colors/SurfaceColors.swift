import SwiftUI

// MARK: - Surface & Accent Colors (Laws of UX Warm Minimalism)

extension Color {
    // MARK: - Primary Surfaces (Warm Cream)
    static let surfaceBackground = Color(hue: 0.167, saturation: 0.10, brightness: 0.92)
    static let surfaceEggshell = Color(hue: 0.153, saturation: 0.62, brightness: 0.89)
    static let surfaceCard = Color(hue: 0.167, saturation: 0.08, brightness: 0.96)

    // MARK: - Dark Mode Surfaces (Blue-tinted, not pure black)
    static let surfaceDarkBase = Color(hue: 0.556, saturation: 0.50, brightness: 0.05)
    static let surfaceDarkCard = Color(hue: 0.556, saturation: 0.50, brightness: 0.15)
    static let surfaceDarkHover = Color(hue: 0.556, saturation: 0.50, brightness: 0.25)

    // MARK: - Accent Colors (Laws of UX Blue)
    static let accentBlue = Color(hue: 0.556, saturation: 0.50, brightness: 0.40)
    static let accentBlueLight = Color(hue: 0.556, saturation: 0.35, brightness: 0.55)

    // MARK: - Text on Cream
    static let textOnCream = Color(hue: 0.556, saturation: 0.50, brightness: 0.10)
    static let textOnCreamSecondary = Color(hue: 0.556, saturation: 0.30, brightness: 0.35)
    static let textOnCreamMuted = Color(hue: 0.167, saturation: 0.10, brightness: 0.52)

    // MARK: - Status Colors (Muted)
    static let statusSuccessMuted = Color(hue: 0.389, saturation: 0.60, brightness: 0.50)
    static let statusWarningMuted = Color(hue: 0.111, saturation: 0.65, brightness: 0.55)
    static let statusErrorMuted = Color(hue: 0.000, saturation: 0.60, brightness: 0.55)
    static let statusProcessingMuted = Color(hue: 0.556, saturation: 0.50, brightness: 0.50)
}
