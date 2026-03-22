import SwiftUI
import AVFoundation

/// Permissions step — request microphone and screen recording access
/// Dark theme, minimal card design matching the product
@available(macOS 26.0, *)
struct PermissionsStep: View {
    @Bindable var state: OnboardingState

    var body: some View {
        VStack(spacing: Spacing.lg) {
            // Header
            VStack(spacing: Spacing.sm) {
                Text("Quick Permissions")
                    .font(.displayMedium)
                    .foregroundColor(.panelTextPrimary)

                Text("We need a couple of permissions to get started")
                    .font(.bodyLarge)
                    .foregroundColor(.panelTextSecondary)
            }
            .padding(.top, Spacing.lg)

            // Permission cards
            VStack(spacing: Spacing.md) {
                PermissionCard(
                    icon: "mic.fill",
                    title: "Microphone Access",
                    description: "For recording your conversations",
                    status: mapStatus(
                        avStatus: state.microphoneStatus,
                        isLoading: state.isMicrophoneRequestInProgress
                    ),
                    onGrant: {
                        Task {
                            await state.requestMicrophonePermission()
                        }
                    },
                    onOpenSettings: {
                        state.openMicrophoneSettings()
                    }
                )

                PermissionCard(
                    icon: "rectangle.inset.filled.and.person.filled",
                    title: "Screen Recording",
                    description: "For capturing meeting audio from Zoom, Teams, and other apps",
                    status: state.screenRecordingGranted ? .granted : .notRequested,
                    onGrant: {
                        state.requestScreenRecordingPermission()
                    },
                    onOpenSettings: {
                        state.openScreenRecordingSettings()
                    }
                )
            }
            .padding(.horizontal, Spacing.lg)

            Spacer()
        }
        .onAppear {
            state.checkPermissions()
        }
    }

    private func mapStatus(avStatus: AVAuthorizationStatus, isLoading: Bool) -> PermissionStatus {
        if isLoading { return .pending }
        switch avStatus {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notRequested
        @unknown default: return .notRequested
        }
    }
}

// MARK: - Permission Status

@available(macOS 26.0, *)
private enum PermissionStatus {
    case notRequested, pending, granted, denied
}

// MARK: - Permission Card

@available(macOS 26.0, *)
private struct PermissionCard: View {
    let icon: String
    let title: String
    let description: String
    let status: PermissionStatus
    let onGrant: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: Spacing.lg) {
            // Status icon
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.15))
                    .frame(width: 48, height: 48)

                Image(systemName: statusIcon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(statusColor)
                    .symbolEffect(.pulse, options: .repeating, isActive: status == .pending)
            }

            // Text
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(title)
                    .font(.headingMedium)
                    .foregroundColor(.panelTextPrimary)

                Text(description)
                    .font(.bodySmall)
                    .foregroundColor(.panelTextSecondary)
                    .lineLimit(2)
            }

            Spacer()

            // Action button
            actionButton
        }
        .padding(Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: Radius.lg)
                .fill(Color.panelCharcoalElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.lg)
                .strokeBorder(Color.panelCharcoalSurface, lineWidth: 1)
        )
        .animation(.smooth, value: status)
    }

    private var statusColor: Color {
        switch status {
        case .notRequested: return .terracotta
        case .pending: return .processingPurple
        case .granted: return .successGreen
        case .denied: return .errorCoral
        }
    }

    private var statusIcon: String {
        switch status {
        case .notRequested: return icon
        case .pending: return "hourglass"
        case .granted: return "checkmark.circle.fill"
        case .denied: return "xmark.circle.fill"
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch status {
        case .notRequested:
            PremiumButton(title: "Grant", variant: .primary) {
                onGrant()
            }

        case .pending:
            ProgressView()
                .scaleEffect(0.8)
                .frame(width: 80)

        case .granted:
            HStack(spacing: Spacing.xs) {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                Text("Granted")
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .foregroundColor(.successGreen)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background(Color.successGreen.opacity(0.15))
            .clipShape(Capsule())

        case .denied:
            PremiumButton(title: "Settings", icon: "gear", variant: .secondary) {
                onOpenSettings()
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
@available(macOS 26.0, *)
#Preview {
    PermissionsStep(state: OnboardingState())
        .frame(width: 560, height: 520)
        .background(Color.panelCharcoal)
}
#endif
