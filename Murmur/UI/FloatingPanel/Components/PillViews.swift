import SwiftUI

// MARK: - Pill Idle View (Hover-expand design)

/// Minimal capsule that expands on hover to reveal Record and Files buttons
/// Collapsed: 40x20px with minimal waveform icon
/// Expanded: 120x28px with two buttons side-by-side
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

    private var currentWidth: CGFloat {
        isExpanded ? PillDimensions.idleExpandedWidth : PillDimensions.idleWidth
    }

    private var currentHeight: CGFloat {
        isExpanded ? PillDimensions.idleExpandedHeight : PillDimensions.idleHeight
    }

    var body: some View {
        ZStack {
            // Frosted glass capsule background
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule()
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.3), Color.white.opacity(0.1)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.5
                        )
                )

            // Content: collapsed icon or expanded buttons
            if isExpanded {
                expandedContent
            } else {
                collapsedContent
            }

            // Failed transcription badge (top-right) - only when collapsed
            if failedCount > 0 && !isExpanded {
                FailedBadgeOverlay(count: failedCount)
                    .offset(x: currentWidth / 2 - 6, y: -currentHeight / 2 + 4)
            }
        }
        .frame(width: currentWidth, height: currentHeight)
        .animation(reduceMotion ? .none : .elegant, value: isExpanded)
        .shadow(color: Color.black.opacity(0.15), radius: 4, y: 2)
        .onHover { hovering in
            withAnimation(reduceMotion ? .none : .elegant) {
                isExpanded = hovering
                if !hovering {
                    hoveredButton = nil
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isExpanded ? "Recording options" : "Transcripted - hover to expand")
    }

    // MARK: - Collapsed Content

    private var collapsedContent: some View {
        MinimalWaveformIcon()
    }

    // MARK: - Expanded Content

    private var expandedContent: some View {
        HStack(spacing: 0) {
            // Record button - left side
            ExpandedPillButton(
                icon: "mic.fill",
                label: "Record",
                isHovered: hoveredButton == .record,
                action: onRecord
            )
            .onHover { hovering in
                hoveredButton = hovering ? .record : (hoveredButton == .record ? nil : hoveredButton)
            }

            // Subtle divider
            Rectangle()
                .fill(Color.white.opacity(0.15))
                .frame(width: 1, height: 16)

            // Files button - right side
            ExpandedPillButton(
                icon: "doc.text.fill",
                label: "Files",
                isHovered: hoveredButton == .files,
                action: onFiles
            )
            .onHover { hovering in
                hoveredButton = hovering ? .files : (hoveredButton == .files ? nil : hoveredButton)
            }
        }
        .opacity(isExpanded ? 1 : 0)
        .animation(reduceMotion ? .none : .easeOut(duration: 0.2).delay(0.1), value: isExpanded)
    }
}

// MARK: - Expanded Pill Button

/// Reusable button component for the expanded idle pill
/// Shows icon + label with hover highlight effect
@available(macOS 14.0, *)
struct ExpandedPillButton: View {
    let icon: String
    let label: String
    let isHovered: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))

                Text(label)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(isHovered ? .panelTextPrimary : .panelTextSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.white.opacity(0.1) : Color.clear)
            )
            .scaleEffect(isHovered ? 1.02 : 1.0)
            .animation(.pillMorph, value: isHovered)
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel(label)
        .accessibilityHint(label == "Record" ? "Start recording audio" : "Open transcripts folder")
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
            // Frosted glass background with coral border tint
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule()
                        .strokeBorder(Color.recordingCoral.opacity(0.4), lineWidth: 1.5)
                )
                .shadow(color: Color.recordingCoral.opacity(0.2), radius: 8)

            HStack(spacing: 12) {
                // Recording dot
                RecordingDotView()
                    .padding(.leading, 12)

                // Waveform visualizer (reuse existing, smaller size)
                WaveformMiniView(
                    levels: Array(audio.audioLevelHistory.suffix(8)),
                    systemLevels: Array(audio.systemAudioLevelHistory.suffix(8)),
                    barCount: 6,
                    maxHeight: 20
                )
                .frame(width: 50, height: 24)

                // Timer (SF Mono, 13px)
                Text(formatDuration(audio.recordingDuration))
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(.panelTextPrimary)
                    .monospacedDigit()

                Spacer()

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
            // Frosted glass background
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule()
                        .strokeBorder(Color.processingPurple.opacity(0.3), lineWidth: 1)
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
        case .preparing, .transcribing:
            return .statusProcessingMuted
        case .extractingActionItems:
            return .processingPurple
        case .saving:
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

                // Frosted glass with green success tint
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.statusSuccessMuted.opacity(0.5), lineWidth: 1.5)
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
