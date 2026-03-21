import SwiftUI

// MARK: - Premium Card

@available(macOS 26.0, *)
struct PremiumCard<Content: View>: View {
    @ViewBuilder let content: Content
    var accentColor: Color = .terracotta
    var enableHover: Bool = true

    @State private var isHovered = false

    var body: some View {
        content
            .padding(Spacing.lg)
            .background(Color.warmCream)
            .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.lg)
                    .strokeBorder(accentColor.opacity(isHovered ? 0.25 : 0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(isHovered ? 0.1 : 0.05), radius: isHovered ? 20 : 12, x: 0, y: isHovered ? 8 : 4)
            .scaleEffect(enableHover && isHovered ? 1.02 : 1.0)
            .animation(.smooth, value: isHovered)
            .onHover { hovering in
                if enableHover { isHovered = hovering }
            }
    }
}
