import SwiftUI
import AppKit

// MARK: - Aurora Success View
/// In-pill success feedback with animated checkmark and action buttons
/// Expanded size (200x44) for visual continuity with processing view
/// Shows Copy and Open buttons so users can immediately act on the transcript

@available(macOS 26.0, *)
struct AuroraSuccessView: View {
    /// Type of success to display
    enum SuccessType: Equatable {
        case transcriptSaved
    }

    let successType: SuccessType
    var transcriptURL: URL? = nil
    var onCopyTranscript: (() -> Void)? = nil

    // Accessibility
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var checkScale: CGFloat = 0.3
    @State private var checkOpacity: CGFloat = 0
    @State private var textOpacity: CGFloat = 0
    @State private var isHovered = false
    @State private var isCopyHovered = false
    @State private var isOpenHovered = false
    @State private var showCopiedCheck = false

    // Expanded dimensions (matches processing view for smooth transition)
    private let width: CGFloat = 200
    private let height: CGFloat = 44

    var body: some View {
        ZStack {
            // Success background with green glow
            successBackground
                .clipShape(Capsule())

            // Content: checkmark + text + action buttons
            HStack(spacing: 8) {
                // Animated checkmark
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.statusSuccessMuted)
                    .scaleEffect(checkScale)
                    .opacity(checkOpacity)

                // Text content
                Text(primaryText)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.panelTextPrimary)
                    .opacity(textOpacity)

                Spacer()

                // Action buttons (visible after text fades in)
                HStack(spacing: 4) {
                    // Copy button
                    if let onCopy = onCopyTranscript {
                        Button(action: {
                            onCopy()
                            withAnimation(.snappy(duration: 0.15)) { showCopiedCheck = true }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                withAnimation(.snappy(duration: 0.15)) { showCopiedCheck = false }
                            }
                        }) {
                            ZStack {
                                Circle()
                                    .fill(isCopyHovered ? Color.panelCharcoalSurface : Color.clear)
                                    .frame(width: 28, height: 28)

                                Image(systemName: showCopiedCheck ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(showCopiedCheck ? .statusSuccessMuted : .panelTextSecondary)
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                        .onHover { hovering in isCopyHovered = hovering }
                        .help("Copy transcript")
                    }

                    // Open button
                    if let url = transcriptURL {
                        Button(action: {
                            NSWorkspace.shared.open(url)
                        }) {
                            ZStack {
                                Circle()
                                    .fill(isOpenHovered ? Color.panelCharcoalSurface : Color.clear)
                                    .frame(width: 28, height: 28)

                                Image(systemName: "arrow.up.forward.app")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.panelTextSecondary)
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                        .onHover { hovering in isOpenHovered = hovering }
                        .help("Open transcript")
                    }
                }
                .opacity(textOpacity)
            }
            .padding(.horizontal, 12)
        }
        .frame(width: width, height: height)
        .onHover { hovering in isHovered = hovering }
        .onAppear {
            animateSuccess()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    // MARK: - Text Content

    private var primaryText: String {
        return "Saved"
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
        return "Transcript saved."
    }

    // MARK: - Hover State (for parent to pause auto-dismiss)

    var isPillHovered: Bool { isHovered }
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
                AuroraSuccessView(
                    successType: .transcriptSaved,
                    transcriptURL: URL(fileURLWithPath: "/tmp/test.md"),
                    onCopyTranscript: {}
                )
            }
        }
        .frame(width: 300, height: 300)
    }
}
#endif
