import SwiftUI

/// Individual stat card for the dashboard - "Metric Panel" design
/// Premium glass slab effect with animated underscore and icon glow
@available(macOS 14.0, *)
struct StatsCardView: View {

    let icon: String
    let value: String
    let label: String
    let accentColor: Color
    let trend: [CGFloat]?  // Optional 7-day trend data (0.0-1.0 normalized)

    @State private var isHovered = false

    init(
        icon: String,
        value: String,
        label: String,
        accentColor: Color = .recordingCoral,
        trend: [CGFloat]? = nil
    ) {
        self.icon = icon
        self.value = value
        self.label = label
        self.accentColor = accentColor
        self.trend = trend
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            // Icon with glow effect
            ZStack {
                // Glow circle behind icon
                Circle()
                    .fill(accentColor.opacity(0.15))
                    .frame(width: 32, height: 32)
                    .blur(radius: 8)

                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.panelTextSecondary)
            }

            Spacer()

            // Value with animated underscore
            VStack(alignment: .leading, spacing: 4) {
                Text(value)
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .foregroundColor(.panelTextPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .tracking(-1)

                // Animated underscore
                Rectangle()
                    .fill(accentColor)
                    .frame(height: 2)
                    .scaleEffect(x: isHovered ? 1.0 : 0.3, anchor: .leading)
                    .opacity(isHovered ? 1.0 : 0.5)
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isHovered)
            }

            // Label with optional sparkline
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundColor(.panelTextMuted)

                Spacer()

                // Mini sparkline (if trend data provided)
                if let trend = trend, !trend.isEmpty {
                    SparklineView(data: trend, color: accentColor)
                        .frame(width: 40, height: 16)
                }
            }
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 140)
        .premiumCard(isHovered: isHovered, glowColor: accentColor)
        .onHover { hovering in
            isHovered = hovering
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}

// MARK: - Sparkline View

/// Mini sparkline chart for showing 7-day trends
@available(macOS 14.0, *)
struct SparklineView: View {
    let data: [CGFloat]
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let stepX = width / CGFloat(max(data.count - 1, 1))

            Path { path in
                guard !data.isEmpty else { return }

                let normalizedData = normalizeData(data)

                for (index, value) in normalizedData.enumerated() {
                    let x = CGFloat(index) * stepX
                    let y = height - (value * height)

                    if index == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
            }
            .stroke(
                color.opacity(0.6),
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
            )
        }
    }

    private func normalizeData(_ data: [CGFloat]) -> [CGFloat] {
        guard let minVal = data.min(), let maxVal = data.max(), maxVal > minVal else {
            return data.map { _ in 0.5 }
        }
        return data.map { ($0 - minVal) / (maxVal - minVal) }
    }
}

/// Compact stats row showing multiple metrics inline
@available(macOS 14.0, *)
struct StatsRowView: View {

    let stats: [(icon: String, value: String, label: String)]

    var body: some View {
        HStack(spacing: Spacing.md) {
            ForEach(Array(stats.enumerated()), id: \.offset) { index, stat in
                StatsCardView(
                    icon: stat.icon,
                    value: stat.value,
                    label: stat.label
                )

                if index < stats.count - 1 {
                    // No explicit divider - cards have their own backgrounds
                }
            }
        }
    }
}

/// Large featured stat card (for streak) - "Achievement Emblem" design
/// Features concentric ring progress and animated fire effect
@available(macOS 14.0, *)
struct StreakCardView: View {

    let streak: Int
    let isActive: Bool

    @State private var isHovered = false
    @State private var isAnimating = false
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    // Milestone thresholds
    private var milestoneProgress: CGFloat {
        if streak >= 30 { return 1.0 }
        if streak >= 14 { return 0.75 + (CGFloat(streak - 14) / 64) }
        if streak >= 7 { return 0.5 + (CGFloat(streak - 7) / 28) }
        return CGFloat(streak) / 14
    }

    private var glowColor: Color {
        streak > 7 ? .orange : .recordingCoral
    }

    var body: some View {
        VStack(spacing: Spacing.sm) {
            // Fire emoji with glow effect and progress ring
            ZStack {
                // Outer ring (muted)
                Circle()
                    .stroke(Color.panelCharcoalSurface, lineWidth: 2)
                    .frame(width: 56, height: 56)

                // Progress ring (fills based on milestone)
                Circle()
                    .trim(from: 0, to: milestoneProgress)
                    .stroke(
                        glowColor,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round)
                    )
                    .frame(width: 56, height: 56)
                    .rotationEffect(.degrees(-90))

                // Inner glow
                if streak > 0 && isAnimating {
                    Circle()
                        .fill(glowColor.opacity(0.25))
                        .frame(width: 44, height: 44)
                        .blur(radius: 10)
                }

                // Emoji
                Text(streak > 0 ? "🔥" : "❄️")
                    .font(.system(size: 28))
                    .scaleEffect(isAnimating && !reduceMotion ? 1.08 : 1.0)
            }

            // Streak count
            Text("\(streak)")
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundColor(.panelTextPrimary)
                .tracking(-1)

            // Label
            Text(streak == 1 ? "day streak" : "day streak")
                .font(.caption)
                .foregroundColor(.panelTextMuted)
        }
        .padding(Spacing.md)
        .frame(width: 110, height: 140)
        .premiumCard(isHovered: isHovered, glowColor: glowColor)
        .onHover { hovering in
            isHovered = hovering
        }
        .onAppear {
            guard streak > 0, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                isAnimating = true
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(streak) day streak")
    }
}

// MARK: - Preview

@available(macOS 14.0, *)
#Preview {
    VStack(spacing: Spacing.lg) {
        HStack(spacing: Spacing.md) {
            StatsCardView(
                icon: "clock.fill",
                value: "14.5h",
                label: "Hours Transcribed"
            )

            StatsCardView(
                icon: "doc.text.fill",
                value: "23",
                label: "Meetings"
            )

            StatsCardView(
                icon: "checkmark.circle.fill",
                value: "47",
                label: "Action Items"
            )

            StreakCardView(streak: 12, isActive: true)
        }
    }
    .padding()
    .background(Color.panelCharcoal)
}
