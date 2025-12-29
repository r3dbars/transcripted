import SwiftUI

// MARK: - Premium Button

/// A refined button component with hover effects, shadows, and terracotta accent
@available(macOS 26.0, *)
struct PremiumButton: View {
    enum ButtonVariant {
        case primary    // Filled terracotta
        case secondary  // Outlined
        case ghost      // Text only
    }

    let title: String
    var icon: String? = nil
    var variant: ButtonVariant = .primary
    var isLoading: Bool = false
    var isDisabled: Bool = false
    let action: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        Button(action: {
            if !isDisabled && !isLoading {
                action()
            }
        }) {
            HStack(spacing: Spacing.sm) {
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 16, height: 16)
                } else if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .symbolEffect(.scale.up, isActive: isHovered)
                }

                Text(title)
                    .font(.buttonText)
                    .tracking(0.3)
            }
            .foregroundColor(foregroundColor)
            .padding(.vertical, 14)
            .padding(.horizontal, Spacing.lg)
            .frame(minWidth: 120)
            .background(backgroundView)
            .clipShape(RoundedRectangle(cornerRadius: Radius.md))
            .overlay(borderOverlay)
            .shadow(
                color: shadowColor,
                radius: isHovered ? 16 : 8,
                x: 0,
                y: isHovered ? 6 : 2
            )
            .scaleEffect(isPressed ? 0.97 : 1.0)
            .opacity(isDisabled ? 0.5 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.snappy) {
                isHovered = hovering
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !isPressed {
                        withAnimation(.snappy) {
                            isPressed = true
                        }
                    }
                }
                .onEnded { _ in
                    withAnimation(.snappy) {
                        isPressed = false
                    }
                }
        )
        .disabled(isDisabled || isLoading)
    }

    private var foregroundColor: Color {
        switch variant {
        case .primary:
            return .white
        case .secondary, .ghost:
            return isHovered ? .terracottaHover : .terracotta
        }
    }

    @ViewBuilder
    private var backgroundView: some View {
        switch variant {
        case .primary:
            ZStack {
                Color.terracotta
                // Subtle highlight gradient
                LinearGradient.buttonHighlight
            }
        case .secondary:
            Color.clear
        case .ghost:
            Color.terracotta.opacity(isHovered ? 0.08 : 0)
        }
    }

    @ViewBuilder
    private var borderOverlay: some View {
        switch variant {
        case .primary:
            EmptyView()
        case .secondary:
            RoundedRectangle(cornerRadius: Radius.md)
                .strokeBorder(
                    isHovered ? Color.terracottaHover : Color.terracotta,
                    lineWidth: 1.5
                )
        case .ghost:
            EmptyView()
        }
    }

    private var shadowColor: Color {
        guard !isDisabled else { return .clear }
        switch variant {
        case .primary:
            return isHovered ? Color.terracotta.opacity(0.35) : Color.black.opacity(0.08)
        case .secondary, .ghost:
            return .clear
        }
    }
}

// MARK: - Premium Card

/// An elegant card container with hover lift effect
@available(macOS 26.0, *)
struct PremiumCard<Content: View>: View {
    @ViewBuilder let content: Content
    var accentColor: Color = .terracotta
    var enableHover: Bool = true

    @State private var isHovered = false

    var body: some View {
        content
            .padding(Spacing.lg)
            .background(Color.warmCream)
            .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.lg)
                    .strokeBorder(
                        accentColor.opacity(isHovered ? 0.25 : 0.08),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: .black.opacity(isHovered ? 0.1 : 0.05),
                radius: isHovered ? 20 : 12,
                x: 0,
                y: isHovered ? 8 : 4
            )
            .scaleEffect(enableHover && isHovered ? 1.02 : 1.0)
            .animation(.smooth, value: isHovered)
            .onHover { hovering in
                if enableHover {
                    isHovered = hovering
                }
            }
    }
}

// MARK: - Benefit Card (for Value Prop)

/// A specialized card for displaying benefits with icon and text
@available(macOS 26.0, *)
struct BenefitCard: View {
    let icon: String
    let iconColor: Color
    let title: String
    let description: String

    @State private var isHovered = false
    @State private var glowOpacity: Double = 0

    var body: some View {
        HStack(spacing: Spacing.lg) {
            // Icon with glow
            ZStack {
                // Glow effect
                Circle()
                    .fill(iconColor.opacity(0.2))
                    .frame(width: 64, height: 64)
                    .blur(radius: 16)
                    .opacity(glowOpacity)

                // Icon background
                Circle()
                    .fill(iconColor.opacity(0.12))
                    .frame(width: 56, height: 56)

                // Icon
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundColor(iconColor)
                    .symbolEffect(.bounce, value: isHovered)
            }
            .animation(.smooth, value: isHovered)

            // Text content
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(title)
                    .font(.headingMedium)
                    .foregroundColor(.charcoal)

                Text(description)
                    .font(.bodyMedium)
                    .foregroundColor(.softCharcoal)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(Spacing.lg)
        .background(
            ZStack {
                Color.warmCream

                // Hover gradient
                LinearGradient(
                    colors: [iconColor.opacity(isHovered ? 0.06 : 0), Color.clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.lg)
                .strokeBorder(
                    iconColor.opacity(isHovered ? 0.25 : 0.1),
                    lineWidth: 1
                )
        )
        .shadow(
            color: iconColor.opacity(isHovered ? 0.15 : 0.05),
            radius: isHovered ? 16 : 8,
            x: 0,
            y: isHovered ? 6 : 2
        )
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.smooth, value: isHovered)
        .onHover { hovering in
            isHovered = hovering
            withAnimation(.smooth) {
                glowOpacity = hovering ? 1 : 0
            }
        }
    }
}

// MARK: - Step Progress Indicator

/// Capsule-based progress indicator that expands for the current step
@available(macOS 26.0, *)
struct StepProgressIndicator: View {
    let currentStep: Int
    let totalSteps: Int

    var body: some View {
        HStack(spacing: Spacing.sm) {
            ForEach(0..<totalSteps, id: \.self) { index in
                Capsule()
                    .fill(fillColor(for: index))
                    .frame(
                        width: index == currentStep ? 28 : 10,
                        height: 10
                    )
                    .animation(.spring(response: 0.4, dampingFraction: 0.7), value: currentStep)
            }
        }
    }

    private func fillColor(for index: Int) -> Color {
        if index < currentStep {
            return .terracotta
        } else if index == currentStep {
            return .terracotta
        } else {
            return .terracotta.opacity(0.2)
        }
    }
}

// MARK: - Permission Card

/// Card for displaying permission status with grant/settings actions
@available(macOS 26.0, *)
struct PermissionCard: View {
    let icon: String
    let title: String
    let description: String
    let status: PermissionStatus
    let onGrant: () -> Void
    let onOpenSettings: () -> Void

    enum PermissionStatus {
        case notRequested
        case pending
        case granted
        case denied
    }

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: Spacing.lg) {
            // Status icon
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.12))
                    .frame(width: 48, height: 48)

