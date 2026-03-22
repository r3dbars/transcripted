import SwiftUI

// MARK: - Aurora Recording View
/// Clean recording pill with two audio-reactive VU dots.
/// Coral dot (left of timer) = mic level. Teal dot (right of timer) = system audio level.
/// Dots scale and brighten with audio. Plain dark border, no bloom effects.

@available(macOS 26.0, *)
struct AuroraRecordingView: View {
    @ObservedObject var audio: Audio
    let onStop: () -> Void
    var onTranscripts: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State private var isStopHovered = false
    @State private var isTranscriptsHovered = false
    @State private var smoothedMicLevel: CGFloat = 0
    @State private var smoothedSystemLevel: CGFloat = 0

    private let width: CGFloat = PillDimensions.recordingWidth
    private let height: CGFloat = PillDimensions.recordingHeight

    // Sharp VU meter response: near-instant attack, quick decay
    private let attackFactor: CGFloat = 0.55
    private let decayFactor: CGFloat = 0.15

    var body: some View {
        ZStack {
            // Dark capsule background
            Capsule()
                .fill(Color.panelCharcoal)

            // Plain dim border
            Capsule()
                .strokeBorder(Color.panelCharcoalSurface, lineWidth: 1)

            // Content: stop button + mic dot + timer + system dot
            recordingContent
        }
        .frame(width: width, height: height)
        .onChange(of: audio.audioLevel) { _, _ in updateLevels() }
        .onChange(of: audio.systemAudioLevelHistory) { _, _ in updateLevels() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Recording in progress, \(formatDurationAccessible(audio.recordingDuration))")
        .accessibilityHint("Click stop to end recording")
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
        HStack(spacing: 2) {
            // Stop button (left)
            Button(action: onStop) {
                ZStack {
                    Circle()
                        .fill(isStopHovered ? Color.panelCharcoalSurface : Color.panelCharcoalElevated)
                        .frame(width: 26, height: 26)
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(Color.panelTextPrimary)
                        .frame(width: 9, height: 9)
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

            // Mic LED (coral)
            ledDot(level: smoothedMicLevel, color: .recordingCoral)
                .accessibilityLabel("Microphone level")

            // Timer (centered)
            Text(formatDuration(audio.recordingDuration))
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundColor(.panelTextPrimary)
                .lineLimit(1)
                .fixedSize()

            // System LED (teal)
            ledDot(level: smoothedSystemLevel, color: .auroraTeal)
                .accessibilityLabel("System audio level")

            // Transcripts button (right)
            if let onTranscripts {
                Button(action: onTranscripts) {
                    ZStack {
                        Circle()
                            .fill(isTranscriptsHovered ? Color.panelCharcoalSurface : Color.panelCharcoalElevated)
                            .frame(width: 26, height: 26)
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.panelTextPrimary)
                    }
                    .scaleEffect(isTranscriptsHovered ? 1.1 : 1.0)
                }
                .buttonStyle(PlainButtonStyle())
                .floatingTooltip("Transcripts")
                .onHover { hovering in
                    withAnimation(.spring(response: 0.15, dampingFraction: 0.8)) {
                        isTranscriptsHovered = hovering
                    }
                }
                .accessibilityLabel("Browse transcripts")
            }
        }
        .padding(.horizontal, 6)
    }

    // MARK: - LED Dot (point light source)

    /// Glowing LED indicator — bright core with radial falloff halo.
    /// No hard circle edge, just light concentration that grows/dims with audio.
    private func ledDot(level: CGFloat, color: Color) -> some View {
        let boosted = Swift.min(level * 1.6, 1.0)
        let coreOpacity = 0.4 + Double(boosted) * 0.6         // 40% → 100%
        let haloOpacity = 0.08 + Double(boosted) * 0.25        // 8% → 33%
        let haloSize = 8 + boosted * 14                         // 8px → 22px diameter (11px max radius)
        let coreSize: CGFloat = 3 + boosted * 1.5               // 3px → 4.5px

        return ZStack {
            // Outer halo — soft radial falloff
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            color.opacity(haloOpacity),
                            color.opacity(haloOpacity * 0.3),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: haloSize / 2
                    )
                )
                .frame(width: haloSize, height: haloSize)

            // Bright core
            Circle()
                .fill(color.opacity(coreOpacity))
                .frame(width: coreSize, height: coreSize)
                .blur(radius: 0.5)
        }
        .frame(width: 22, height: 22) // fixed hit area
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
