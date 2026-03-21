import SwiftUI

/// Coach mark callout that appears above the pill to introduce it to first-time users.
/// Features a downward-pointing arrow, glassmorphism background, and persists until dismissed.
@available(macOS 26.0, *)
struct PillCalloutView: View {
    let onDismiss: () -> Void

    @State private var isVisible = false
    @State private var arrowBounce = false

    var body: some View {
        VStack(spacing: 0) {
            // Callout bubble
            ZStack(alignment: .topTrailing) {
                HStack(spacing: 12) {
                    // Icon
                    ZStack {
                        Circle()
                            .fill(LinearGradient(
                                colors: [Color.premiumCoral.opacity(0.2), Color.premiumCoral.opacity(0.05)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ))
                            .frame(width: 36, height: 36)

                        Image(systemName: "mic.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.premiumCoral)
                    }

                    // Text
                    VStack(alignment: .leading, spacing: 4) {
                        Text("This is your recording pill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.softWhite)

                        Text("Click the mic to start recording. It lives here above your dock.")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundColor(.panelTextSecondary)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 20)
                }
                .padding(14)
                .padding(.trailing, 8) // Extra space for X button

                // X close button
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.panelTextSecondary)
                        .frame(width: 22, height: 22)
                        .background(
                            Circle()
                                .fill(Color.white.opacity(0.1))
                        )
                }
                .buttonStyle(PlainButtonStyle())
                .padding(8)
            }
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.glassBackground)
                        .background(
                            VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        )

                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.2), Color.white.opacity(0.05)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                }
            )
            .shadow(color: .black.opacity(0.3), radius: 12, y: 6)

            // Downward-pointing arrow (big, obvious, pulsing)
            Triangle()
                .rotation(.degrees(180))
                .fill(Color.panelCharcoal.opacity(0.85))
                .frame(width: 24, height: 14)
                .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                .offset(y: arrowBounce ? 4 : -1)
                .animation(
                    .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                    value: arrowBounce
                )
        }
        .frame(width: 320)
        .offset(y: isVisible ? 0 : 10)
        .opacity(isVisible ? 1 : 0)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Welcome tooltip: This is your recording pill. Click the mic to start recording. It lives here above your dock.")
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                isVisible = true
            }
            // Start arrow bounce after entry animation settles
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                arrowBounce = true
            }
        }
    }

    private func dismiss() {
        withAnimation(.easeOut(duration: 0.2)) {
            isVisible = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            onDismiss()
        }
    }
}
