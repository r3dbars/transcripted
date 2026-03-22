import SwiftUI

// MARK: - Toast Notification View (Phase 6 Polish - Brief Error Notifications)

/// Slides in from bottom, shows error with context, auto-dismisses
/// Design: Solid dark panel style matching the pill theme
@available(macOS 14.0, *)
struct ToastNotificationView: View {
    let error: ContextualError
    @Binding var isVisible: Bool

    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State private var isShown = false
    @State private var isHovered = false
    @State private var dismissTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 10) {
            // Icon with colored background circle
            ZStack {
                Circle()
                    .fill(error.color.opacity(0.2))
                    .frame(width: 28, height: 28)

                Image(systemName: error.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(error.color)
            }

            // Text content
            VStack(alignment: .leading, spacing: 2) {
                Text(error.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.panelTextPrimary)
                    .lineLimit(1)

                Text(error.recoveryHint)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.panelTextSecondary)
                    .lineLimit(1)
            }

            Spacer()

            // Dismiss button
            Button(action: { dismissToast() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.panelTextMuted)
                    .padding(5)
                    .background(Circle().fill(Color.panelCharcoalElevated))
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(Color.panelCharcoal)
                .overlay(
                    Capsule()
                        .strokeBorder(error.color.opacity(0.4), lineWidth: 1)
                )
        )
        .shadow(color: error.color.opacity(0.2), radius: 8, y: 2)
        .shadow(color: Color.black.opacity(0.3), radius: 4, y: 2)
        .frame(width: PillDimensions.recordingWidth + 60)
        .offset(y: isShown ? 0 : 50)
        .opacity(isShown ? 1 : 0)
        .onAppear {
            performAnimateIn()
        }
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                // Pause auto-dismiss while user is reading
                dismissTask?.cancel()
            } else {
                // Resume auto-dismiss when mouse leaves
                scheduleDismiss()
            }
        }
        .accessibilityLabel("Error: \(error.title)")
        .accessibilityHint(error.recoveryHint)
    }

    private func performAnimateIn() {
        // Slide in
        withAnimation(reduceMotion ? .none : .spring(response: 0.3, dampingFraction: 0.8)) {
            isShown = true
        }

        // Schedule auto-dismiss
        scheduleDismiss()
    }

    private func scheduleDismiss() {
        dismissTask?.cancel()
        dismissTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(PillAnimationTiming.toastDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                dismissToast()
            }
        }
    }

    private func dismissToast() {
        dismissTask?.cancel()
        withAnimation(reduceMotion ? .none : .easeOut(duration: 0.2)) {
            isShown = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            isVisible = false
        }
    }
}
