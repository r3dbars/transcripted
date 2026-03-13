import SwiftUI

// MARK: - Unified Celebration Overlay

/// Single reusable celebration animation for success states.
/// Replaces the three previous redundant views (PillSuccessCelebration, CelebrationOverlay, RecordingStoppedCelebration).
/// Supports two styles: expanding ring and checkmark scale-in.
@available(macOS 14.0, *)
struct CelebrationOverlay: View {
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    let style: CelebrationStyle
    let isVisible: Bool

    enum CelebrationStyle: Equatable {
        /// Blue ring that expands and fades (recording stopped)
        case ring(color: Color = .accentBlue)
        /// Green checkmark that scales in (transcript saved)
        case checkmark
    }

    @State private var ringScale: CGFloat = 0.8
    @State private var ringOpacity: Double = 0.0
    @State private var checkScale: CGFloat = 0.5

    var body: some View {
        ZStack {
            switch style {
            case .ring(let color):
                Circle()
                    .stroke(color.opacity(ringOpacity), lineWidth: 3)
                    .frame(width: 60, height: 60)
                    .scaleEffect(ringScale)

            case .checkmark:
                ZStack {
                    Circle()
                        .fill(Color.statusSuccessMuted.opacity(0.15))
                        .frame(width: 48, height: 48)
                        .scaleEffect(checkScale)

                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 32, weight: .medium))
                        .foregroundColor(.statusSuccessMuted)
                        .scaleEffect(checkScale)
                }
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

    private func triggerCelebration() {
        guard !reduceMotion else { return }

        switch style {
        case .ring:
            ringScale = 0.8
            ringOpacity = 0.8
            withAnimation(.easeOut(duration: 0.6)) {
                ringScale = 1.5
                ringOpacity = 0.0
            }

        case .checkmark:
            checkScale = 0.5
            withAnimation(.spring(response: 0.4, dampingFraction: 0.5)) {
                checkScale = 1.0
            }
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
        }
    }
}
