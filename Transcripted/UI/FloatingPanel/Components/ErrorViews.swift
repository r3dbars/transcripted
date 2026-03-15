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

// MARK: - Contextual Error Type (UX Law: Provide actionable guidance)

/// Error types with icons and recovery actions for better user guidance
enum ContextualError: Equatable {
    case microphoneError(message: String)
    case transcriptionFailed(message: String)
    case networkError(message: String)
    case storageFull(message: String)
    case permissionDenied(message: String)
    case unknown(message: String)

    /// Parse an error message and return the appropriate ContextualError type
    static func from(message: String) -> ContextualError {
        let lowercased = message.lowercased()

        if lowercased.contains("microphone") || lowercased.contains("audio input") || lowercased.contains("mic") {
            return .microphoneError(message: message)
        } else if lowercased.contains("speech") || lowercased.contains("transcri") || lowercased.contains("recognition") {
            return .transcriptionFailed(message: message)
        } else if lowercased.contains("network") || lowercased.contains("connection") || lowercased.contains("internet") || lowercased.contains("offline") {
            return .networkError(message: message)
        } else if lowercased.contains("disk") || lowercased.contains("storage") || lowercased.contains("space") || lowercased.contains("full") {
            return .storageFull(message: message)
        } else if lowercased.contains("permission") || lowercased.contains("denied") || lowercased.contains("access") {
            return .permissionDenied(message: message)
        } else {
            return .unknown(message: message)
        }
    }

    var icon: String {
        switch self {
        case .microphoneError: return "mic.slash.fill"
        case .transcriptionFailed: return "waveform.badge.exclamationmark"
        case .networkError: return "wifi.exclamationmark"
        case .storageFull: return "externaldrive.badge.xmark"
        case .permissionDenied: return "lock.shield.fill"
        case .unknown: return "exclamationmark.triangle.fill"
        }
    }

    var title: String {
        switch self {
        case .microphoneError: return "Microphone Error"
        case .transcriptionFailed: return "Transcription Failed"
        case .networkError: return "Connection Lost"
        case .storageFull: return "Storage Full"
        case .permissionDenied: return "Permission Denied"
        case .unknown: return "Error"
        }
    }

    var recoveryHint: String {
        switch self {
        case .microphoneError: return "Check microphone in Settings"
        case .transcriptionFailed: return "Tap to retry"
        case .networkError: return "Check internet connection"
        case .storageFull: return "Free up disk space"
        case .permissionDenied: return "Grant access in System Settings"
        case .unknown: return "Try again"
        }
    }

    var color: Color {
        switch self {
        case .microphoneError, .permissionDenied:
            return .statusWarningMuted  // Amber for permission issues
        case .networkError, .storageFull:
            return .statusWarningMuted  // Amber for recoverable issues
        case .transcriptionFailed, .unknown:
            return .statusErrorMuted    // Red for errors
        }
    }
}

// MARK: - Contextual Error Banner View

/// A more informative error banner with icon, title, and recovery action
@available(macOS 14.0, *)
struct ContextualErrorBanner: View {
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    let error: ContextualError
    let onTap: (() -> Void)?

    @State private var isVisible = false
    @State private var isShaking = false

    init(error: ContextualError, onTap: (() -> Void)? = nil) {
        self.error = error
        self.onTap = onTap
    }

    var body: some View {
        Button(action: { onTap?() }) {
            HStack(spacing: 10) {
                // Icon with background
                ZStack {
                    Circle()
                        .fill(error.color.opacity(0.15))
                        .frame(width: 32, height: 32)

                    Image(systemName: error.icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(error.color)
                }

                // Text content
                VStack(alignment: .leading, spacing: 2) {
                    Text(error.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.textOnCream)

                    Text(error.recoveryHint)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.textOnCreamMuted)
                }

                Spacer()

                // Chevron if tappable
                if onTap != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.textOnCreamMuted)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: Radius.lawsCard, style: .continuous)
                    .fill(Color.surfaceCard)
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.lawsCard, style: .continuous)
                            .stroke(error.color.opacity(0.3), lineWidth: 1)
                    )
            )
            .shadow(
                color: error.color.opacity(0.15),
                radius: 8,
                y: 4
            )
        }
        .buttonStyle(PlainButtonStyle())
        .hoverScale(1.01)
        .shake(when: isShaking)
        .offset(y: isVisible ? 0 : 20)
        .opacity(isVisible ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                isVisible = true
            }
            // Brief shake to draw attention
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if !reduceMotion {
                    isShaking = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        isShaking = false
                    }
                }
            }
        }
    }
}
