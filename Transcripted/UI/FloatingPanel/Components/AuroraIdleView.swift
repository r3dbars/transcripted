import SwiftUI

// MARK: - Aurora Idle View
/// Idle state view matching the recording state's visual pattern
/// Same dimensions and hover-to-expand behavior as AuroraRecordingView

@available(macOS 26.0, *)
struct AuroraIdleView: View {
    let onRecord: () -> Void
    let onTranscripts: () -> Void
    let failedCount: Int
    var backgroundTaskCount: Int = 0
    var forceExpanded: Bool = false

    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State private var isHoverExpanded = false

    /// True when pill should show expanded state (hover OR forced by tray)
    private var isExpanded: Bool { isHoverExpanded || forceExpanded }
    @State private var isRecordHovered = false
    @State private var isFilesHovered = false

    /// Tracks whether the view has settled after appearing
    /// When false, view starts at success view's size (200×44) to enable smooth transition
    /// When true, view uses normal collapsed/expanded sizing
    @State private var hasSettled = false

    // Ultra-small collapsed state (smaller than recording)
    private let collapsedWidth: CGFloat = 40
    private let collapsedHeight: CGFloat = 20
    private let expandedWidth: CGFloat = 200
    private let expandedHeight: CGFloat = 44

    // Initial size matches AuroraSuccessView for smooth transition
    private let initialWidth: CGFloat = 200
    private let initialHeight: CGFloat = 44

    var body: some View {
        ZStack {
            // Idle background - subtle dark capsule
            idleBackground
                .clipShape(Capsule())

            // Subtle mic icon in collapsed state to signal clickability
            if !isExpanded {
                Image(systemName: "mic.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.panelTextMuted.opacity(0.4))
            }

            // Background processing badge (top-left when collapsed)
            if backgroundTaskCount > 0 && !isExpanded {
                processingBadge
            }

            // Failed badge (top-right when collapsed)
            if failedCount > 0 && !isExpanded {
                failedBadge
            }

            // Expanded content (buttons + waveform)
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
            isHoverExpanded = hovering
        }
        .onTapGesture {
            if !isExpanded {
                onRecord()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Ready to record")
        .accessibilityHint("Click to start recording, or hover to reveal controls")
    }

    // MARK: - Idle Background

    private var idleBackground: some View {
        ZStack {
            Color.panelCharcoal
            // Ultra-minimal: empty capsule when collapsed
        }
        .overlay(
            Capsule()
                .strokeBorder(
                    failedCount > 0
                        ? Color.recordingCoral.opacity(0.3)
                        : Color.panelCharcoalSurface,
                    lineWidth: failedCount > 0 ? 1.5 : 1
                )
        )
        .shadow(color: Color.black.opacity(0.3), radius: 8, y: 2)
        .glowPulse(when: backgroundTaskCount > 0 && !isExpanded, color: .recordingCoral)
    }

    // MARK: - Failed Badge

    private var failedBadge: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 18, height: 18)
            .overlay(
                Text("\(min(failedCount, 9))")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
            )
            .offset(x: 28, y: -14)
    }

    // MARK: - Processing Badge

    private var processingBadge: some View {
        ProcessingPulseDot()
            .offset(x: -20, y: -14)
    }

    // MARK: - Expanded Content

    private var expandedContent: some View {
        HStack(spacing: 0) {
            // Record button (left) - PRIMARY ACTION
            Button(action: onRecord) {
                ZStack {
                    Circle()
                        .fill(isRecordHovered ? Color.panelCharcoalSurface : Color.panelCharcoalElevated)
                        .frame(width: 32, height: 32)

                    Image(systemName: "mic.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(isRecordHovered ? .recordingCoral : .panelTextPrimary)
                }
                .scaleEffect(isRecordHovered ? 1.1 : 1.0)
            }
            .buttonStyle(PlainButtonStyle())
            .floatingTooltip("Record")
            .onHover { hovering in
                withAnimation(.spring(response: 0.15, dampingFraction: 0.8)) {
                    isRecordHovered = hovering
                }
            }
            .accessibilityLabel("Start recording")
            .frame(width: 44)

            Spacer()

            // Center: processing indicator (when background tasks active)
            if backgroundTaskCount > 0 {
                ProcessingPulseDot()
            }

            Spacer()

            // Transcripts button (right) - SECONDARY ACTION
            Button(action: onTranscripts) {
                ZStack {
                    Circle()
                        .fill(isFilesHovered ? Color.panelCharcoalSurface : Color.panelCharcoalElevated)
                        .frame(width: 32, height: 32)

                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.panelTextPrimary)
                }
                .scaleEffect(isFilesHovered ? 1.1 : 1.0)
            }
            .buttonStyle(PlainButtonStyle())
            .floatingTooltip("Transcripts")
            .onHover { hovering in
                withAnimation(.spring(response: 0.15, dampingFraction: 0.8)) {
                    isFilesHovered = hovering
                }
            }
            .accessibilityLabel("Browse recent transcripts")
            .frame(width: 44)
        }
        .padding(.horizontal, 8)
    }
}

// MARK: - Idle Panel Waveform View

/// A subtle, gently pulsing waveform for the dark panel theme
/// Distinct from DormantWaveformView in WaveformViews.swift which uses terracotta/warm theme
struct IdlePanelWaveformView: View {
    let isAnimating: Bool

    @State private var phase: CGFloat = 0

    private let barCount = 5
    private let barWidth: CGFloat = 3
    private let barSpacing: CGFloat = 2
    private let baseHeights: [CGFloat] = [6, 10, 14, 10, 6]

    var body: some View {
        HStack(spacing: barSpacing) {
            ForEach(0..<barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.panelTextMuted)
                    .frame(width: barWidth, height: barHeight(for: index))
            }
        }
        .onAppear {
            if isAnimating {
                withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                    phase = 1
                }
            }
        }
    }

    private func barHeight(for index: Int) -> CGFloat {
        guard isAnimating else {
            return baseHeights[index]
        }
        let variation = sin(Double(index) * 0.5 + Double(phase) * .pi) * 2
        return baseHeights[index] + CGFloat(variation)
    }
}

// MARK: - Processing Pulse Dot

/// Subtle pulsing dot indicating background transcription is in progress
/// Communicates "work is happening" without blocking the user from recording
struct ProcessingPulseDot: View {
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(Color.recordingCoral.opacity(0.9))
            .frame(width: 12, height: 12)
            .scaleEffect(isPulsing ? 1.2 : 0.8)
            .opacity(isPulsing ? 1.0 : 0.5)
            .animation(
                .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                value: isPulsing
            )
            .onAppear { isPulsing = true }
    }
}

// MARK: - Preview

#if DEBUG
@available(macOS 26.0, *)
struct AuroraIdleView_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Color.black
            VStack(spacing: 40) {
                // Collapsed state
                AuroraIdleView(onRecord: {}, onTranscripts: {}, failedCount: 0)

                // With failed badge
                AuroraIdleView(onRecord: {}, onTranscripts: {}, failedCount: 3)
            }
        }
        .frame(width: 300, height: 200)
    }
}
#endif
