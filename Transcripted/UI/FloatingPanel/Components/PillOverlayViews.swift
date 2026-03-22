import SwiftUI

// MARK: - Failed Badge Overlay

/// Small red circle showing count of failed transcriptions
struct FailedBadgeOverlay: View {
    let count: Int

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.errorCoral)
                .frame(width: 14, height: 14)

            Text("\(min(count, 9))\(count > 9 ? "+" : "")")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white)
        }
        .shadow(color: Color.errorCoral.opacity(0.3), radius: 2)
    }
}

// MARK: - Recording Dot View (Pulsing red indicator)

/// Classic red recording dot with pulsing animation
@available(macOS 14.0, *)
struct RecordingDotView: View {
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State private var isPulsing = false

    private let dotSize: CGFloat = 10

    var body: some View {
        Circle()
            .fill(Color(hex: "#FF0000"))  // Pure red for recording
            .frame(width: dotSize, height: dotSize)
            .scaleEffect(isPulsing ? 1.1 : 0.9)
            .shadow(color: Color.red.opacity(0.5), radius: 4)
            .onAppear {
                if !reduceMotion {
                    startPulsing()
                }
            }
    }

    private func startPulsing() {
        withAnimation(
            .easeInOut(duration: 0.6)
            .repeatForever(autoreverses: true)
        ) {
            isPulsing = true
        }
    }
}

// MARK: - System Audio Warning Indicator

/// Warning indicator shown when system audio capture has issues
/// Shows amber warning for silence/failure, blue for reconnecting
@available(macOS 14.0, *)
struct SystemAudioWarningIndicator: View {
    let status: SystemAudioStatus
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State private var isPulsing = false

    var body: some View {
        ZStack {
            // Pulsing background
            Circle()
                .fill(fillColor.opacity(isPulsing ? 0.8 : 0.5))
                .frame(width: 18, height: 18)

            // Icon
            Image(systemName: iconName)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white)
        }
        .help(helpText)
        .onAppear {
            if !reduceMotion {
                startPulsing()
            }
        }
        .accessibilityLabel(helpText)
    }

    private var fillColor: Color {
        switch status {
        case .reconnecting:
            return .accentBlue
        case .silent, .failed:
            return .statusWarningMuted
        default:
            return .clear
        }
    }

    private var iconName: String {
        switch status {
        case .reconnecting:
            return "arrow.triangle.2.circlepath"
        case .silent:
            return "speaker.slash.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        default:
            return "speaker.fill"
        }
    }

    private var helpText: String {
        switch status {
        case .reconnecting:
            return "Reconnecting to audio device..."
        case .silent:
            return "System audio is silent - remote participants may not be captured"
        case .failed:
            return "System audio capture failed"
        default:
            return "System audio status"
        }
    }

    private func startPulsing() {
        withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
            isPulsing = true
        }
    }
}
