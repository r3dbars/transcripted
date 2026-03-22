import SwiftUI

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
