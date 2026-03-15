import SwiftUI

// MARK: - Aurora Processing View
/// Enhanced processing view with progress-based aurora intensity
/// Always expanded (200x44) - no collapse for processing since users want to see status
/// Progress shown through brightness and animation speed, not color changes

@available(macOS 26.0, *)
struct AuroraProcessingView: View {
    let status: DisplayStatus

    @Environment(\.accessibilityReduceMotion) var reduceMotion

    // Celebration bloom effect
    @State private var showCelebrationBloom = true

    // Warning state tracking
    @State private var stepStartTime: Date = Date()
    @State private var stepElapsedTime: TimeInterval = 0

    // Fixed expanded dimensions (no collapse for processing - users want to see status)
    private let width: CGFloat = 200
    private let height: CGFloat = 44

    var body: some View {
        ZStack {
            // Aurora background with progress-based intensity
            auroraBackground
                .clipShape(Capsule())
                .brightness(showCelebrationBloom ? 0.3 : 0)  // Celebration flash

            // Always show expanded content (no collapse for processing)
            expandedContent
        }
        .frame(width: width, height: height)
        .onAppear {
            // Celebration bloom animation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                withAnimation(.easeOut(duration: 0.2)) {
                    showCelebrationBloom = false
                }
            }

            // Reset step timer on appear
            stepStartTime = Date()
            stepElapsedTime = 0
        }
        .onReceive(Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()) { _ in
            stepElapsedTime = Date().timeIntervalSince(stepStartTime)
        }
        .onChange(of: status) { _, _ in
            // Reset step timer when status changes
            stepStartTime = Date()
            stepElapsedTime = 0
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Processing: \(status.statusText)")
    }

    // MARK: - Progress-Based Aurora Properties

    /// Aurora opacity based on progress phase (dim → normal → bright)
    private var auroraOpacity: Double {
        let progress = status.progress
        if progress < 0.15 { return 0.45 }       // Getting ready: dim
        else if progress < 0.75 { return 0.60 }  // Transcribing: normal
        else { return 0.75 }                      // Finding items/finishing: bright
    }

    /// Aurora animation speed based on progress phase (slow → medium → fast)
    private var auroraPulseSpeed: Double {
        let progress = status.progress
        if reduceMotion { return 0 }
        if progress < 0.15 { return 0.03 }       // 4s cycle (slow breathe)
        else if progress < 0.75 { return 0.08 }  // 2s cycle (steady pulse)
        else { return 0.15 }                      // 1s cycle (active pulse)
    }

    /// Warning text for long-running steps
    private var warningText: String? {
        if stepElapsedTime > 120 {
            return "Taking longer than usual. Hang tight."
        } else if stepElapsedTime > 90 {
            return "Still working on this one..."
        }
        return nil
    }

    // MARK: - Content

    private var expandedContent: some View {
        VStack(spacing: 2) {
            Text(status.statusText)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.panelTextPrimary)
                .lineLimit(1)

            // Warning text (if applicable)
            if let warning = warningText {
                Text(warning)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundColor(.statusWarningMuted)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Aurora Background

    private var auroraBackground: some View {
        ZStack {
            // Base dark background
            Color.panelCharcoal

            // CORAL FOG: Warm tones, biased LEFT
            fogLayer(
                color: Color.auroraCoral,
                secondaryColor: Color.auroraCoralLight,
                blurRadius: 8,
                opacity: auroraOpacity,
                orbCount: 2,
                phaseOffset: 0,
                positionBias: -0.8
            )
            .blendMode(.plusLighter)

            // TEAL FOG: Cool tones, biased RIGHT
            fogLayer(
                color: Color.auroraTeal,
                secondaryColor: Color.auroraTealLight,
                blurRadius: 8,
                opacity: auroraOpacity * 0.9,
                orbCount: 2,
                phaseOffset: .pi / 3,
                positionBias: 0.8
            )
            .blendMode(.plusLighter)
        }
        .overlay(
            // Subtle capsule border
            Capsule()
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.auroraCoral.opacity(0.25),
                            Color.auroraTeal.opacity(0.25)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    lineWidth: 1
                )
        )
        // Subtle outer glow
        .shadow(color: Color.auroraCoral.opacity(0.15), radius: 12, x: -3, y: 0)
        .shadow(color: Color.auroraTeal.opacity(0.12), radius: 12, x: 3, y: 0)
    }

    // MARK: - Fog Layer

    private func fogLayer(
        color: Color,
        secondaryColor: Color,
        blurRadius: CGFloat,
        opacity: Double,
        orbCount: Int,
        phaseOffset: Double,
        positionBias: CGFloat
    ) -> some View {
        TimelineView(.animation(minimumInterval: 1/30)) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate

                drawFogOrbs(
                    context: &context,
                    size: size,
                    time: time,
                    color: color,
                    secondaryColor: secondaryColor,
                    orbCount: orbCount,
                    phaseOffset: phaseOffset,
                    opacity: opacity,
                    positionBias: positionBias
                )
            }
        }
        .blur(radius: blurRadius)
    }

    // MARK: - Pseudo-noise Function

    private func pseudoNoise(time: Double, phase: Double, seed: Double) -> Double {
        let t = time + seed
        let p = phase

        let wave1 = sin(t * 1.0 + p)
        let wave2 = sin(t * 1.7 + p * 2.3) * 0.5
        let wave3 = sin(t * 0.3 + p * 0.7) * 0.3
        let wave4 = sin(t * 2.3 + p * 1.1) * 0.2

        return (wave1 + wave2 + wave3 + wave4) / 2.0
    }

    // MARK: - Draw Fog Orbs

    private func drawFogOrbs(
        context: inout GraphicsContext,
        size: CGSize,
        time: Double,
        color: Color,
        secondaryColor: Color,
        orbCount: Int,
        phaseOffset: Double,
        opacity: Double,
        positionBias: CGFloat
    ) {
        let width = size.width
        let height = size.height
        let centerY = height / 2

        // Progress-based animation speed
        let slowTime = time * auroraPulseSpeed

        // Fixed intensity boost (no audio reactivity in processing)
        let fixedBoost = 0.55

        let biasOffset = positionBias * width * 0.15

        for i in 0..<orbCount {
            let orbPhase = Double(i) * (.pi * 2 / Double(orbCount)) + phaseOffset

            // Organic movement using pseudo-noise
            let xNoise = pseudoNoise(time: slowTime, phase: orbPhase, seed: 0)
            let yNoise = pseudoNoise(time: slowTime * 0.8, phase: orbPhase * 1.3, seed: 100)

            let xOffset = xNoise * (width * 0.18)
            let yOffset = yNoise * (height * 0.15)

            let orbCenterX = width / 2 + biasOffset + xOffset
            let orbCenterY = centerY + yOffset

            // Subtle breathing
            let breatheNoise = pseudoNoise(time: slowTime * 0.4, phase: orbPhase, seed: 200)
            let breathe = 1.0 + breatheNoise * 0.08
            let baseSize = max(width, height) * 0.8
            let orbSize = baseSize * fixedBoost * breathe

            let orbRect = CGRect(
                x: orbCenterX - orbSize / 2,
                y: orbCenterY - orbSize / 2,
                width: orbSize,
                height: orbSize
            )

            let gradient = Gradient(stops: [
                .init(color: color.opacity(opacity * fixedBoost), location: 0),
                .init(color: secondaryColor.opacity(opacity * 0.5), location: 0.4),
                .init(color: color.opacity(opacity * 0.25), location: 0.7),
                .init(color: Color.clear, location: 1.0)
            ])

            context.fill(
                Path(ellipseIn: orbRect),
                with: .radialGradient(
                    gradient,
                    center: CGPoint(x: orbCenterX, y: orbCenterY),
                    startRadius: 0,
                    endRadius: orbSize / 2
                )
            )
        }
    }

}

// MARK: - Preview

#if DEBUG
@available(macOS 26.0, *)
struct AuroraProcessingView_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Color.black
            VStack(spacing: 20) {
                AuroraProcessingView(status: .gettingReady)
                AuroraProcessingView(status: .transcribing(progress: 0.45))
                AuroraProcessingView(status: .finishing)
            }
        }
        .frame(width: 400, height: 400)
    }
}
#endif
