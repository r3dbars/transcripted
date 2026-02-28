import SwiftUI

// MARK: - Aurora Idle View
/// Idle state view matching the recording state's visual pattern
/// Same dimensions and hover-to-expand behavior as AuroraRecordingView

@available(macOS 26.0, *)
struct AuroraIdleView: View {
    let onRecord: () -> Void
    let onFiles: () -> Void
    let failedCount: Int
    var backgroundTaskCount: Int = 0

    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State private var isExpanded = false
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
            isExpanded = hovering
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Ready to record")
        .accessibilityHint("Hover to reveal controls")
    }

    // MARK: - Idle Background

    private var idleBackground: some View {
        ZStack {
            Color.panelCharcoal
            // Ultra-minimal: empty capsule when collapsed
        }
        .overlay(
            Capsule()
                .strokeBorder(Color.panelCharcoalSurface, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.3), radius: 8, y: 2)
    }

    // MARK: - Failed Badge

    private var failedBadge: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 14, height: 14)
            .overlay(
                Text("\(min(failedCount, 9))")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)
            )
            .offset(x: 28, y: -14)
    }

    // MARK: - Processing Badge

    private var processingBadge: some View {
        ProcessingPulseDot()
            .offset(x: -20, y: -14)
    }

    // MARK: - Branding View

    private var brandingView: some View {
        VStack(spacing: 1) {
            // Coral circle with waveform icon - compact for 44px pill
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.recordingCoral, Color.recordingCoralDeep],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 20, height: 20)

                Image(systemName: "waveform")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white)
            }

            // App name - tiny, below logo
            Text("Transcripted")
                .font(.system(size: 7, weight: .medium))
                .foregroundColor(.panelTextSecondary)
                .tracking(0.3)
        }
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

            // Center: App branding (logo + name) with optional processing indicator
            ZStack {
                brandingView
                if backgroundTaskCount > 0 {
                    ProcessingPulseDot()
                        .offset(x: 16, y: -12)
                }
            }

            Spacer()

            // Files button (right) - SECONDARY ACTION
            Button(action: onFiles) {
                ZStack {
                    Circle()
                        .fill(isFilesHovered ? Color.panelCharcoalSurface : Color.panelCharcoalElevated)
                        .frame(width: 32, height: 32)

                    Image(systemName: "folder.fill")
                        .font(.system(size: 14, weight: .medium))
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
            .accessibilityLabel("Open transcripts folder")
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
            .frame(width: 8, height: 8)
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
                AuroraIdleView(onRecord: {}, onFiles: {}, failedCount: 0)

                // With failed badge
                AuroraIdleView(onRecord: {}, onFiles: {}, failedCount: 3)
            }
        }
        .frame(width: 300, height: 200)
    }
}
#endif
