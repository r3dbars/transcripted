import SwiftUI

// MARK: - Animated Dots View

/// Animated "..." that cycles through 1, 2, 3 dots
struct AnimatedDotsView: View {
    @State private var dotCount = 0
    let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(String(repeating: ".", count: dotCount + 1))
            .font(.system(size: 12, weight: .bold, design: .monospaced))
            .foregroundColor(.retroGreen)
            .shadow(color: .retroGreen.opacity(0.5), radius: 2)
            .frame(width: 24, alignment: .leading)
            .onReceive(timer) { _ in
                dotCount = (dotCount + 1) % 3
            }
    }
}

// MARK: - Laws of UX Button (Warm Minimalism)

struct LawsButton: View {
    let iconName: String
    let label: String
    let color: Color
    let isActive: Bool
    let action: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: iconName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(isActive ? color : color.opacity(0.8))

                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.textOnCream)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: Radius.lawsButton, style: .continuous)
                    .fill(isActive ? color.opacity(0.15) : Color.surfaceCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.lawsButton, style: .continuous)
                    .stroke(isActive ? color.opacity(0.4) : Color.accentBlue.opacity(0.1), lineWidth: 1)
            )
            .shadow(
                color: isHovered ? CardStyle.shadowHover.color : CardStyle.shadowSubtle.color,
                radius: isHovered ? CardStyle.shadowHover.radius : CardStyle.shadowSubtle.radius,
                x: 0,
                y: isHovered ? 2 : 1
            )
            .scaleEffect(isPressed ? 0.96 : (isHovered ? 1.02 : 1.0))
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(.lawsCardHover) {
                isHovered = hovering
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    withAnimation(.lawsTap) { isPressed = true }
                }
                .onEnded { _ in
                    withAnimation(.lawsTap) { isPressed = false }
                }
        )
    }
}

// MARK: - Laws of UX Status Text View

struct LawsStatusTextView: View {
    let status: DisplayStatus

    var body: some View {
        HStack(spacing: 6) {
            // Status icon
            Image(systemName: statusIcon)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(statusColor)

            Text(statusText)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.textOnCream)

            if showAnimatedDots {
                AnimatedDotsView()
            }
        }
    }

    private var statusText: String {
        // Use the computed statusText from DisplayStatus enum
        status.statusText
    }

    private var statusIcon: String {
        // Use the computed icon from DisplayStatus enum
        status.icon
    }

    private var statusColor: Color {
        switch status {
        case .idle:
            return .accentBlue
        case .preparing, .transcribing, .extractingActionItems, .saving:
            return .statusProcessingMuted
        case .transcriptSaved, .completed:
            return .statusSuccessMuted
        case .pendingReview:
            return .statusWarningMuted
        case .failed:
            return .statusErrorMuted
        }
    }

    private var showAnimatedDots: Bool {
        status.isProcessing
    }
}

// MARK: - Retro Colors (Used by AnimatedDotsView)

extension Color {
    static let retroGreen = Color(red: 0.2, green: 0.8, blue: 0.2)
}
