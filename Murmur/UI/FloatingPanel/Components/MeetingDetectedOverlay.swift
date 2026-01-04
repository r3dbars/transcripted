import SwiftUI
import AppKit

// MARK: - Meeting Detected Overlay
/// Non-intrusive prompt that appears when a meeting is detected
/// Shows coral glow background with "Record this meeting?" and action buttons
/// Persistent until user clicks Record or Dismiss (no auto-dismiss)

@available(macOS 26.0, *)
struct MeetingDetectedOverlay: View {
    let onRecord: () -> Void
    let onDismiss: () -> Void

    @State private var glowOpacity: Double = 0.3
    @State private var isHoveringRecord: Bool = false
    @State private var isHoveringDismiss: Bool = false

    // Match the recording pill dimensions
    private let width: CGFloat = PillDimensions.recordingWidth  // 180
    private let height: CGFloat = PillDimensions.recordingHeight  // 40

    var body: some View {
        ZStack {
            // Coral glow background (recording color, not warning amber)
            coralBackground
                .clipShape(Capsule())

            HStack(spacing: 8) {
                // Record button (LEFT) - coral dot
                Button(action: {
                    onRecord()
                }) {
                    ZStack {
                        Circle()
                            .fill(Color.panelCharcoalElevated)
                            .frame(width: 28, height: 28)

                        Circle()
                            .fill(Color.recordingCoral)
                            .frame(width: 10, height: 10)
                    }
                    .scaleEffect(isHoveringRecord ? 1.1 : 1.0)
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isHoveringRecord = hovering
                    }
                }
                .accessibilityLabel("Start recording")

                Spacer()

                // Text (CENTER) - action-oriented copy
                Text("Record?")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.panelTextPrimary)
                    .lineLimit(1)

                Spacer()

                // Dismiss button (RIGHT) - red X
                Button(action: {
                    onDismiss()
                }) {
                    ZStack {
                        Circle()
                            .fill(Color.panelCharcoalElevated)
                            .frame(width: 28, height: 28)

                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.red.opacity(0.8))
                    }
                    .scaleEffect(isHoveringDismiss ? 1.1 : 1.0)
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isHoveringDismiss = hovering
                    }
                }
                .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, 12)
        }
        .frame(width: width, height: height)
        .onAppear {
            startGlowAnimation()
            playEntrySound()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Record meeting? Tap record button to start, or dismiss to ignore.")
    }

    // MARK: - Coral Background (Recording Color)

    private var coralBackground: some View {
        ZStack {
            // Base dark background
            Color.panelCharcoal

            // Coral radial glow (pulsing) - using recording color instead of warning amber
            RadialGradient(
                colors: [
                    Color.recordingCoral.opacity(glowOpacity),
                    Color.recordingCoral.opacity(glowOpacity * 0.3),
                    Color.clear
                ],
                center: .leading,
                startRadius: 0,
                endRadius: 150
            )
        }
        .overlay(
            Capsule()
                .strokeBorder(Color.recordingCoral.opacity(0.4), lineWidth: 1.5)
        )
        .shadow(color: Color.recordingCoral.opacity(0.2), radius: 12, y: 0)
    }

    // MARK: - Glow Animation

    private func startGlowAnimation() {
        withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
            glowOpacity = 0.5
        }
    }

    // MARK: - Entry Sound

    private func playEntrySound() {
        // Play subtle system sound when overlay appears
        NSSound(named: "Pop")?.play()
    }
}

// MARK: - Preview

#if DEBUG
@available(macOS 26.0, *)
struct MeetingDetectedOverlay_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Color.black
            MeetingDetectedOverlay(
                onRecord: { print("Record tapped") },
                onDismiss: { print("Dismissed") }
            )
        }
        .frame(width: 300, height: 100)
    }
}
#endif
