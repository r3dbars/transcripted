import SwiftUI

// MARK: - Pill Error View (Phase 6 Polish)

/// Coral-tinted pill with shake animation for errors
/// Shows recovery hint and auto-dismisses
@available(macOS 14.0, *)
struct PillErrorView: View {
    let message: String
    let hint: String?
    @Binding var isVisible: Bool

    @State private var shakeOffset: CGFloat = 0
    @State private var contentOpacity: Double = 0

    var body: some View {
        ZStack {
            // Error-tinted frosted glass
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule()
                        .strokeBorder(Color.errorCoral.opacity(0.5), lineWidth: 1.5)
                )
                .shadow(color: Color.errorCoral.opacity(0.2), radius: 6)

            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.errorCoral)

                VStack(alignment: .leading, spacing: 2) {
                    Text(message)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.panelTextPrimary)
                        .lineLimit(1)

                    if let hint = hint {
                        Text(hint)
                            .font(.system(size: 10))
                            .foregroundColor(.panelTextSecondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                // Dismiss button
                Button(action: { isVisible = false }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.panelTextMuted)
                        .padding(4)
                        .background(Circle().fill(Color.white.opacity(0.1)))
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal, 12)
        }
        .frame(width: PillDimensions.recordingWidth + 40, height: PillDimensions.recordingHeight + 8)
        .offset(x: shakeOffset)
        .opacity(contentOpacity)
        .onChange(of: isVisible) { _, visible in
            if visible {
                animateIn()
            }
        }
        .onAppear {
            if isVisible {
                animateIn()
            }
        }
        .accessibilityLabel("Error: \(message)")
        .accessibilityHint(hint ?? "Tap X to dismiss")
    }

    private func animateIn() {
        // Fade in
        withAnimation(.easeOut(duration: 0.2)) {
            contentOpacity = 1
        }

        // Shake animation (5 cycles)
        let shakeSequence: [CGFloat] = [5, -5, 4, -4, 3, -3, 2, -2, 1, -1, 0]
        for (index, offset) in shakeSequence.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.05) {
                withAnimation(.linear(duration: 0.05)) {
                    shakeOffset = offset
                }
            }
        }

        // Auto-dismiss after 4 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            withAnimation(.easeOut(duration: 0.3)) {
                contentOpacity = 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                isVisible = false
            }
        }
    }
}
