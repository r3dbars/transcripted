import SwiftUI

// MARK: - Quick Tip Row

@available(macOS 26.0, *)
struct QuickTipRow: View {
    let icon: String
    let text: String
    var iconColor: Color = .terracotta

    var body: some View {
        HStack(spacing: Spacing.ms) {
            Image(systemName: icon).font(.system(size: 14, weight: .medium)).foregroundColor(iconColor).frame(width: 24)
            Text(text).font(.bodyMedium).foregroundColor(.charcoal)
            Spacer()
        }
        .padding(.vertical, Spacing.sm)
    }
}
