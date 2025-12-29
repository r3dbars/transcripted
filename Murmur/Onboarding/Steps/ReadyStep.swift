import SwiftUI

/// Ready step - The confidence-building final moment
/// Celebrates completion and builds excitement for the first recording
/// Aesthetic: Warm, triumphant, reassuring - "You've got this!"
@available(macOS 26.0, *)
struct ReadyStep: View {
    @State private var celebrationScale: CGFloat = 0.6
    @State private var celebrationOpacity: Double = 0
    @State private var celebrationRotation: Double = -15
    @State private var glowPulse: Bool = false
    @State private var titleOpacity: Double = 0
    @State private var titleOffset: CGFloat = 15
    @State private var tipsAppeared: Set<Int> = []
    @State private var footerOpacity: Double = 0

    private let quickTips: [(icon: String, text: String, color: Color)] = [
        ("menubar.rectangle", "Find Transcripted in your menu bar", .terracotta),
        ("record.circle", "Click the red button to start capturing", .recordingRed),
        ("keyboard", "Pro tip: Use ⌃⇧R for instant recording", .processingPurple),
        ("sparkles", "AI extracts insights when you stop", .successGreen)
    ]

    var body: some View {
        VStack(spacing: Spacing.lg) {
            Spacer()

            // Celebration badge
            ZStack {
                // Outer glow - pulsing
                Circle()
                    .fill(Color.successGreen.opacity(0.15))
                    .frame(width: 160, height: 160)
                    .blur(radius: 30)
                    .scaleEffect(glowPulse ? 1.2 : 1.0)

                // Inner glow
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.successGreen.opacity(0.3), Color.clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: 60
                        )
                    )
                    .frame(width: 120, height: 120)

                // Checkmark with badge
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.successGreen, Color.successGreen.opacity(0.85)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 88, height: 88)
                        .shadow(color: Color.successGreen.opacity(0.3), radius: 16, y: 4)

                    Image(systemName: "checkmark")
                        .font(.system(size: 44, weight: .bold))
                        .foregroundColor(.white)
                }
            }
            .scaleEffect(celebrationScale)
            .opacity(celebrationOpacity)
            .rotationEffect(.degrees(celebrationRotation))

            // Title section
            VStack(spacing: Spacing.sm) {
                Text("You're Ready!")
                    .font(.displayLarge)
                    .foregroundColor(.charcoal)

                Text("Your next meeting will never be the same")
                    .font(.bodyLarge)
                    .foregroundColor(.softCharcoal)
            }
            .opacity(titleOpacity)
            .offset(y: titleOffset)

            // Quick start guide
            VStack(spacing: Spacing.md) {
                Text("QUICK START GUIDE")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.softCharcoal)
                    .tracking(1.5)

                VStack(spacing: Spacing.sm) {
                    ForEach(Array(quickTips.enumerated()), id: \.offset) { index, tip in
                        QuickStartTip(
                            number: index + 1,
                            icon: tip.icon,
                            text: tip.text,
                            color: tip.color
                        )
                        .opacity(tipsAppeared.contains(index) ? 1 : 0)
                        .offset(x: tipsAppeared.contains(index) ? 0 : -30)
                    }
                }
            }
            .padding(Spacing.lg)
            .background(
                RoundedRectangle(cornerRadius: Radius.lg)
                    .fill(Color.warmCream)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.lg)
                    .strokeBorder(Color.terracotta.opacity(0.15), lineWidth: 1)
            )
            .padding(.horizontal, Spacing.xxl)

            Spacer()

            // Menu bar hint with animated indicator
            MenuBarHint()
                .opacity(footerOpacity)
                .padding(.bottom, Spacing.lg)
        }
        .onAppear {
            animateIn()
        }
    }

    private func animateIn() {
        // Celebration badge entrance with bounce
        withAnimation(.bouncy.delay(0.1)) {
            celebrationScale = 1.0
            celebrationOpacity = 1.0
            celebrationRotation = 0
        }

        // Start glow pulsing
        withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true).delay(0.5)) {
            glowPulse = true
        }

        // Title fade up
        withAnimation(.smooth.delay(0.3)) {
            titleOpacity = 1.0
            titleOffset = 0
        }

        // Staggered tips
        for i in 0..<quickTips.count {
            withAnimation(.smooth.delay(Double(i) * 0.1 + 0.5)) {
                tipsAppeared.insert(i)
            }
        }

        // Footer fade in
        withAnimation(.easeOut(duration: 0.4).delay(1.0)) {
            footerOpacity = 1.0
        }
    }
}

// MARK: - Quick Start Tip

@available(macOS 26.0, *)
private struct QuickStartTip: View {
    let number: Int
    let icon: String
    let text: String
    let color: Color

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: Spacing.md) {
            // Number badge
            ZStack {
                Circle()
                    .fill(color.opacity(0.12))
                    .frame(width: 32, height: 32)

                Text("\(number)")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(color)
            }

            // Icon
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(color)
                .frame(width: 24)

            // Text
            Text(text)
                .font(.bodyMedium)
                .foregroundColor(.charcoal)

            Spacer()
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.ms)
        .background(
            RoundedRectangle(cornerRadius: Radius.md)
                .fill(isHovered ? color.opacity(0.06) : Color.clear)
        )
        .animation(.smooth, value: isHovered)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Menu Bar Hint

@available(macOS 26.0, *)
private struct MenuBarHint: View {
    @State private var arrowBounce: Bool = false

    var body: some View {
        HStack(spacing: Spacing.sm) {
            // Animated arrow pointing up
            Image(systemName: "arrow.up")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.terracotta)
                .offset(y: arrowBounce ? -3 : 0)

            Text("Look for")
                .font(.bodySmall)
                .foregroundColor(.softCharcoal)

            // Menu bar icon preview
            HStack(spacing: Spacing.xs) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.terracotta)

                Text("in your menu bar")
                    .font(.bodySmall)
                    .fontWeight(.medium)
                    .foregroundColor(.terracotta)
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(
                Capsule()
                    .fill(Color.terracotta.opacity(0.1))
            )

            // Animated arrow pointing up
            Image(systemName: "arrow.up")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.terracotta)
                .offset(y: arrowBounce ? -3 : 0)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                arrowBounce = true
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
@available(macOS 26.0, *)
#Preview {
    ReadyStep()
        .frame(width: 720, height: 680)
        .background(Color.cream)
}
#endif
