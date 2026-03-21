import SwiftUI

// MARK: - Gradient Presets

extension LinearGradient {
    static let warmGlow = LinearGradient(
        colors: [Color.terracotta.opacity(0.08), Color.cream],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let centerWarmth = LinearGradient(
        colors: [Color.terracotta.opacity(0.05), Color.clear],
        startPoint: .center,
        endPoint: .bottom
    )

    static let buttonHighlight = LinearGradient(
        colors: [Color.white.opacity(0.15), Color.clear],
        startPoint: .top,
        endPoint: .bottom
    )

    static let aiGradient = LinearGradient(
        colors: [Color.processingPurple, Color.terracotta],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

extension RadialGradient {
    static let iconGlow = RadialGradient(
        colors: [Color.terracotta.opacity(0.3), Color.clear],
        center: .center,
        startRadius: 0,
        endRadius: 60
    )
}
