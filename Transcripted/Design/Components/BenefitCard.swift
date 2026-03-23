import SwiftUI

// MARK: - Benefit Card

@available(macOS 26.0, *)
struct BenefitCard: View {
    let icon: String
    let iconColor: Color
    let title: String
    let description: String

    var body: some View {
        HStack(spacing: Spacing.lg) {
            Circle()
                .fill(iconColor.opacity(0.12))
                .frame(width: 48, height: 48)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(iconColor)
                )

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(title).font(.headingSmall).foregroundColor(.panelTextPrimary)
                Text(description).font(.bodySmall).foregroundColor(.panelTextSecondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(Spacing.md)
        .background(Color.panelCharcoalElevated)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Radius.md).strokeBorder(Color.panelCharcoalSurface, lineWidth: 1))
    }
}
