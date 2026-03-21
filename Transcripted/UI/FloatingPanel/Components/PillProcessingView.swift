import SwiftUI

// MARK: - Pill Processing View (180x40px - Status indicator)

/// Shown during transcription/processing
/// Displays status with icon and animated dots
@available(macOS 14.0, *)
struct PillProcessingView: View {
    let status: DisplayStatus

    var body: some View {
        ZStack {
            // Solid dark background
            Capsule()
                .fill(Color.panelCharcoal)
                .overlay(
                    Capsule()
                        .strokeBorder(Color.processingPurple.opacity(0.4), lineWidth: 1)
                )

            HStack(spacing: 10) {
                // Status icon with spinning animation for processing states
                Image(systemName: status.icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(statusColor)
                    .symbolEffect(.pulse, options: .repeating, isActive: status.isProcessing)

                // Status text with animated dots
                HStack(spacing: 0) {
                    Text(status.statusText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.panelTextPrimary)

                    if status.isProcessing {
                        AnimatedDotsView()
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(width: PillDimensions.recordingWidth, height: PillDimensions.recordingHeight)
        .accessibilityLabel(status.statusText)
    }

    private var statusColor: Color {
        switch status {
        case .gettingReady, .transcribing, .finishing:
            return .statusProcessingMuted
        case .transcriptSaved:
            return .statusSuccessMuted
        case .failed:
            return .statusErrorMuted
        default:
            return .panelTextSecondary
        }
    }
}