                Image(systemName: statusIcon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(statusColor)
                    .symbolEffect(.pulse, options: .repeating, isActive: status == .pending)
            }

            // Text
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headingSmall)
                    .foregroundColor(.charcoal)

                Text(description)
                    .font(.bodySmall)
                    .foregroundColor(.softCharcoal)
            }

            Spacer()

            // Action button
            actionButton
        }
        .padding(Spacing.ml)
        .background(Color.warmCream)
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.lg)
                .strokeBorder(statusColor.opacity(0.2), lineWidth: 1)
        )
        .shadow(
            color: .black.opacity(isHovered ? 0.08 : 0.04),
            radius: isHovered ? 12 : 6,
            x: 0,
            y: isHovered ? 4 : 2
        )
        .onHover { isHovered = $0 }
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
            }
            .foregroundColor(.successGreen)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background(Color.successGreen.opacity(0.12))
            .clipShape(Capsule())
        case .denied:
            PremiumButton(title: "Open Settings", icon: "gear", variant: .secondary) {
                onOpenSettings()
            }
        }
    }
}

// MARK: - Quick Tip Row

/// A small tip item with icon and text
@available(macOS 26.0, *)
struct QuickTipRow: View {
    let icon: String
    let text: String
    var iconColor: Color = .terracotta

    var body: some View {
        HStack(spacing: Spacing.ms) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(iconColor)
                .frame(width: 24)

            Text(text)
                .font(.bodyMedium)
                .foregroundColor(.charcoal)

            Spacer()
        }
        .padding(.vertical, Spacing.sm)
    }
}

// MARK: - Animated Icon

/// An icon with optional glow and pulse effects
@available(macOS 26.0, *)
struct AnimatedIcon: View {
    let systemName: String
    var size: CGFloat = 64
    var color: Color = .terracotta
    var showGlow: Bool = true
    var isPulsing: Bool = false

    @State private var glowScale: CGFloat = 1.0

    var body: some View {
        ZStack {
            // Glow effect
            if showGlow {
                Circle()
                    .fill(color.opacity(0.2))
                    .frame(width: size * 1.5, height: size * 1.5)
                    .blur(radius: 20)
                    .scaleEffect(glowScale)
            }

            // Icon
            Image(systemName: systemName)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(
                    LinearGradient(
                        colors: [color, color.opacity(0.8)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .symbolEffect(.pulse, options: .repeating, isActive: isPulsing)
        }
        .onAppear {
            if showGlow {
                withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                    glowScale = 1.1
                }
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
@available(macOS 26.0, *)
#Preview("Premium Components") {
    ScrollView {
        VStack(spacing: 32) {
            // Buttons
            VStack(spacing: 16) {
                Text("Buttons").font(.headingLarge)
                PremiumButton(title: "Get Started", icon: "arrow.right") {}
                PremiumButton(title: "Secondary", variant: .secondary) {}
                PremiumButton(title: "Ghost", variant: .ghost) {}
                PremiumButton(title: "Loading", isLoading: true) {}
            }

            Divider()

            // Benefit Card
            VStack(spacing: 16) {
                Text("Benefit Card").font(.headingLarge)
                BenefitCard(
                    icon: "clock.fill",
                    iconColor: .terracotta,
                    title: "Reclaim Your Time",
                    description: "Stop scribbling notes. Start being present."
                )
            }

            Divider()

            // Progress Indicator
            VStack(spacing: 16) {
                Text("Progress Indicator").font(.headingLarge)
                StepProgressIndicator(currentStep: 2, totalSteps: 6)
            }

            Divider()

            // Permission Cards
            VStack(spacing: 16) {
                Text("Permission Cards").font(.headingLarge)
                PermissionCard(
                    icon: "mic.fill",
                    title: "Microphone",
                    description: "To capture your voice",
                    status: .notRequested,
                    onGrant: {},
                    onOpenSettings: {}
                )
                PermissionCard(
                    icon: "waveform",
                    title: "Speech Recognition",
                    description: "To understand your words",
                    status: .granted,
                    onGrant: {},
                    onOpenSettings: {}
                )
            }
        }
        .padding(32)
    }
    .frame(width: 500, height: 800)
    .background(Color.cream)
}
#endif
