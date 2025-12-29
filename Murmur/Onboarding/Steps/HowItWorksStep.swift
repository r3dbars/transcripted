import SwiftUI

/// How It Works step - Rich 4-phase animation showing the workflow
/// Phase 3 features the signature PARTICLE EXPLOSION animation
/// mic → transcript → AI analysis (explosion) → organized insights
@available(macOS 26.0, *)
struct HowItWorksStep: View {
    @State private var phase: Int = 0
    @State private var titleOpacity: Double = 0
    @State private var autoAdvance: Bool = true

    // Timer for auto-advancing phases
    private let timer = Timer.publish(every: 3.0, on: .main, in: .common).autoconnect()

    private let phases: [(caption: String, icon: String, color: Color)] = [
        ("Recording your conversation...", "mic.fill", .recordingRed),
        ("Transcribing speech to text...", "text.quote", .terracotta),
        ("AI finding what matters...", "sparkles", .processingPurple),
        ("Insights ready!", "checklist", .successGreen)
    ]

    var body: some View {
        VStack(spacing: Spacing.lg) {
            // Header
            VStack(spacing: Spacing.sm) {
                Text("How Transcripted Works")
                    .font(.displayMedium)
                    .foregroundColor(.charcoal)

                Text("See the magic in action")
                    .font(.bodyLarge)
                    .foregroundColor(.softCharcoal)
            }
            .opacity(titleOpacity)
            .padding(.top, Spacing.ml)

            // Animation area
            ZStack {
                RoundedRectangle(cornerRadius: Radius.xl)
                    .fill(Color.warmCream)
                    .shadow(color: .black.opacity(0.05), radius: 16, y: 4)

                // Phase content
                animationContent
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    .id(phase)
            }
            .frame(height: 280)
            .padding(.horizontal, Spacing.xl)

            // Caption with icon
            HStack(spacing: Spacing.sm) {
                Image(systemName: phases[phase].icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(phases[phase].color)
                    .symbolEffect(.pulse, options: .repeating, isActive: phase < 3)

                Text(phases[phase].caption)
                    .font(.headingSmall)
                    .foregroundColor(.charcoal)
            }
            .animation(.smooth, value: phase)
            .id("caption-\(phase)")

            // Phase indicators
            HStack(spacing: Spacing.ms) {
                ForEach(0..<4, id: \.self) { index in
                    PhaseIndicatorDot(
                        icon: phases[index].icon,
                        color: phases[index].color,
                        isActive: index == phase,
                        isCompleted: index < phase
                    )
                    .onTapGesture {
                        withAnimation(.smooth) {
                            phase = index
                            autoAdvance = false // Stop auto-advance on tap
                        }
                    }
                }
            }

            Spacer()
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.3)) {
                titleOpacity = 1.0
            }
        }
        .onReceive(timer) { _ in
            guard autoAdvance else { return }
            withAnimation(.smooth) {
                phase = (phase + 1) % 4
            }
        }
    }

    @ViewBuilder
    private var animationContent: some View {
        switch phase {
        case 0:
            RecordingPhaseView()
        case 1:
            TranscribingPhaseView()
        case 2:
            AnalyzingPhaseView()
        default:
            InsightsPhaseView()
        }
    }
}

// MARK: - Phase Indicator Dot

@available(macOS 26.0, *)
private struct PhaseIndicatorDot: View {
    let icon: String
    let color: Color
    let isActive: Bool
    let isCompleted: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(isActive ? color : (isCompleted ? color.opacity(0.3) : Color.terracotta.opacity(0.1)))
                .frame(width: 44, height: 44)

            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(isActive ? .white : (isCompleted ? color : .softCharcoal))
        }
        .scaleEffect(isActive ? 1.15 : 1.0)
        .animation(.bouncy, value: isActive)
    }
}

// MARK: - Recording Phase

@available(macOS 26.0, *)
private struct RecordingPhaseView: View {
    @State private var ringScale: CGFloat = 1.0
    @State private var pulseOpacity: Double = 0.6

