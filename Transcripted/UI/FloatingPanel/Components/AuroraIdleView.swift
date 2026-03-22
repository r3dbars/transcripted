import SwiftUI

// MARK: - Aurora Idle View
/// Idle state: confident but minimal presence
/// Collapsed: 52x26px capsule with mic icon — visible against any wallpaper
/// Expanded: 160x36px on hover with Record + Transcripts buttons

@available(macOS 26.0, *)
struct AuroraIdleView: View {
    let onRecord: () -> Void
    let onTranscripts: () -> Void
    let failedCount: Int
    var backgroundTaskCount: Int = 0
    var forceExpanded: Bool = false
    var showOnboardingGlow: Bool = false

    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State private var isHoverExpanded = false
    @State private var isRecordHovered = false
    @State private var isFilesHovered = false

    private var isExpanded: Bool { isHoverExpanded || forceExpanded }

    // Confident resting size — visible but unobtrusive
    private let collapsedWidth: CGFloat = 52
    private let collapsedHeight: CGFloat = 26
    private let expandedWidth: CGFloat = 160
    private let expandedHeight: CGFloat = 36

    var body: some View {
        ZStack {
            // Dark capsule background with border for definition
            idleBackground
                .clipShape(Capsule())

            // Mic icon in collapsed state
            if !isExpanded {
                Image(systemName: "mic.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.panelTextMuted)
            }

            // Background processing badge (top-left when collapsed)
            if backgroundTaskCount > 0 && !isExpanded {
                ProcessingPulseDot()
                    .offset(x: -20, y: -14)
            }

            // Failed badge (top-right when collapsed)
            if failedCount > 0 && !isExpanded {
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

            // Expanded content
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

    // MARK: - Background

    private var idleBackground: some View {
        ZStack {
            Color.panelCharcoal
        }
        .overlay(
            Capsule()
                .strokeBorder(
                    failedCount > 0
                        ? Color.recordingCoral.opacity(0.3)
                        : Color.panelCharcoalSurface,
                    lineWidth: 1
                )
        )
        .shadow(color: Color.black.opacity(0.3), radius: 4, y: 1)
        .glowPulse(when: backgroundTaskCount > 0 && !isExpanded, color: .recordingCoral)
        .overlay(
            Capsule()
                .strokeBorder(Color.premiumCoral, lineWidth: showOnboardingGlow ? 2 : 0)
                .shadow(color: showOnboardingGlow ? Color.premiumCoral.opacity(0.6) : .clear, radius: showOnboardingGlow ? 10 : 0)
                .shadow(color: showOnboardingGlow ? Color.premiumCoral.opacity(0.3) : .clear, radius: showOnboardingGlow ? 20 : 0)
                .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: showOnboardingGlow)
        )
    }

    // MARK: - Expanded Content

    private var expandedContent: some View {
        HStack(spacing: 0) {
            // Record button (left)
            Button(action: onRecord) {
                ZStack {
                    Circle()
                        .fill(isRecordHovered ? Color.panelCharcoalSurface : Color.panelCharcoalElevated)
                        .frame(width: 26, height: 26)

                    Image(systemName: "mic.fill")
                        .font(.system(size: 12, weight: .medium))
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
            .frame(width: 36)

            Spacer()

            // Center: processing indicator
            if backgroundTaskCount > 0 {
                ProcessingPulseDot()
            }

            Spacer()

            // Transcripts button (right)
            Button(action: onTranscripts) {
                ZStack {
                    Circle()
                        .fill(isFilesHovered ? Color.panelCharcoalSurface : Color.panelCharcoalElevated)
                        .frame(width: 26, height: 26)

                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 11, weight: .medium))
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
            .frame(width: 36)
        }
        .padding(.horizontal, 6)
    }
}

// MARK: - Processing Pulse Dot

/// Subtle pulsing dot indicating background transcription is in progress
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
                AuroraIdleView(onRecord: {}, onTranscripts: {}, failedCount: 0)
                AuroraIdleView(onRecord: {}, onTranscripts: {}, failedCount: 3)
            }
        }
        .frame(width: 300, height: 200)
    }
}
#endif
