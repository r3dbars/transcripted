import SwiftUI
import AppKit

// MARK: - Attention Prompt View

/// Expandable prompt for notifications like "Start Recording?" or "Still Recording?"
/// Features animated green ring, shake animation, and auto-dismiss
struct AttentionPromptView: View {
    let promptType: AttentionPromptType
    let onPrimaryAction: () -> Void
    let onDismiss: () -> Void

    @State private var isVisible = false
    @State private var dismissProgress: CGFloat = 1.0

    private let autoDismissSeconds: Double = 10.0

    enum AttentionPromptType {
        case startRecording(appName: String)  // "Zoom opened - Record?"
        case stillRecording(duration: TimeInterval, silenceMinutes: Int)  // "Still recording? 2 min silence"

        var icon: String {
            switch self {
            case .startRecording: return "mic.fill"
            case .stillRecording: return "waveform.badge.exclamationmark"
            }
        }

        var title: String {
            switch self {
            case .startRecording(let appName): return "\(appName) Active"
            case .stillRecording: return "Still Recording?"
            }
        }

        var subtitle: String {
            switch self {
            case .startRecording: return "Start recording?"
            case .stillRecording(_, let minutes): return "\(minutes)m silence detected"
            }
        }

        var primaryButtonText: String {
            switch self {
            case .startRecording: return "Record"
            case .stillRecording: return "Stop"
            }
        }

        var secondaryButtonText: String {
            switch self {
            case .startRecording: return "Dismiss"
            case .stillRecording: return "Keep"
            }
        }
    }

    var body: some View {
        HStack(spacing: 16) {
            // Icon
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [Color.premiumCoral.opacity(0.2), Color.premiumCoral.opacity(0.05)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 36, height: 36)

                Image(systemName: promptType.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.premiumCoral)
            }

            // Text Content
            VStack(alignment: .leading, spacing: 2) {
                Text(promptType.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.softWhite)

                Text(promptType.subtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.panelTextSecondary)
            }

            Spacer()

            // Actions
            HStack(spacing: 8) {
                // Secondary (Dismiss)
                Button(action: {
                    withAnimation(.easeOut(duration: 0.2)) {
                        isVisible = false
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        onDismiss()
                    }
                }) {
                    Text(promptType.secondaryButtonText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.panelTextSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                        )
                }
                .buttonStyle(PlainButtonStyle())

                // Primary (Action)
                Button(action: {
                    onPrimaryAction()
                }) {
                    Text(promptType.primaryButtonText)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(LinearGradient(
                                    colors: [Color.premiumCoral, Color.premiumCoral.opacity(0.8)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ))
                                .shadow(color: Color.premiumCoral.opacity(0.3), radius: 8, x: 0, y: 4)
                        )
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(12)
        .background(
            ZStack {
                // Glass Background
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.glassBackground)
                    .background(
                        VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    )

                // Subtle Border
                RoundedRectangle(cornerRadius: 16, style: .continuous)
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
        // Entry Animation
        .offset(y: isVisible ? 0 : 20)
        .opacity(isVisible ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                isVisible = true
            }
            startDismissCountdown()
        }
    }

    private func startDismissCountdown() {
        DispatchQueue.main.asyncAfter(deadline: .now() + autoDismissSeconds) {
            withAnimation(.easeOut(duration: 0.3)) {
                isVisible = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                onDismiss()
            }
        }
    }
}

// MARK: - Visual Effect Blur

/// Helper for Glassmorphism effects using NSVisualEffectView
struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let visualEffectView = NSVisualEffectView()
        visualEffectView.material = material
        visualEffectView.blendingMode = blendingMode
        visualEffectView.state = .active
        return visualEffectView
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
