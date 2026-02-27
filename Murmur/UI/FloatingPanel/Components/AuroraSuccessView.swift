import SwiftUI

// MARK: - Aurora Success View
/// In-pill success feedback with animated checkmark and clear messaging
/// Expanded size (200x44) for visual continuity with processing view
/// Shows descriptive text so users know what happened

@available(macOS 26.0, *)
struct AuroraSuccessView: View {
    /// Type of success to display
    enum SuccessType: Equatable {
        case transcriptSaved
        case tasksAdded(count: Int)
    }

    let successType: SuccessType

    // Accessibility
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var checkScale: CGFloat = 0.3
    @State private var checkOpacity: CGFloat = 0
    @State private var textOpacity: CGFloat = 0

    // Expanded dimensions (matches processing view for smooth transition)
    private let width: CGFloat = 200
    private let height: CGFloat = 44

    var body: some View {
        ZStack {
            // Success background with green glow
            successBackground
                .clipShape(Capsule())

            // Content: checkmark + text
            HStack(spacing: 12) {
                // Animated checkmark
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(.statusSuccessMuted)
                    .scaleEffect(checkScale)
                    .opacity(checkOpacity)

                // Text content - fixedSize prevents truncation
                VStack(alignment: .leading, spacing: 2) {
                    Text(primaryText)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.panelTextPrimary)
                        .opacity(textOpacity)

                    if let secondary = secondaryText {
                        Text(secondary)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundColor(.panelTextMuted)
                            .opacity(textOpacity)
                    }
                }
                .fixedSize(horizontal: true, vertical: false)

                Spacer()
            }
            .padding(.horizontal, 16)
        }
        .frame(width: width, height: height)
        .onAppear {
            animateSuccess()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    // MARK: - Text Content

    private var primaryText: String {
        switch successType {
        case .transcriptSaved:
            return "Saved"
        case .tasksAdded(let count):
            return "\(count) task\(count == 1 ? "" : "s") added"
        }
    }

    private var secondaryText: String? {
        switch successType {
        case .transcriptSaved:
            return "No tasks found"
        case .tasksAdded:
            return nil
        }
    }

    // MARK: - Success Background

    private var successBackground: some View {
        ZStack {
            Color.panelCharcoal

            // Subtle green radial glow
            RadialGradient(
                colors: [
                    Color.statusSuccessMuted.opacity(0.2),
                    Color.statusSuccessMuted.opacity(0.08),
                    Color.clear
                ],
                center: .leading,
                startRadius: 0,
                endRadius: 120
            )
        }
        .overlay(
            Capsule()
                .strokeBorder(Color.statusSuccessMuted.opacity(0.5), lineWidth: 1.5)
        )
        .shadow(color: Color.statusSuccessMuted.opacity(0.25), radius: 10, y: 0)
    }

    // MARK: - Animation

    private func animateSuccess() {
        // Phase 1: Scale + fade in checkmark (spring)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) {
            checkScale = 1.0
            checkOpacity = 1.0
        }

        // Phase 2: Bounce out slightly
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.5)) {
                checkScale = 1.15
            }
        }

        // Phase 3: Settle back
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            withAnimation(.spring(response: 0.15, dampingFraction: 0.8)) {
                checkScale = 1.0
            }
        }

        // Phase 4: Fade in text
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            withAnimation(.easeOut(duration: 0.25)) {
                textOpacity = 1.0
            }
        }
    }

    // MARK: - Accessibility

    private var accessibilityText: String {
        switch successType {
        case .transcriptSaved:
            return "Transcript saved. No tasks found."
        case .tasksAdded(let count):
            return "\(count) task\(count == 1 ? "" : "s") added"
        }
    }
}

// MARK: - Preview

#if DEBUG
@available(macOS 26.0, *)
struct AuroraSuccessView_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Color.black
            VStack(spacing: 20) {
                AuroraSuccessView(successType: .transcriptSaved)
                AuroraSuccessView(successType: .tasksAdded(count: 1))
                AuroraSuccessView(successType: .tasksAdded(count: 3))
                AuroraSuccessView(successType: .tasksAdded(count: 12))
            }
        }
        .frame(width: 300, height: 300)
    }
}
#endif
