import SwiftUI

// MARK: - Benefit Card

@available(macOS 26.0, *)
struct BenefitCard: View {
    let icon: String
    let iconColor: Color
    let title: String
    let description: String

    @State private var isHovered = false
    @State private var glowOpacity: Double = 0

    var body: some View {
        HStack(spacing: Spacing.lg) {
            ZStack {
                Circle().fill(iconColor.opacity(0.2)).frame(width: 64, height: 64).blur(radius: 16).opacity(glowOpacity)
                Circle().fill(iconColor.opacity(0.12)).frame(width: 56, height: 56)
                Image(systemName: icon).font(.system(size: 24, weight: .medium)).foregroundColor(iconColor).symbolEffect(.bounce, value: isHovered)
            }
            .animation(.smooth, value: isHovered)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(title).font(.headingMedium).foregroundColor(.charcoal)
                Text(description).font(.bodyMedium).foregroundColor(.softCharcoal).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(Spacing.lg)
        .background(ZStack { Color.warmCream; LinearGradient(colors: [iconColor.opacity(isHovered ? 0.06 : 0), Color.clear], startPoint: .topLeading, endPoint: .bottomTrailing) })
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
        .overlay(RoundedRectangle(cornerRadius: Radius.lg).strokeBorder(iconColor.opacity(isHovered ? 0.25 : 0.1), lineWidth: 1))
        .shadow(color: iconColor.opacity(isHovered ? 0.15 : 0.05), radius: isHovered ? 16 : 8, x: 0, y: isHovered ? 6 : 2)
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.smooth, value: isHovered)
        .onHover { hovering in
            isHovered = hovering
            withAnimation(.smooth) { glowOpacity = hovering ? 1 : 0 }
        }
    }
}
