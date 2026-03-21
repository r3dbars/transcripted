import SwiftUI

// MARK: - Card View Modifiers

extension View {
    /// Apply minimal card styling — dark container with subtle border
    func lawsCard(isHovered: Bool = false) -> some View {
        self
            .background(Color.panelCharcoalElevated)
            .clipShape(RoundedRectangle(cornerRadius: Radius.lawsCard, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.lawsCard, style: .continuous)
                    .stroke(Color.panelCharcoalSurface, lineWidth: 1)
            )
    }
}

// MARK: - Premium Card View Modifier

@available(macOS 14.0, *)
struct PremiumCardModifier: ViewModifier {
    let isHovered: Bool
    let glowColor: Color
    let cornerRadius: CGFloat

    init(isHovered: Bool, glowColor: Color = .recordingCoral, cornerRadius: CGFloat = Radius.lawsCard) {
        self.isHovered = isHovered
        self.glowColor = glowColor
        self.cornerRadius = cornerRadius
    }

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.panelCharcoalElevated)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.panelCharcoalSurface, lineWidth: 1)
            }
    }
}

@available(macOS 14.0, *)
extension View {
    func premiumCard(isHovered: Bool, glowColor: Color = .recordingCoral, cornerRadius: CGFloat = Radius.lawsCard) -> some View {
        modifier(PremiumCardModifier(isHovered: isHovered, glowColor: glowColor, cornerRadius: cornerRadius))
    }
}
