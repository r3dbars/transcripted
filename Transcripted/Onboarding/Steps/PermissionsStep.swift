import SwiftUI
import AVFoundation

/// Permissions step - Request microphone access
/// Features clear explanations and warm aesthetic
@available(macOS 26.0, *)
struct PermissionsStep: View {
    @Bindable var state: OnboardingState
    @State private var titleOpacity: Double = 0
    @State private var titleOffset: CGFloat = 10
    @State private var cardAppeared: Bool = false
    @State private var card2Appeared: Bool = false
    @State private var successPulse: Bool = false

    var body: some View {
        VStack(spacing: Spacing.lg) {
            // Header
            VStack(spacing: Spacing.sm) {
                Text("Quick Permissions")
                    .font(.displayMedium)
                    .foregroundColor(.charcoal)

                Text("We need a couple of permissions to get started")
                    .font(.bodyLarge)
                    .foregroundColor(.softCharcoal)
            }
            .opacity(titleOpacity)
            .offset(y: titleOffset)
            .padding(.top, Spacing.lg)

            // Permission cards
            VStack(spacing: Spacing.md) {
                // Microphone Permission (required)
                OnboardingPermissionCard(
                    icon: "mic.fill",
                    title: "Microphone Access",
                    description: "To hear your conversations and capture every word",
                    status: mapStatus(
                        avStatus: state.microphoneStatus,
                        isLoading: state.isMicrophoneRequestInProgress
                    ),
                    isRequired: true,
                    onGrant: {
                        Task {
                            await state.requestMicrophonePermission()
                        }
                    },
                    onOpenSettings: {
                        state.openMicrophoneSettings()
                    }
                )
                .offset(x: cardAppeared ? 0 : 40)
                .opacity(cardAppeared ? 1 : 0)

                // Screen Recording Permission (recommended for system audio)
                OnboardingPermissionCard(
                    icon: "rectangle.inset.filled.and.person.filled",
                    title: "Screen Recording",
                    description: "To capture meeting audio from Zoom, Teams, and other apps",
                    status: state.screenRecordingGranted ? .granted : .notRequested,
                    isRequired: false,
                    onGrant: {
                        state.requestScreenRecordingPermission()
                    },
                    onOpenSettings: {
                        state.openScreenRecordingSettings()
                    }
                )
                .offset(x: card2Appeared ? 0 : 40)
                .opacity(card2Appeared ? 1 : 0)
            }
            .padding(.horizontal, Spacing.lg)

            Spacer()

            // Success message when granted
            if state.allPermissionsGranted {
                SuccessMessage()
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.9)).combined(with: .move(edge: .bottom)),
                        removal: .opacity
                    ))
                    .padding(.bottom, Spacing.lg)
            }
            
            // "Continue without mic" link (only shown when mic is not granted)
            if !state.microphoneGranted {
                VStack(spacing: Spacing.xs) {
                    Text("You can grant microphone access anytime from the menu bar")
                        .font(.bodySmall)
                        .foregroundColor(.softCharcoal.opacity(0.7))
                    
                    Button(action: {
                        // User can proceed without granting
                        state.advance()
                    }) {
                        Text("Continue without mic")
                            .font(.bodyMedium)
                            .foregroundColor(.terracotta.opacity(0.9))
                            .underline()
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, Spacing.md)
            }
        }
        .onAppear {
            state.checkPermissions()
            animateIn()
        }
        .onChange(of: state.allPermissionsGranted) { _, granted in
            if granted {
                // Celebrate success
                withAnimation(.bouncy) {
                    successPulse = true
                }
            }
        }
    }

    private func animateIn() {
        // Title animation
        withAnimation(.smooth.delay(0.1)) {
            titleOpacity = 1.0
            titleOffset = 0
        }

        // Card animations (staggered)
        withAnimation(.smooth.delay(0.2)) {
            cardAppeared = true
        }
        withAnimation(.smooth.delay(0.35)) {
            card2Appeared = true
        }
    }

    // Map AVAuthorizationStatus to our PermissionStatus
    private func mapStatus(avStatus: AVAuthorizationStatus, isLoading: Bool) -> OnboardingPermissionStatus {
        if isLoading {
            return .pending
        }

        switch avStatus {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notRequested
        @unknown default: return .notRequested
        }
    }
}

// MARK: - Onboarding Permission Status

