import SwiftUI

// MARK: - Brand Colors (Terracotta, Cream, Charcoal) + Semantic Colors

extension Color {
    static let terracotta = Color(hex: "#DA7756")
    static let cream = Color(hex: "#FAF7F2")
    static let warmCream = Color(hex: "#F5F0E8")
    static let charcoal = Color(hex: "#2D2D2D")
    static let softCharcoal = Color(hex: "#5A5A5A")
    static let mutedText = Color(hex: "#8A8A8A")

    // MARK: - Semantic Colors
    static let successGreen = Color(hex: "#4A9E6B")
    static let recordingRed = Color(hex: "#D94F4F")
    static let processingPurple = Color(hex: "#7B68A8")
    static let warningAmber = Color(hex: "#D4A03D")
    static let errorCoral = Color(hex: "#E05A5A")

    // MARK: - Accent Variations
    static let terracottaLight = Color(hex: "#DA7756").opacity(0.12)
    static let terracottaHover = Color(hex: "#C4654A")
    static let terracottaPressed = Color(hex: "#B85A42")
}
