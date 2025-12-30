import SwiftUI

// MARK: - Pill Success Celebration (Phase 6 Polish)

/// Expanding green glow ring with checkmark
/// Shows briefly when tasks are added successfully
@available(macOS 14.0, *)
struct PillSuccessCelebration: View {
    let taskCount: Int
    let isVisible: Bool

    @State private var ringScale: CGFloat = 0.8
    @State private var ringOpacity: Double = 0
    @State private var contentOpacity: Double = 0

    var body: some View {
        ZStack {
            // Expanding glow ring
            Circle()
                .stroke(Color.statusSuccessMuted.opacity(0.4), lineWidth: 3)
                .frame(width: 80, height: 80)
                .scaleEffect(ringScale)
                .opacity(ringOpacity)

            // Inner content
            VStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.statusSuccessMuted)

                Text("\(taskCount) added")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.panelTextPrimary)
            }
            .opacity(contentOpacity)
        }
        .onChange(of: isVisible) { _, visible in
            if visible {
                animate()
            } else {
                reset()
            }
        }
        .onAppear {
            if isVisible {
                animate()
            }
        }
    }

    private func animate() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) {
            ringScale = 1.5
            ringOpacity = 1
            contentOpacity = 1
        }

        // Fade out ring
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            withAnimation(.easeOut(duration: 0.5)) {
                ringOpacity = 0
            }
        }
    }

    private func reset() {
        ringScale = 0.8
        ringOpacity = 0
        contentOpacity = 0
    }
}

// MARK: - Success Celebration Overlay (Peak-End Rule: positive endings are remembered)

/// Overlay that shows celebration animations for success states
/// Uses Laws of UX aesthetic with warm, subtle animations
@available(macOS 14.0, *)
struct CelebrationOverlay: View {
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    let celebrationType: CelebrationType
    let isVisible: Bool

    enum CelebrationType: Equatable {
        case recordingStopped           // Blue pulse ring fade
        case transcriptSaved            // Green checkmark scale-in
        case actionItemsCreated(count: Int)  // Count badge with bounce
    }

    @State private var ringScale: CGFloat = 0.8
    @State private var ringOpacity: Double = 0.0
    @State private var checkScale: CGFloat = 0.5
    @State private var badgeBounce: CGFloat = 1.0

    var body: some View {
        ZStack {
            switch celebrationType {
            case .recordingStopped:
                recordingStoppedCelebration
            case .transcriptSaved:
                transcriptSavedCelebration
            case .actionItemsCreated(let count):
                actionItemsCelebration(count: count)
            }
        }
        .opacity(isVisible ? 1.0 : 0.0)
        .animation(reduceMotion ? .none : .easeOut(duration: 0.3), value: isVisible)
        .onChange(of: isVisible) { _, newValue in
            if newValue {
                triggerCelebration()
            }
        }
    }

    // MARK: - Recording Stopped (Blue pulse ring)

    private var recordingStoppedCelebration: some View {
        Circle()
            .stroke(Color.accentBlue.opacity(ringOpacity), lineWidth: 3)
            .frame(width: 60, height: 60)
            .scaleEffect(ringScale)
    }

    // MARK: - Transcript Saved (Green checkmark)

    private var transcriptSavedCelebration: some View {
        ZStack {
            // Background circle
            Circle()
                .fill(Color.statusSuccessMuted.opacity(0.15))
                .frame(width: 48, height: 48)
                .scaleEffect(checkScale)

            // Checkmark icon
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 32, weight: .medium))
                .foregroundColor(.statusSuccessMuted)
                .scaleEffect(checkScale)
        }
    }

    // MARK: - Action Items Created (Count badge with bounce)

    private func actionItemsCelebration(count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checklist")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.statusSuccessMuted)

            Text("\(count) task\(count == 1 ? "" : "s") added")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.textOnCream)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(Color.surfaceCard)
                .overlay(
                    Capsule()
                        .stroke(Color.statusSuccessMuted.opacity(0.3), lineWidth: 1)
                )
        )
        .shadow(color: Color.statusSuccessMuted.opacity(0.2), radius: 8, y: 4)
        .scaleEffect(badgeBounce)
    }

    // MARK: - Trigger Animation

    private func triggerCelebration() {
        guard !reduceMotion else { return }

        switch celebrationType {
        case .recordingStopped:
            // Blue ring expands and fades out
            ringScale = 0.8
            ringOpacity = 0.8
            withAnimation(.easeOut(duration: 0.6)) {
                ringScale = 1.5
                ringOpacity = 0.0
            }

        case .transcriptSaved:
            // Green checkmark scales in with bounce
            checkScale = 0.5
            withAnimation(.lawsSuccess) {
                checkScale = 1.0
            }
            // Subtle bounce
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                withAnimation(.spring(response: 0.2, dampingFraction: 0.5)) {
                    checkScale = 1.1
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                withAnimation(.spring(response: 0.15, dampingFraction: 0.8)) {
                    checkScale = 1.0
                }
            }

        case .actionItemsCreated:
            // Badge bounces in
            badgeBounce = 0.7
            withAnimation(.spring(response: 0.4, dampingFraction: 0.5)) {
                badgeBounce = 1.0
            }
            // Extra bounce
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                withAnimation(.spring(response: 0.15, dampingFraction: 0.4)) {
                    badgeBounce = 1.1
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                withAnimation(.spring(response: 0.1, dampingFraction: 0.6)) {
                    badgeBounce = 1.0
                }
            }
        }
    }
}

// MARK: - Recording Stopped Celebration View

/// Simple celebration when recording stops (before transcription starts)
@available(macOS 14.0, *)
struct RecordingStoppedCelebration: View {
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    let isVisible: Bool

    @State private var ringScale: CGFloat = 0.6
    @State private var ringOpacity: Double = 0.0

    var body: some View {
        Circle()
            .stroke(Color.accentBlue.opacity(ringOpacity), lineWidth: 2)
            .frame(width: 50, height: 50)
            .scaleEffect(ringScale)
            .onChange(of: isVisible) { _, newValue in
                if newValue && !reduceMotion {
                    ringScale = 0.6
                    ringOpacity = 0.7
                    withAnimation(.easeOut(duration: 0.5)) {
                        ringScale = 1.3
                        ringOpacity = 0.0
                    }
                }
            }
    }
}
