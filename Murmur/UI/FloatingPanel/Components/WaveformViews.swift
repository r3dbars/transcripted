import SwiftUI

// MARK: - Edge Peek View (Laws of UX Warm Minimalism)

/// Minimal view shown when panel is docked at edge - warm cream theme
/// Shows distinctly different content based on recording state:
/// - Idle: warm cream edge with subtle grip dots
/// - Recording: pulsing red dot with compact waveform
/// - Silence warning: amber ring around recording indicator
struct EdgePeekView: View {
    let isRecording: Bool
    let audioLevels: [Float]
    let systemAudioLevels: [Float]
    let recordingDuration: TimeInterval
    var silenceWarning: Bool = false  // Amber ring when silence detected
    var onStop: () -> Void = {}

    var body: some View {
        ZStack {
            // Warm cream background with vibrancy
            RoundedRectangle(cornerRadius: Radius.lawsCard, style: .continuous)
                .fill(Color.surfaceEggshell.opacity(0.95))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.lawsCard, style: .continuous)
                        .stroke(
                            isRecording ? Color.recordingCoral.opacity(0.5) : Color.accentBlue.opacity(0.15),
                            lineWidth: isRecording ? 2 : 1
                        )
                )
                .shadow(
                    color: CardStyle.shadowSubtle.color,
                    radius: CardStyle.shadowSubtle.radius,
                    x: CardStyle.shadowSubtle.x,
                    y: CardStyle.shadowSubtle.y
                )

            if isRecording {
                VStack(spacing: 8) {
                    // Recording Indicator (Red dot, amber ring when silence warning)
                    ZStack {
                        // Amber pulsing ring when silence detected (UX: non-intrusive warning)
                        if silenceWarning {
                            Circle()
                                .stroke(Color.statusWarningMuted, lineWidth: 2)
                                .frame(width: 18, height: 18)
                                .opacity(Double(Int(Date().timeIntervalSince1970 * 1.5) % 2 == 0 ? 1.0 : 0.4))
                        }

                        Circle()
                            .fill(silenceWarning ? Color.statusWarningMuted : Color.recordingCoral)
                            .frame(width: 10, height: 10)
                            .shadow(color: (silenceWarning ? Color.statusWarningMuted : Color.recordingCoral).opacity(0.6), radius: 4)
                            .opacity(Double(Int(Date().timeIntervalSince1970 * 2) % 2 == 0 ? 1.0 : 0.5))
                    }

                    // Dual Waveform showing both mic and system audio
                    WaveformMiniView(levels: audioLevels, systemLevels: systemAudioLevels)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(.vertical, 8)
            } else {
                // Idle: Subtle grip dots (Laws of UX minimal)
                VStack(spacing: 6) {
                    ForEach(0..<8, id: \.self) { _ in
                        Circle()
                            .fill(Color.accentBlue.opacity(0.2))
                            .frame(width: 4, height: 4)
                    }
                }
            }
        }
        .frame(width: isRecording ? 60 : 28, height: 110) // Match panelHeight (110), idle 28px for discoverability
    }
}

// MARK: - Waveform Mini View (Abstract, Laws of UX style)
// Shows both mic and system audio with distinct visual styles:
// - Mic audio: Filled bars (your voice)
// - System audio: Outlined bars (what you're hearing)

struct WaveformMiniView: View {
    let levels: [Float]  // Microphone audio levels
    var systemLevels: [Float]? = nil  // Optional system audio levels
    var barCount: Int = 8
    var maxHeight: CGFloat = 40

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<barCount, id: \.self) { index in
                let micLevel = index < levels.count ? CGFloat(levels[index]) : 0
                let sysLevel = systemLevels.map { index < $0.count ? CGFloat($0[index]) : 0 } ?? 0

                ZStack(alignment: .bottom) {
                    // System audio: Outlined bar (behind mic bar)
                    if let _ = systemLevels, sysLevel > 0.05 {
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(colorForSystemLevel(sysLevel), lineWidth: 1.5)
                            .frame(width: 4, height: max(4, sysLevel * maxHeight))
                    }

                    // Mic audio: Filled bar (foreground)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(colorForMicLevel(micLevel))
                        .frame(width: 4, height: max(4, micLevel * maxHeight))
                }
                .frame(height: maxHeight, alignment: .bottom)
            }
        }
    }

    /// Color for microphone audio (your voice) - warm tones
    private func colorForMicLevel(_ level: CGFloat) -> Color {
        if level > 0.75 {
            return Color.recordingCoral
        } else if level > 0.5 {
            return Color.statusWarningMuted
        } else if level > 0.1 {
            return Color.accentBlue.opacity(0.7)
        } else {
            return Color.accentBlue.opacity(0.3)
        }
    }

    /// Color for system audio (what you're hearing) - cool tones to differentiate
    private func colorForSystemLevel(_ level: CGFloat) -> Color {
        if level > 0.75 {
            return Color.purple.opacity(0.8)
        } else if level > 0.5 {
            return Color.purple.opacity(0.6)
        } else {
            return Color.purple.opacity(0.4)
        }
    }
}

// MARK: - Dormant Waveform View (Idle state - subtle breathing animation)

/// 8 flat bars that subtly "breathe" using sine wave animation
/// Terracotta color at 60% opacity, 2px bar width, 2px spacing
@available(macOS 14.0, *)
struct DormantWaveformView: View {
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State private var phase: Double = 0

    private let barCount = 8
    private let barWidth: CGFloat = 2
    private let barSpacing: CGFloat = 2
    private let minHeight: CGFloat = 3
    private let maxHeight: CGFloat = 8

    var body: some View {
        HStack(spacing: barSpacing) {
            ForEach(0..<barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.terracotta.opacity(0.6))
                    .frame(width: barWidth, height: barHeight(for: index))
            }
        }
        .onAppear {
            if !reduceMotion {
                startBreathing()
            }
        }
    }

    private func barHeight(for index: Int) -> CGFloat {
        guard !reduceMotion else { return (minHeight + maxHeight) / 2 }

        // Create wave pattern across bars
        let offset = Double(index) * 0.4
        let wave = sin(phase + offset)
        let normalized = (wave + 1) / 2  // 0 to 1
        return minHeight + (maxHeight - minHeight) * CGFloat(normalized)
    }

    private func startBreathing() {
        // Slow, subtle breathing animation (3 second cycle)
        withAnimation(
            .linear(duration: 3)
            .repeatForever(autoreverses: false)
        ) {
            phase = .pi * 2
        }
    }
}

// MARK: - Minimal Waveform Icon (Collapsed idle state)

/// Simplified 3-bar waveform icon for the collapsed idle pill
/// Static or very subtle breathing animation, respects reduce motion
@available(macOS 14.0, *)
struct MinimalWaveformIcon: View {
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State private var breatheScale: CGFloat = 1.0

    private let barWidth: CGFloat = 2
    private let barSpacing: CGFloat = 2
    // Symmetric heights: short, tall, short
    private let barHeights: [CGFloat] = [4, 8, 4]

    var body: some View {
        HStack(spacing: barSpacing) {
            ForEach(0..<3, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.terracotta.opacity(0.5))
                    .frame(width: barWidth, height: barHeights[index] * breatheScale)
            }
        }
        .onAppear {
            if !reduceMotion {
                startSubtleBreathing()
            }
        }
    }

    private func startSubtleBreathing() {
        // Very slow, subtle breathing (5 second cycle, minimal scale change)
        withAnimation(
            .easeInOut(duration: 2.5)
            .repeatForever(autoreverses: true)
        ) {
            breatheScale = 1.15
        }
    }
}
