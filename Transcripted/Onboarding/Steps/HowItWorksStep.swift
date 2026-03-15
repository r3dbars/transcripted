import SwiftUI

/// How It Works step - Rich 4-phase animation showing the workflow
/// Phase 3 features the signature PARTICLE EXPLOSION animation
/// mic → transcript → AI analysis (explosion) → organized insights
@available(macOS 26.0, *)
struct HowItWorksStep: View {
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State private var phase: Int = 0
    @State private var titleOpacity: Double = 0
    @State private var autoAdvance: Bool = false  // Manual by default — user taps phase dots

    // Timer for auto-advancing phases (only active when autoAdvance is true)
    private let timer = Timer.publish(every: 3.0, on: .main, in: .common).autoconnect()

    private let phases: [(caption: String, icon: String, color: Color)] = [
        ("Recording your conversation...", "mic.fill", .recordingRed),
        ("Transcribing speech to text...", "text.quote", .terracotta),
        ("Identifying speakers...", "person.2.fill", .processingPurple),
        ("Transcript ready!", "doc.text.fill", .successGreen)
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
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.95)))
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
            withAnimation(reduceMotion ? .none : .easeOut(duration: 0.3)) {
                titleOpacity = 1.0
            }
        }
        .onReceive(timer) { _ in
            guard autoAdvance, !reduceMotion else { return }
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
            IdentifyingSpeakersPhaseView()
        default:
            TranscriptReadyPhaseView()
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
        "\"Great, let's go through the project update...\"",
        "\"The new design is looking really solid...\"",
        "\"I agree, let's finalize the timeline tomorrow.\""
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

// MARK: - Identifying Speakers Phase

@available(macOS 26.0, *)
private struct IdentifyingSpeakersPhaseView: View {
    @State private var avatarsVisible: Int = 0
    @State private var connectionsVisible: Bool = false
    @State private var labelsVisible: Int = 0

    private let speakers: [(label: String, color: Color, xOffset: CGFloat, yOffset: CGFloat)] = [
        ("Speaker 1", .terracotta, -50, -20),
        ("Speaker 2", .processingPurple, 50, -20),
        ("Speaker 3", .successGreen, 0, 40)
    ]

    var body: some View {
        ZStack {
            // Connection lines between speakers
            if connectionsVisible {
                Path { path in
                    path.move(to: CGPoint(x: 310, y: 120))
                    path.addLine(to: CGPoint(x: 410, y: 120))
                    path.move(to: CGPoint(x: 310, y: 120))
                    path.addLine(to: CGPoint(x: 360, y: 180))
                    path.move(to: CGPoint(x: 410, y: 120))
                    path.addLine(to: CGPoint(x: 360, y: 180))
                }
                .stroke(Color.processingPurple.opacity(0.3), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                .transition(.opacity)
            }

            // Speaker avatars with labels
            ForEach(0..<speakers.count, id: \.self) { index in
                VStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .fill(speakers[index].color.opacity(0.15))
                            .frame(width: 52, height: 52)

                        Image(systemName: "person.fill")
                            .font(.system(size: 24))
                            .foregroundColor(speakers[index].color)
                    }

                    if index < labelsVisible {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(speakers[index].color)
                                .frame(width: 6, height: 6)
                            Text(speakers[index].label)
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(.charcoal)
                        }
                        .transition(.opacity.combined(with: .offset(y: 4)))
                    }
                }
                .offset(x: speakers[index].xOffset, y: speakers[index].yOffset)
                .scaleEffect(index < avatarsVisible ? 1.0 : 0.5)
                .opacity(index < avatarsVisible ? 1.0 : 0.0)
            }
        }
        .onAppear {
            // Stagger avatar appearances
            for i in 0..<speakers.count {
                withAnimation(.bouncy.delay(Double(i) * 0.25)) {
                    avatarsVisible = i + 1
                }
            }
            // Show connections after avatars
            withAnimation(.easeOut(duration: 0.4).delay(0.75)) {
                connectionsVisible = true
            }
            // Stagger label appearances
            for i in 0..<speakers.count {
                withAnimation(.smooth.delay(Double(i) * 0.2 + 0.9)) {
                    labelsVisible = i + 1
                }
            }
        }
    }
}

// MARK: - Transcript Ready Phase

@available(macOS 26.0, *)
private struct TranscriptReadyPhaseView: View {
    @State private var linesVisible: Int = 0

    private let transcriptLines: [(timestamp: String, speaker: String, text: String, color: Color)] = [
        ("[00:12]", "Speaker 1", "Great, let's get started.", .terracotta),
        ("[00:18]", "Speaker 2", "Sounds good, I have the update.", .processingPurple),
        ("[00:25]", "Speaker 1", "Perfect, walk us through the changes.", .terracotta)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.ms) {
            // Mini transcript header
            HStack(spacing: Spacing.sm) {
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.successGreen)
                Text("Transcript")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.softCharcoal)
                    .tracking(1.0)
                Spacer()
            }
            .padding(.bottom, Spacing.xs)

            ForEach(0..<transcriptLines.count, id: \.self) { index in
                let line = transcriptLines[index]
                HStack(alignment: .top, spacing: Spacing.sm) {
                    Text(line.timestamp)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.softCharcoal)
                        .frame(width: 44, alignment: .leading)

                    Circle()
                        .fill(line.color)
                        .frame(width: 8, height: 8)
                        .offset(y: 4)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(line.speaker)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(line.color)
                        Text("\"\(line.text)\"")
                            .font(.transcript)
                            .foregroundColor(.charcoal)
                    }
                }
                .opacity(index < linesVisible ? 1 : 0)
                .offset(y: index < linesVisible ? 0 : 8)
            }
        }
        .padding(Spacing.xl)
        .onAppear {
            for i in 0..<transcriptLines.count {
                withAnimation(.smooth.delay(Double(i) * 0.3)) {
                    linesVisible = i + 1
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
