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
        HStack(spacing: 0) {
            // Stop button (left)
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
            .frame(width: 36)

            Spacer()

            // Mic VU dot (coral)
            vuDot(level: smoothedMicLevel, color: .recordingCoral)
                .accessibilityLabel("Microphone level")

            // Timer (centered)
            Text(formatDuration(audio.recordingDuration))
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
                .foregroundColor(.panelTextPrimary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 10)

            // System VU dot (teal)
            vuDot(level: smoothedSystemLevel, color: .auroraTeal)
                .accessibilityLabel("System audio level")

            Spacer()
                .frame(width: 36)
        }
        .padding(.horizontal, 8)
    }

    // MARK: - VU Dot

    private func vuDot(level: CGFloat, color: Color) -> some View {
        let dotScale = 0.6 + level * 0.9         // 0.6x → 1.5x
        let dotOpacity = 0.3 + Double(level) * 0.7  // 30% → 100%
        let glowRadius = 2 + level * 6             // subtle glow

        return Circle()
            .fill(color.opacity(dotOpacity))
            .frame(width: 6, height: 6)
            .scaleEffect(reduceMotion ? 1.0 : dotScale)
            .shadow(color: color.opacity(dotOpacity * 0.6), radius: glowRadius)
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
