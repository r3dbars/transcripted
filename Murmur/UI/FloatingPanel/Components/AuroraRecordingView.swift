import SwiftUI

// MARK: - Aurora Recording View
/// A living aurora visualization that dances with your conversation
/// Gemini-inspired: Soft, glowing fog that gently pulses with audio
/// Uses layered radial gradients with heavy blur for diffuse, smoky effect

@available(macOS 26.0, *)
struct AuroraRecordingView: View {
    @ObservedObject var audio: Audio
    let onStop: () -> Void

    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State private var isExpanded = true  // Start expanded, auto-collapse after 5s
    @State private var isStopHovered = false
    @State private var collapseTask: Task<Void, Never>?

    // Smoothed audio levels (prevents jitter)
    @State private var smoothedMicLevel: CGFloat = 0
    @State private var smoothedSystemLevel: CGFloat = 0

    // Collapsed/expanded dimensions
    private let collapsedWidth: CGFloat = 72
    private let collapsedHeight: CGFloat = 36
    private let expandedWidth: CGFloat = 200
    private let expandedHeight: CGFloat = 44

    // Animation smoothing factor (lower = smoother, slower response)
    private let smoothingFactor: CGFloat = 0.08

    var body: some View {
        ZStack {
            // Aurora background (always visible)
            auroraBackground
                .clipShape(Capsule())

            // Expanded content (timer + stop button)
            if isExpanded {
                expandedContent
                    .transition(.opacity.animation(.easeOut(duration: 0.1)))
            }
        }
        .frame(
            width: isExpanded ? expandedWidth : collapsedWidth,
            height: isExpanded ? expandedHeight : collapsedHeight
        )
        .animation(.spring(response: 0.15, dampingFraction: 0.8), value: isExpanded)
        .onHover { hovering in
            if hovering {
                // Cancel any pending collapse and expand immediately
                collapseTask?.cancel()
                collapseTask = nil
                isExpanded = true
            } else {
                // Start collapse timer when mouse leaves
                collapseTask = Task {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if !Task.isCancelled {
                        await MainActor.run {
                            isExpanded = false
                        }
                    }
                }
            }
        }
        .onAppear {
            // Auto-collapse after 5 seconds of initial display
            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await MainActor.run {
                    isExpanded = false
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Recording in progress, \(formatDurationAccessible(audio.recordingDuration))")
        .accessibilityHint("Hover to reveal controls")
    }

    // MARK: - Aurora Background (Gemini-style fog layers)

    private var auroraBackground: some View {
        ZStack {
            // Base dark background
            Color.panelCharcoal

            // MIC FOG: Coral/warm tones, biased LEFT
            fogLayer(
                color: Color.auroraCoral,
                secondaryColor: Color.auroraCoralLight,
                blurRadius: 12,
                opacity: 0.75,
                orbCount: 2,
                phaseOffset: 0,
                isMicLevel: true,
                positionBias: -0.8  // Bias left
            )
            .blendMode(.plusLighter)

            // SYSTEM FOG: Teal/cool tones, biased RIGHT
            fogLayer(
                color: Color.auroraTeal,
                secondaryColor: Color.auroraTealLight,
                blurRadius: 10,
                opacity: 0.7,
                orbCount: 2,
                phaseOffset: .pi / 3,
                isMicLevel: false,
                positionBias: 0.8  // Bias right
            )
            .blendMode(.plusLighter)
        }
        .overlay(
            // Capsule border glow matches position bias (coral left, teal right)
            Capsule()
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.auroraCoral.opacity(0.4),
                            Color.auroraTeal.opacity(0.4)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    lineWidth: 1
                )
        )
        // Outer glow shadows (coral left, teal right)
        .shadow(color: Color.auroraCoral.opacity(0.3), radius: 20, x: -5, y: 0)
        .shadow(color: Color.auroraTeal.opacity(0.25), radius: 20, x: 5, y: 0)
    }

    // MARK: - Fog Layer

    private func fogLayer(
        color: Color,
        secondaryColor: Color,
        blurRadius: CGFloat,
        opacity: Double,
        orbCount: Int,
        phaseOffset: Double,
        isMicLevel: Bool,
        positionBias: CGFloat = 0  // -1 = left, 0 = center, 1 = right
    ) -> some View {
        TimelineView(.animation(minimumInterval: 1/30)) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate

                // Update smoothed levels
                let targetMic = CGFloat(audio.audioLevelHistory.last ?? 0)
                let targetSystem = CGFloat(audio.systemAudioLevelHistory.last ?? 0)

                // Use main actor dispatch for state updates (can't mutate @State in Canvas)
                // Instead, compute smoothed values locally each frame
                let effectiveSmoothing = reduceMotion ? 0.02 : smoothingFactor
                let localSmoothedMic = smoothedMicLevel + (targetMic - smoothedMicLevel) * effectiveSmoothing
                let localSmoothedSystem = smoothedSystemLevel + (targetSystem - smoothedSystemLevel) * effectiveSmoothing

                // Select audio level based on layer type
                let audioLevel = isMicLevel ? localSmoothedMic : localSmoothedSystem

                // Draw fog orbs
                drawFogOrbs(
                    context: &context,
                    size: size,
                    time: time,
                    audioLevel: audioLevel,
                    color: color,
                    secondaryColor: secondaryColor,
                    orbCount: orbCount,
                    phaseOffset: phaseOffset,
                    opacity: opacity,
                    positionBias: positionBias
                )

                // Update state for next frame (approximate - computed in body)
                DispatchQueue.main.async {
                    smoothedMicLevel = localSmoothedMic
                    smoothedSystemLevel = localSmoothedSystem
                }
            }
        }
        .blur(radius: blurRadius)
    }

    // MARK: - Pseudo-noise Function

    /// Creates organic, non-repeating motion by layering sine waves with prime-ratio frequencies
    private func pseudoNoise(time: Double, phase: Double, seed: Double) -> Double {
        let t = time + seed
        let p = phase

        // Layer multiple sine waves with incommensurate frequencies
        let wave1 = sin(t * 1.0 + p)
        let wave2 = sin(t * 1.7 + p * 2.3) * 0.5
        let wave3 = sin(t * 0.3 + p * 0.7) * 0.3
        let wave4 = sin(t * 2.3 + p * 1.1) * 0.2

        // Sum and normalize (max amplitude ~2.0)
        return (wave1 + wave2 + wave3 + wave4) / 2.0
    }

    // MARK: - Draw Fog Orbs

    private func drawFogOrbs(
        context: inout GraphicsContext,
        size: CGSize,
        time: Double,
        audioLevel: CGFloat,
        color: Color,
        secondaryColor: Color,
        orbCount: Int,
        phaseOffset: Double,
        opacity: Double,
        positionBias: CGFloat = 0  // -1 = left, 0 = center, 1 = right
    ) {
        let width = size.width
        let height = size.height
        let centerY = height / 2

        // Slow animation speed (0.15x for calm, organic feel)
        let slowTime = reduceMotion ? 0 : time * 0.15

        // Audio reactivity affects SIZE and BRIGHTNESS, not speed
        // Base level of 0.6 ensures visibility even in silence, peaks at 1.8x with audio
        let audioBoost = 0.6 + Double(audioLevel) * 1.5  // 0.6 to 2.1x

        // Position bias shifts center point left or right
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

            // Orb size varies with audio and subtle breathing
            let breatheNoise = pseudoNoise(time: slowTime * 0.4, phase: orbPhase, seed: 200)
            let breathe = 1.0 + breatheNoise * 0.12
            let baseSize = max(width, height) * 0.8  // Larger orbs to fill the capsule
            let orbSize = baseSize * audioBoost * breathe

            // Draw radial gradient orb
            let orbRect = CGRect(
                x: orbCenterX - orbSize / 2,
                y: orbCenterY - orbSize / 2,
                width: orbSize,
                height: orbSize
            )

            // Radial gradient: color center fading to transparent
            let gradient = Gradient(stops: [
                .init(color: color.opacity(opacity * audioBoost), location: 0),
                .init(color: secondaryColor.opacity(opacity * 0.6), location: 0.4),
                .init(color: color.opacity(opacity * 0.3), location: 0.7),
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

    // MARK: - Expanded Content

    private var expandedContent: some View {
        HStack(spacing: 0) {
            // Stop button (left) - PRIMARY ACTION
            Button(action: onStop) {
                ZStack {
                    Circle()
                        .fill(isStopHovered ? Color.panelCharcoalSurface : Color.panelCharcoalElevated)
                        .frame(width: 32, height: 32)

                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.panelTextPrimary)
                        .frame(width: 12, height: 12)
                }
                .scaleEffect(isStopHovered ? 1.1 : 1.0)
            }
            .buttonStyle(PlainButtonStyle())
            .floatingTooltip("Stop")
            .onHover { hovering in
                withAnimation(.spring(response: 0.15, dampingFraction: 0.8)) {
                    isStopHovered = hovering
                }
            }
            .accessibilityLabel("Stop recording")
            .frame(width: 44)

            Spacer()

            // Timer (center)
            Text(formatDuration(audio.recordingDuration))
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundColor(.panelTextPrimary)
                .lineLimit(1)
                .fixedSize()

            Spacer()
                .frame(width: 44)
        }
        .padding(.horizontal, 8)
    }

    // MARK: - Helpers

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func formatDurationAccessible(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        if minutes > 0 {
            return "\(minutes) minute\(minutes == 1 ? "" : "s") \(seconds) second\(seconds == 1 ? "" : "s")"
        }
        return "\(seconds) second\(seconds == 1 ? "" : "s")"
    }
}

// MARK: - Aurora Dimensions

struct AuroraDimensions {
    /// Collapsed width - pure aurora
    static let collapsedWidth: CGFloat = 72

    /// Collapsed height
    static let collapsedHeight: CGFloat = 36

    /// Expanded width - aurora + timer + stop
    static let expandedWidth: CGFloat = 200

    /// Expanded height
    static let expandedHeight: CGFloat = 44
}

// MARK: - Preview

#if DEBUG
@available(macOS 26.0, *)
struct AuroraRecordingView_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Color.black
            // Note: Preview needs actual Audio instance
            // AuroraRecordingView(audio: Audio(), onStop: {})
            Text("Preview requires Audio instance")
                .foregroundColor(.white)
        }
        .frame(width: 300, height: 200)
    }
}
#endif
