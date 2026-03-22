import SwiftUI

// MARK: - Aurora Recording View
/// Audio-reactive neon border for recording state.
/// Mic audio (coral) glows from the LEFT side, fading toward center.
/// System audio (teal) glows from the RIGHT side, fading toward center.
/// Uses masked Capsule strokes layered for bloom effect — strokes always stay on the border.

@available(macOS 26.0, *)
struct AuroraRecordingView: View {
    @ObservedObject var audio: Audio
    let onStop: () -> Void
    var onTranscripts: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State private var isStopHovered = false
    @State private var smoothedMicLevel: CGFloat = 0
    @State private var smoothedSystemLevel: CGFloat = 0

    private let width: CGFloat = PillDimensions.recordingWidth
    private let height: CGFloat = PillDimensions.recordingHeight

    private let attackFactor: CGFloat = 0.25
    private let decayFactor: CGFloat = 0.06

    var body: some View {
        ZStack {
            // Dark capsule background
            Capsule()
                .fill(Color.panelCharcoal)

            // Base dim border
            Capsule()
                .strokeBorder(Color.panelCharcoalSurface.opacity(0.5), lineWidth: 1)

            if reduceMotion {
                staticBorder
            } else {
                // Neon glow layers — padded outward so bloom doesn't clip at frame edges
                ZStack {
                    neonGlow(color: .recordingCoral, level: smoothedMicLevel, fromLeading: true)
                    neonGlow(color: .auroraTeal, level: smoothedSystemLevel, fromLeading: false)
                }
                .padding(-30)
            }

            // Content: stop button + timer
            recordingContent
        }
        .frame(width: width, height: height)
        .shadow(color: Color.recordingCoral.opacity(0.12 + Double(smoothedMicLevel) * 0.38),
                radius: 14 + smoothedMicLevel * 14, x: -3, y: 0)
        .shadow(color: Color.auroraTeal.opacity(0.10 + Double(smoothedSystemLevel) * 0.32),
                radius: 12 + smoothedSystemLevel * 12, x: 3, y: 0)
        .onChange(of: audio.audioLevel) { _, _ in updateLevels() }
        .onChange(of: audio.systemAudioLevelHistory) { _, _ in updateLevels() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Recording in progress, \(formatDurationAccessible(audio.recordingDuration))")
        .accessibilityHint("Click stop to end recording")
    }

    // MARK: - Neon Glow Layer

    /// Three layered capsule strokes masked to fade from one side, creating the apex-glow effect.
    @ViewBuilder
    private func neonGlow(color: Color, level: CGFloat, fromLeading: Bool) -> some View {
        let coverage = 0.15 + level * 0.85 // 15% base → 100% at peak

        // Pass 1: Outer bloom (wide, blurred)
        Capsule()
            .stroke(color.opacity(0.2 + Double(level) * 0.35), lineWidth: 8 + level * 8)
            .blur(radius: 10 + level * 8)
            .mask(coverageMask(coverage: coverage, fromLeading: fromLeading))

        // Pass 2: Mid glow
        Capsule()
            .stroke(color.opacity(0.4 + Double(level) * 0.35), lineWidth: 4 + level * 4)
            .blur(radius: 4 + level * 3)
            .mask(coverageMask(coverage: coverage, fromLeading: fromLeading))

        // Pass 3: Inner core (sharp, bright)
        Capsule()
            .stroke(color.opacity(0.7 + Double(level) * 0.3), lineWidth: 2 + level * 1.5)
            .mask(coverageMask(coverage: coverage, fromLeading: fromLeading))
    }

    /// Gradient mask that reveals from one side based on coverage (0→1).
    /// Creates the "crawling from apex" effect without custom paths.
    private func coverageMask(coverage: CGFloat, fromLeading: Bool) -> some View {
        LinearGradient(
            stops: [
                .init(color: .white, location: 0),
                .init(color: .white, location: coverage * 0.8),
                .init(color: .clear, location: coverage),
            ],
            startPoint: fromLeading ? .leading : .trailing,
            endPoint: fromLeading ? .trailing : .leading
        )
    }

    // MARK: - Static Border (reduce motion)

    private var staticBorder: some View {
        Capsule()
            .strokeBorder(
                LinearGradient(
                    colors: [Color.recordingCoral.opacity(0.3), Color.auroraTeal.opacity(0.3)],
                    startPoint: .leading, endPoint: .trailing
                ),
                lineWidth: 2
            )
    }

    // MARK: - Level Smoothing

    private func updateLevels() {
        let targetMic = CGFloat(audio.audioLevel)
        let targetSystem = CGFloat(audio.systemAudioLevelHistory.last ?? 0)

        let micFactor = targetMic > smoothedMicLevel ? attackFactor : decayFactor
        smoothedMicLevel += (targetMic - smoothedMicLevel) * micFactor

        let sysFactor = targetSystem > smoothedSystemLevel ? attackFactor : decayFactor
        smoothedSystemLevel += (targetSystem - smoothedSystemLevel) * sysFactor
    }

    // MARK: - Content

    private var recordingContent: some View {
        ZStack {
            Text(formatDuration(audio.recordingDuration))
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
                .foregroundColor(.panelTextPrimary)
                .lineLimit(1)
                .fixedSize()

            HStack(spacing: 0) {
                Button(action: onStop) {
                    ZStack {
                        Circle()
                            .fill(isStopHovered ? Color.panelCharcoalSurface : Color.panelCharcoalElevated)
                            .frame(width: 28, height: 28)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.panelTextPrimary)
                            .frame(width: 10, height: 10)
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
                .frame(width: 40)
                Spacer()
            }
            .padding(.horizontal, 8)
        }
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
