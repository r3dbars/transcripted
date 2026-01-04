import SwiftUI

// MARK: - Pill Idle View (Horizontal slide-out design)

/// Minimal capsule that slides out horizontally on hover to reveal buttons
/// Collapsed: 40x24px with minimal waveform icon (centered)
/// Expanded: Buttons slide out from center - Record left, Files right
@available(macOS 14.0, *)
struct PillIdleView: View {
    let onRecord: () -> Void
    let onFiles: () -> Void
    let failedCount: Int

    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State private var isExpanded = false
    @State private var hoveredButton: HoveredButton? = nil

    enum HoveredButton {
        case record
        case files
    }

    init(onRecord: @escaping () -> Void, onFiles: @escaping () -> Void, failedCount: Int = 0) {
        self.onRecord = onRecord
        self.onFiles = onFiles
        self.failedCount = failedCount
    }

    // Button dimensions
    private let buttonWidth: CGFloat = 56
    private let buttonHeight: CGFloat = 28
    private let coreWidth: CGFloat = 40
    private let coreHeight: CGFloat = 24

    var body: some View {
        ZStack {
            // Slide-out buttons (appear from behind core pill)
            HStack(spacing: 4) {
                // Record button - slides out left
                SlideOutButton(
                    icon: "mic.fill",
                    isHovered: hoveredButton == .record,
                    action: onRecord
                )
                .frame(width: buttonWidth, height: buttonHeight)
                .offset(x: isExpanded ? 0 : buttonWidth / 2)
                .opacity(isExpanded ? 1 : 0)
                .onHover { hovering in
                    hoveredButton = hovering ? .record : (hoveredButton == .record ? nil : hoveredButton)
                }

                // Spacer for core pill area
                Spacer()
                    .frame(width: coreWidth - 8)

                // Files button - slides out right
                SlideOutButton(
                    icon: "folder.fill",
                    isHovered: hoveredButton == .files,
                    action: onFiles
                )
                .frame(width: buttonWidth, height: buttonHeight)
                .offset(x: isExpanded ? 0 : -buttonWidth / 2)
                .opacity(isExpanded ? 1 : 0)
                .onHover { hovering in
                    hoveredButton = hovering ? .files : (hoveredButton == .files ? nil : hoveredButton)
                }
            }

            // Core pill (always visible, stays centered)
            ZStack {
                Capsule()
                    .fill(Color.panelCharcoal)
                    .overlay(
                        Capsule()
                            .strokeBorder(
                                isExpanded ? Color.panelCharcoalElevated : Color.panelCharcoalSurface,
                                lineWidth: 1
                            )
                    )

                MinimalWaveformIcon()
                    .scaleEffect(isExpanded ? 0.9 : 1.0)

                // Failed transcription badge (top-right)
                if failedCount > 0 {
                    FailedBadgeOverlay(count: failedCount)
                        .offset(x: coreWidth / 2 - 4, y: -coreHeight / 2 + 2)
                        .opacity(isExpanded ? 0.5 : 1.0)
                }
            }
            .frame(width: coreWidth, height: coreHeight)
            .shadow(color: Color.black.opacity(0.2), radius: 4, y: 2)
            .zIndex(1)  // Core pill stays on top
        }
        .frame(
            width: isExpanded ? (buttonWidth * 2 + coreWidth) : coreWidth,
            height: buttonHeight
        )
        .animation(reduceMotion ? .none : .snappy(duration: 0.2), value: isExpanded)
        .onHover { hovering in
            withAnimation(reduceMotion ? .none : .snappy(duration: 0.2)) {
                isExpanded = hovering
                if !hovering {
                    hoveredButton = nil
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isExpanded ? "Recording options" : "Transcripted - hover to expand")
    }
}

// MARK: - Slide-Out Button

/// Compact circular button that slides out from the core pill
@available(macOS 14.0, *)
struct SlideOutButton: View {
    let icon: String
    let isHovered: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Capsule()
                    .fill(isHovered ? Color.panelCharcoalElevated : Color.panelCharcoal.opacity(0.9))
                    .overlay(
                        Capsule()
                            .strokeBorder(
                                isHovered ? Color.recordingCoral.opacity(0.5) : Color.panelCharcoalSurface,
                                lineWidth: 1
                            )
                    )

                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isHovered ? .recordingCoral : .panelTextSecondary)
            }
            .scaleEffect(isHovered ? 1.05 : 1.0)
        }
        .buttonStyle(PlainButtonStyle())
        .shadow(color: Color.black.opacity(0.15), radius: 3, y: 1)
        .animation(.snappy(duration: 0.15), value: isHovered)
    }
}

// MARK: - Failed Badge Overlay

/// Small red circle showing count of failed transcriptions
struct FailedBadgeOverlay: View {
    let count: Int

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.errorCoral)
                .frame(width: 14, height: 14)

            Text("\(min(count, 9))\(count > 9 ? "+" : "")")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white)
        }
        .shadow(color: Color.errorCoral.opacity(0.3), radius: 2)
    }
}