    var body: some View {
        ZStack {
            // Pulsing rings
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .stroke(Color.recordingRed.opacity(0.3 - Double(i) * 0.1), lineWidth: 2)
                    .frame(width: 80 + CGFloat(i) * 35, height: 80 + CGFloat(i) * 35)
                    .scaleEffect(ringScale)
                    .opacity(pulseOpacity - Double(i) * 0.15)
            }

            // Microphone icon
            Image(systemName: "mic.fill")
                .font(.system(size: 52))
                .foregroundColor(.recordingRed)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                ringScale = 1.2
                pulseOpacity = 0.25
            }
        }
    }
}

// MARK: - Transcribing Phase

@available(macOS 26.0, *)
private struct TranscribingPhaseView: View {
    @State private var visibleLines: Int = 0

    private let sampleLines = [
        "\"Let's follow up with the design team...\"",
        "\"I'll take the lead on competitor analysis...\"",
        "\"We're targeting March 15th for launch...\""
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.ms) {
            ForEach(0..<sampleLines.count, id: \.self) { index in
                HStack(spacing: Spacing.sm) {
                    Circle()
                        .fill(Color.terracotta)
                        .frame(width: 8, height: 8)

                    Text(sampleLines[index])
                        .font(.transcript)
                        .foregroundColor(.charcoal)
                }
                .opacity(index < visibleLines ? 1 : 0)
                .offset(y: index < visibleLines ? 0 : 10)
            }
        }
        .padding(Spacing.xl)
        .onAppear {
            for i in 0..<sampleLines.count {
                withAnimation(.smooth.delay(Double(i) * 0.4)) {
                    visibleLines = i + 1
                }
            }
        }
    }
}

// MARK: - Analyzing Phase (Simplified - Full particle in Demo)

@available(macOS 26.0, *)
private struct AnalyzingPhaseView: View {
    @State private var sparkleRotation: Double = 0
    @State private var pulseScale: CGFloat = 1.0
    @State private var glowOpacity: Double = 0.3

    var body: some View {
        ZStack {
            // Glow effect
            Circle()
                .fill(Color.processingPurple.opacity(0.2))
                .frame(width: 140, height: 140)
                .blur(radius: 25)
                .opacity(glowOpacity)

            // AI sparkle effect
            Image(systemName: "sparkles")
                .font(.system(size: 64))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.processingPurple, .terracotta],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .rotationEffect(.degrees(sparkleRotation))
                .scaleEffect(pulseScale)

            // Processing text
            Text("Analyzing...")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.softCharcoal)
                .offset(y: 65)
        }
        .onAppear {
            withAnimation(.linear(duration: 3).repeatForever(autoreverses: false)) {
                sparkleRotation = 360
            }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                pulseScale = 1.15
                glowOpacity = 0.5
            }
        }
    }
}

// MARK: - Insights Phase

@available(macOS 26.0, *)
private struct InsightsPhaseView: View {
    @State private var cardsVisible: Int = 0

    private let insights = [
        ("Follow up with design team", "Due Friday", Color.terracotta),
        ("Launch date: March 15th", "Decision made", Color.successGreen),
        ("Competitor analysis assigned", "In progress", Color.processingPurple)
    ]

    var body: some View {
        VStack(spacing: Spacing.ms) {
            ForEach(0..<insights.count, id: \.self) { index in
                HStack {
                    Circle()
                        .fill(insights[index].2)
                        .frame(width: 10, height: 10)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(insights[index].0)
                            .font(.bodyMedium)
                            .fontWeight(.medium)
                            .foregroundColor(.charcoal)

                        Text(insights[index].1)
                            .font(.caption)
                            .foregroundColor(.softCharcoal)
                    }

                    Spacer()

                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(insights[index].2)
                        .font(.system(size: 18))
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.ms)
                .background(
                    RoundedRectangle(cornerRadius: Radius.sm)
                        .fill(Color.cream)
                )
                .opacity(index < cardsVisible ? 1 : 0)
                .offset(x: index < cardsVisible ? 0 : 30)
            }
        }
        .padding(Spacing.xl)
        .onAppear {
            for i in 0..<insights.count {
                withAnimation(.bouncy.delay(Double(i) * 0.2)) {
                    cardsVisible = i + 1
                }
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
@available(macOS 26.0, *)
#Preview {
    HowItWorksStep()
        .frame(width: 720, height: 680)
        .background(Color.cream)
}
#endif
