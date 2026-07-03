import AppKit
import SwiftUI

enum TimelineTokens {
    static let canvasPixelsPerHour: CGFloat = 60
    static let cardCornerRadius: CGFloat = 8
    static let panelCornerRadius: CGFloat = 8
    static let hairline = Color.primary.opacity(0.09)
    static let quietStroke = Color.primary.opacity(0.12)
    static let softFill = Color(nsColor: .controlBackgroundColor).opacity(0.72)
    static let insetFill = Color.primary.opacity(0.035)
    static let selectedFill = Color.accentColor.opacity(0.12)

    static func color(for category: TimelineCategory) -> Color {
        switch category {
        case .work:
            return Color(red: 0.73, green: 0.52, blue: 0.98)
        case .meetings:
            return Color(red: 0.22, green: 0.76, blue: 0.72)
        case .personal:
            return Color(red: 0.42, green: 0.68, blue: 1.0)
        case .distraction:
            return Color(red: 1.0, green: 0.35, blue: 0.31)
        case .idle:
            return Color(red: 0.63, green: 0.67, blue: 0.72)
        }
    }

    static func categoryLabel(_ category: TimelineCategory) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color(for: category))
                .frame(width: 6, height: 6)
            Text(category.rawValue)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
    }
}