// MARK: - Recording Dot View (Pulsing red indicator)

/// Classic red recording dot with pulsing animation
@available(macOS 14.0, *)
struct RecordingDotView: View {
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State private var isPulsing = false

    private let dotSize: CGFloat = 10

    var body: some View {
        Circle()
            .fill(Color(hex: "#FF0000"))  // Pure red for recording
            .frame(width: dotSize, height: dotSize)
            .scaleEffect(isPulsing ? 1.1 : 0.9)
            .shadow(color: Color.red.opacity(0.5), radius: 4)
            .onAppear {
                if !reduceMotion {
                    startPulsing()
                }
            }
    }

    private func startPulsing() {
        withAnimation(
            .easeInOut(duration: 0.6)
            .repeatForever(autoreverses: true)
        ) {
            isPulsing = true
        }
    }
}

// MARK: - Pill Recording View (180x40px - Dynamic Island style)

/// Expanded pill shown during recording
/// Contains: recording dot, waveform visualizer, timer, stop button
@available(macOS 26.0, *)
struct PillRecordingView: View {
    @ObservedObject var audio: Audio
    let onStop: () -> Void

    @State private var isStopHovered = false

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
                // Recording dot
                RecordingDotView()
                    .padding(.leading, 10)

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

// MARK: - Pill Processing View (180x40px - Status indicator)

/// Shown during transcription/processing
/// Displays status with icon and animated dots
@available(macOS 14.0, *)
struct PillProcessingView: View {
    let status: DisplayStatus

    var body: some View {
        ZStack {
            // Solid dark background
            Capsule()
                .fill(Color.panelCharcoal)
                .overlay(
                    Capsule()
                        .strokeBorder(Color.processingPurple.opacity(0.4), lineWidth: 1)
                )

            HStack(spacing: 10) {
                // Status icon with spinning animation for processing states
                Image(systemName: status.icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(statusColor)
                    .symbolEffect(.pulse, options: .repeating, isActive: status.isProcessing)

                // Status text with animated dots
                HStack(spacing: 0) {
                    Text(status.statusText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.panelTextPrimary)

                    if status.isProcessing {
                        AnimatedDotsView()
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(width: PillDimensions.recordingWidth, height: PillDimensions.recordingHeight)
        .accessibilityLabel(status.statusText)
    }

    private var statusColor: Color {
        switch status {
        case .gettingReady, .transcribing:
            return .statusProcessingMuted
        case .findingActionItems:
            return .processingPurple
        case .finishing:
            return .statusProcessingMuted
        case .completed, .transcriptSaved:
            return .statusSuccessMuted
        case .failed:
            return .statusErrorMuted
        default:
            return .panelTextSecondary
        }
    }
}

// MARK: - Pill Reviewing View (Bottom pill during review tray)

/// Shown at bottom of review tray
/// Green success tint with task count - anchors the expanded tray above
@available(macOS 14.0, *)
struct PillReviewingView: View {
    let itemCount: Int
    var onTap: (() -> Void)? = nil  // Optional tap handler for future expand/collapse

    @State private var isHovered = false
    @State private var pulseOpacity: Double = 0.4

    var body: some View {
        Button(action: { onTap?() }) {
            ZStack {
                // Subtle pulsing glow behind pill (draws attention)
                Capsule()
                    .fill(Color.statusSuccessMuted.opacity(pulseOpacity * 0.3))
                    .frame(width: PillDimensions.recordingWidth + 8, height: PillDimensions.recordingHeight + 4)
                    .blur(radius: 8)

                // Solid dark background with green success tint
                Capsule()
                    .fill(Color.panelCharcoal)
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.statusSuccessMuted.opacity(0.6), lineWidth: 1.5)
                    )

                HStack(spacing: 8) {
                    // Checklist icon with badge indicator
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "checklist")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.statusSuccessMuted)

                        // Small count badge
                        Circle()
                            .fill(Color.statusSuccessMuted)
                            .frame(width: 14, height: 14)
                            .overlay(
                                Text("\(min(itemCount, 9))")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(.white)
                            )
                            .offset(x: 8, y: -6)
                    }

                    Text("\(itemCount) task\(itemCount == 1 ? "" : "s") to review")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.panelTextPrimary)

                    // Up arrow indicator showing tray is above
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.panelTextMuted)
                }
            }
            .frame(width: PillDimensions.recordingWidth, height: PillDimensions.recordingHeight)
            .scaleEffect(isHovered ? 1.02 : 1.0)
            .shadow(color: Color.statusSuccessMuted.opacity(0.2), radius: 8, y: 2)
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(.pillMorph) {
                isHovered = hovering
            }
        }
        .onAppear {
            // Subtle pulse animation to draw attention
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                pulseOpacity = 0.8
            }
        }
        .accessibilityLabel("\(itemCount) tasks ready to review")
        .accessibilityHint("Review tray is open above")
    }
}
