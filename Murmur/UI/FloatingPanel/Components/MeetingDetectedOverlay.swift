import SwiftUI

// MARK: - Meeting Detected Overlay
/// Non-intrusive prompt that appears when a meeting is detected
/// Shows amber glow background with "Meeting detected" and highlighted Record button
/// Auto-dismisses after 10 seconds, tap anywhere to dismiss

@available(macOS 26.0, *)
struct MeetingDetectedOverlay: View {
    let onRecord: () -> Void
    let onDismiss: () -> Void

    @State private var autoDismissTask: Task<Void, Never>?
    @State private var glowOpacity: Double = 0.3
    @State private var isHoveringRecord: Bool = false

    private let width: CGFloat = 220
    private let height: CGFloat = 44

    var body: some View {
        ZStack {
            // Amber glow background
            amberBackground
                .clipShape(Capsule())

            HStack(spacing: 12) {
                // Meeting indicator icon
                Image(systemName: "person.2.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.statusWarningMuted)

                Text("Meeting detected")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.panelTextPrimary)

                Spacer()

                // Record button (highlighted with coral accent)
                Button(action: {
                    onRecord()
                }) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.recordingCoral)
                            .frame(width: 8, height: 8)
                        Text("Record")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.panelTextPrimary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(Color.recordingCoral.opacity(isHoveringRecord ? 0.35 : 0.2))
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.recordingCoral.opacity(0.5), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isHoveringRecord = hovering
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(width: width, height: height)
        .onAppear {
            startAutoDismiss()
            startGlowAnimation()
        }
        .onDisappear {
            autoDismissTask?.cancel()
        }
        .contentShape(Capsule())
        .onTapGesture {
            // Tap anywhere (except Record button) to dismiss
            onDismiss()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Meeting detected. Tap Record to start recording, or tap to dismiss.")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Amber Background

    private var amberBackground: some View {
        ZStack {
            // Base dark background
            Color.panelCharcoal

            // Warm amber radial glow (pulsing)
            RadialGradient(
                colors: [
                    Color.statusWarningMuted.opacity(glowOpacity),
                    Color.statusWarningMuted.opacity(glowOpacity * 0.3),
                    Color.clear
                ],
                center: .leading,
                startRadius: 0,
                endRadius: 150
            )
        }
        .overlay(
            Capsule()
                .strokeBorder(Color.statusWarningMuted.opacity(0.4), lineWidth: 1.5)
        )
        .shadow(color: Color.statusWarningMuted.opacity(0.2), radius: 12, y: 0)
    }

    // MARK: - Auto Dismiss

    private func startAutoDismiss() {
        autoDismissTask = Task {
            try? await Task.sleep(for: .seconds(10))
            if !Task.isCancelled {
                await MainActor.run {
                    onDismiss()
                }
            }
        }
    }

    // MARK: - Glow Animation

    private func startGlowAnimation() {
        withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
            glowOpacity = 0.5
        }
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
