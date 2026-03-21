import SwiftUI

// MARK: - Pill Recording View (180x40px - Dynamic Island style)

/// Expanded pill shown during recording
/// Contains: recording dot, waveform visualizer, timer, stop button
@available(macOS 26.0, *)
struct PillRecordingView: View {
    @ObservedObject var audio: Audio
    let onStop: () -> Void

    @State private var isStopHovered = false

    // MARK: - Invisible Warning Indicator (Phase 2: 2-second delay)
    // Brief issues (<2s) are completely invisible to users
    @State private var showWarningDelayed = false
    @State private var warningDelayTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            // Solid dark background with coral border tint
            Capsule()
                .fill(Color.panelCharcoal)
                .overlay(
                    Capsule()
                        .strokeBorder(Color.recordingCoral.opacity(0.6), lineWidth: 1.5)
                )
                .shadow(color: Color.recordingCoral.opacity(0.3), radius: 8)

            HStack(spacing: 8) {
                // Recording dot + optional system audio warning
                // Warning only shows after 2-second delay (brief issues are invisible)
                HStack(spacing: 4) {
                    RecordingDotView()

                    // System audio status indicator (only show after 2s delay)
                    if showWarningDelayed {
                        SystemAudioWarningIndicator(status: audio.systemAudioStatus)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .padding(.leading, 10)
                .animation(.snappy(duration: 0.2), value: showWarningDelayed)

                // Waveform visualizer (reuse existing, smaller size)
                WaveformMiniView(
                    levels: Array(audio.audioLevelHistory.suffix(8)),
                    systemLevels: Array(audio.systemAudioLevelHistory.suffix(8)),
                    barCount: 5,
                    maxHeight: 18
                )
                .frame(width: 40, height: 20)

                // Timer (SF Mono, 13px) - fixed width to prevent wrapping
                Text(formatDuration(audio.recordingDuration))
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(.panelTextPrimary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                Spacer(minLength: 4)

                // Stop button (28x28px circle)
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
                .onHover { hovering in
                    withAnimation(.pillMorph) {
                        isStopHovered = hovering
                    }
                }
                .padding(.trailing, 6)
                .accessibilityLabel("Stop recording")
            }
        }
        .frame(width: PillDimensions.recordingWidth, height: PillDimensions.recordingHeight)
        // MARK: - 2-Second Delay Logic for Warning Indicator
        // Achieves "invisible" recovery for brief issues (<2s)
        .onChange(of: audio.systemAudioStatus) { _, newStatus in
            warningDelayTask?.cancel()

            if newStatus.isWarning || newStatus.isRecovering {
                // Start 2-second delay before showing warning
                warningDelayTask = Task {
                    try? await Task.sleep(for: .seconds(2))
                    if !Task.isCancelled {
                        await MainActor.run {
                            showWarningDelayed = true
                        }
                    }
                }
            } else {
                // Issue resolved - hide indicator immediately
                showWarningDelayed = false
            }
        }
        .onDisappear {
            warningDelayTask?.cancel()
            showWarningDelayed = false
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Recording in progress, \(formatDurationAccessible(audio.recordingDuration))")
        .accessibilityHint("Contains stop button")
    }

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
