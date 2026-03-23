import SwiftUI
import AVFoundation

/// Permissions step - Request microphone and screen recording access
/// Dark theme with simple permission rows
@available(macOS 26.0, *)
struct PermissionsStep: View {
    @Bindable var state: OnboardingState
    @State private var appeared = false

    var body: some View {
        VStack(spacing: Spacing.lg) {
            Spacer()

            VStack(spacing: Spacing.sm) {
                Text("Quick Permissions")
                    .font(.displayMedium)
                    .foregroundColor(.panelTextPrimary)

                Text("We need a couple of permissions to get started")
                    .font(.bodyLarge)
                    .foregroundColor(.panelTextSecondary)
            }

            VStack(spacing: Spacing.sm) {
                PermissionRow(
                    icon: "mic.fill",
                    title: "Microphone Access",
                    description: "To hear your conversations and capture every word",
                    isRequired: true,
                    status: micStatus,
                    onGrant: {
                        Task { await state.requestMicrophonePermission() }
                    },
                    onOpenSettings: {
                        state.openMicrophoneSettings()
                    }
                )

                PermissionRow(
                    icon: "rectangle.inset.filled.and.person.filled",
                    title: "Screen Recording",
                    description: "To capture meeting audio from Zoom, Teams, and other apps",
                    isRequired: false,
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

            if state.microphoneStatus == .denied || state.microphoneStatus == .restricted {
                Text("Microphone access wasn't granted. Tap \"Try Again\" to see the permission prompt, or open Settings to enable it manually.")
                    .font(.bodySmall)
                    .foregroundColor(.panelTextSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Spacing.xxl)
                    .padding(.bottom, Spacing.md)
            }

            if state.microphoneGranted {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.attentionGreen)
                    Text("Ready to continue")
                        .font(.bodyMedium)
                        .foregroundColor(.attentionGreen)
                }
                .padding(.bottom, Spacing.md)
                .transition(.opacity)
            }
        }
        .opacity(appeared ? 1 : 0)
        .onAppear {
            state.checkPermissions()
            withAnimation(.easeInOut(duration: 0.3)) {
                appeared = true
            }
        }
    }

    private var micStatus: PermissionRowStatus {
        if state.isMicrophoneRequestInProgress { return .pending }
        switch state.microphoneStatus {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notRequested
        @unknown default: return .notRequested
        }
    }
}

// MARK: - Permission Row Status

enum PermissionRowStatus {
    case notRequested
    case pending
    case granted
    case denied
}

// MARK: - Permission Row

@available(macOS 26.0, *)
private struct PermissionRow: View {
    let icon: String
    let title: String
    let description: String
    let isRequired: Bool
    let status: PermissionRowStatus
    let onGrant: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: Spacing.md) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.12))
                    .frame(width: 44, height: 44)

                Image(systemName: statusIcon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(statusColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Spacing.xs) {
                    Text(title)
                        .font(.bodyMedium)
                        .fontWeight(.semibold)
                        .foregroundColor(.panelTextPrimary)

                    Text(isRequired ? "Required" : "Recommended")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(isRequired ? .recordingCoral : .panelTextMuted)
                }

                Text(description)
                    .font(.bodySmall)
                    .foregroundColor(.panelTextSecondary)
                    .lineLimit(2)
            }

            Spacer()

            actionView
        }
        .padding(Spacing.md)
        .background(Color.panelCharcoalElevated)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md)
                .strokeBorder(Color.panelCharcoalSurface, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var actionView: some View {
        switch status {
        case .notRequested:
            Button("Grant") { onGrant() }
                .buttonStyle(.bordered)
                .tint(.recordingCoral)
                .controlSize(.small)

        case .pending:
            ProgressView()
                .scaleEffect(0.7)
                .frame(width: 60)

        case .granted:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20))
                .foregroundColor(.attentionGreen)

        case .denied:
            HStack(spacing: 6) {
                Button("Try Again") { onGrant() }
                    .buttonStyle(.bordered)
                    .tint(.recordingCoral)
                    .controlSize(.small)
                Button("Settings") { onOpenSettings() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private var statusColor: Color {
        switch status {
        case .notRequested: return .recordingCoral
        case .pending: return .processingPurple
        case .granted: return .attentionGreen
        case .denied: return .errorRed
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
}

// MARK: - Preview

#if DEBUG
@available(macOS 26.0, *)
#Preview {
    PermissionsStep(state: OnboardingState())
        .frame(width: 640, height: 560)
        .background(Color.panelCharcoal)
}
#endif