@available(macOS 26.0, *)
enum OnboardingPermissionStatus {
    case notRequested
    case pending
    case granted
    case denied
}

// MARK: - Onboarding Permission Card

@available(macOS 26.0, *)
private struct OnboardingPermissionCard: View {
    let icon: String
    let title: String
    let description: String
    let status: OnboardingPermissionStatus
    var isRequired: Bool = true
    let onGrant: () -> Void
    let onOpenSettings: () -> Void

    @State private var isHovered = false
    @State private var iconGlow: Double = 0

    var body: some View {
        HStack(spacing: Spacing.lg) {
            // Status icon with glow
            ZStack {
                // Glow effect
                Circle()
                    .fill(statusColor.opacity(0.2))
                    .frame(width: 64, height: 64)
                    .blur(radius: 12)
                    .opacity(iconGlow)

                // Icon background
                Circle()
                    .fill(statusColor.opacity(0.12))
                    .frame(width: 52, height: 52)

                // Icon
                Image(systemName: statusIcon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(statusColor)
                    .symbolEffect(.pulse, options: .repeating, isActive: status == .pending)
            }

            // Text
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.sm) {
                    Text(title)
                        .font(.headingMedium)
                        .foregroundColor(.charcoal)

                    Text(isRequired ? "Required" : "Recommended")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(isRequired ? .terracotta : .softCharcoal)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(isRequired ? Color.terracotta.opacity(0.12) : Color.softCharcoal.opacity(0.1))
                        )
                }

                Text(description)
                    .font(.bodyMedium)
                    .foregroundColor(.softCharcoal)
                    .lineLimit(2)
            }

            Spacer()

            // Action button
            actionButton
        }
        .padding(Spacing.lg)
        .background(
            ZStack {
                Color.warmCream

                // Hover gradient
                LinearGradient(
                    colors: [statusColor.opacity(isHovered ? 0.06 : 0), Color.clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.lg)
                .strokeBorder(statusColor.opacity(isHovered ? 0.25 : 0.12), lineWidth: 1)
        )
        .shadow(
            color: statusColor.opacity(isHovered ? 0.12 : 0.06),
            radius: isHovered ? 16 : 8,
            x: 0,
            y: isHovered ? 6 : 2
        )
        .scaleEffect(isHovered ? 1.01 : 1.0)
        .animation(.smooth, value: isHovered)
        .animation(.smooth, value: status)
        .onHover { hovering in
            isHovered = hovering
            withAnimation(.smooth) {
                iconGlow = hovering ? 1 : 0
            }
        }
    }

    private var statusColor: Color {
        switch status {
        case .notRequested:
            return .terracotta
        case .pending:
            return .processingPurple
        case .granted:
            return .successGreen
        case .denied:
            return .errorCoral
        }
    }

    private var statusIcon: String {
        switch status {
        case .notRequested:
            return icon
        case .pending:
            return "hourglass"
        case .granted:
            return "checkmark.circle.fill"
        case .denied:
            return "xmark.circle.fill"
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
            .background(Color.successGreen.opacity(0.12))
            .clipShape(Capsule())

        case .denied:
            PremiumButton(title: "Settings", icon: "gear", variant: .secondary) {
                onOpenSettings()
            }
        }
    }
}

// MARK: - Success Message

@available(macOS 26.0, *)
private struct SuccessMessage: View {
    @State private var checkmarkScale: CGFloat = 0.5
    @State private var textOpacity: Double = 0

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20))
                .foregroundColor(.successGreen)
                .scaleEffect(checkmarkScale)

            Text("All permissions granted!")
                .font(.headingSmall)
                .foregroundColor(.successGreen)
                .opacity(textOpacity)

            Text("Ready to continue.")
                .font(.bodyMedium)
                .foregroundColor(.softCharcoal)
                .opacity(textOpacity)
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
        .background(
            Capsule()
                .fill(Color.successGreen.opacity(0.1))
        )
        .onAppear {
            withAnimation(.bouncy.delay(0.1)) {
                checkmarkScale = 1.0
            }
            withAnimation(.smooth.delay(0.2)) {
                textOpacity = 1.0
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
@available(macOS 26.0, *)
#Preview {
    PermissionsStep(state: OnboardingState())
        .frame(width: 720, height: 680)
        .background(Color.cream)
}
#endif
