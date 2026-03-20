import SwiftUI

/// Model Setup step - Downloads and initializes AI models
/// Shows progress for Parakeet (STT) and Sortformer (diarization)
/// Aesthetic: Warm, reassuring progress indicators matching onboarding style
@available(macOS 26.0, *)
struct ModelSetupStep: View {
    @Bindable var state: OnboardingState

    @State private var titleOpacity: Double = 0
    @State private var titleOffset: CGFloat = 10
    @State private var card1Appeared: Bool = false
    @State private var card2Appeared: Bool = false

    var body: some View {
        VStack(spacing: Spacing.lg) {
            // Header
            VStack(spacing: Spacing.sm) {
                Text("Setting Up AI Models")
                    .font(.displayMedium)
                    .foregroundColor(.charcoal)

                Text("Downloading speech recognition models for local use")
                    .font(.bodyLarge)
                    .foregroundColor(.softCharcoal)
            }
            .opacity(titleOpacity)
            .offset(y: titleOffset)
            .padding(.top, Spacing.lg)

            // Model download cards
            VStack(spacing: Spacing.md) {
                ModelDownloadCard(
                    icon: "waveform",
                    title: "Speech Recognition",
                    description: "Parakeet TDT V3 — converts speech to text",
                    isReady: state.parakeetReady,
                    isLoading: state.isLoadingModels && !state.parakeetReady,
                    loadingText: "Downloading speech models (~600 MB)..."
                )
                .offset(x: card1Appeared ? 0 : 40)
                .opacity(card1Appeared ? 1 : 0)

                ModelDownloadCard(
                    icon: "person.2.fill",
                    title: "Speaker Diarization",
                    description: "PyAnnote — identifies who said what",
                    isReady: state.diarizationReady,
                    isLoading: state.isLoadingModels && !state.diarizationReady,
                    loadingText: "Downloading diarization models..."
                )
                .offset(x: card2Appeared ? 0 : 40)
                .opacity(card2Appeared ? 1 : 0)
            }
            .padding(.horizontal, Spacing.lg)

            Spacer()

            // Error state with retry
            if let error = state.modelError, !state.isLoadingModels {
                VStack(spacing: Spacing.sm) {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.recordingRed)
                        Text(error)
                            .font(.bodySmall)
                            .foregroundColor(.softCharcoal)
                            .multilineTextAlignment(.center)
                    }

                    PremiumButton(
                        title: "Retry Download",
                        icon: "arrow.clockwise",
                        variant: .secondary
                    ) {
                        Task { await state.loadModels() }
                    }
                }
                .padding(.horizontal, Spacing.xxl)
                .transition(.opacity)
            }

            // Info text
            if !state.modelsReady && state.modelError == nil {
                VStack(spacing: Spacing.xs) {
                    Text("Everything runs 100% on your Mac")
                        .font(.bodySmall)
                        .foregroundColor(.softCharcoal)

                    Text("No cloud APIs, no internet required after setup")
                        .font(.caption)
                        .foregroundColor(.softCharcoal.opacity(0.7))

                    Text("English only · macOS 14.2+ · 16 GB RAM recommended")
                        .font(.caption)
                        .foregroundColor(.softCharcoal.opacity(0.5))
                }
                .padding(.bottom, Spacing.lg)
            }

            // Success message
            if state.modelsReady {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.successGreen)
                    Text("Models ready — everything runs locally on your Mac")
                        .font(.bodyMedium)
                        .foregroundColor(.charcoal)
                }
                .padding(Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: Radius.lg)
                        .fill(Color.successGreen.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.lg)
                        .strokeBorder(Color.successGreen.opacity(0.2), lineWidth: 1)
                )
                .padding(.horizontal, Spacing.xxl)
                .padding(.bottom, Spacing.lg)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.95)),
                    removal: .opacity
                ))
            }
        }
        .onAppear {
            animateIn()
            // Start loading models if not already done
            if !state.modelsReady && !state.isLoadingModels {
                Task { await state.loadModels() }
            }
        }
    }

    private func animateIn() {
        withAnimation(.smooth.delay(0.1)) {
            titleOpacity = 1.0
            titleOffset = 0
        }
        withAnimation(.smooth.delay(0.25)) {
            card1Appeared = true
        }
        withAnimation(.smooth.delay(0.4)) {
            card2Appeared = true
        }
    }
}

// MARK: - Model Download Card

@available(macOS 26.0, *)
private struct ModelDownloadCard: View {
    let icon: String
    let title: String
    let description: String
    let isReady: Bool
    let isLoading: Bool
    let loadingText: String

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: Spacing.md) {
            // Status icon
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.12))
                    .frame(width: 44, height: 44)

                if isReady {
                    Image(systemName: "checkmark")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.successGreen)
                } else if isLoading {
                    ProgressView()
                        .scaleEffect(0.8)
                        .tint(.terracotta)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.softCharcoal)
                }
            }

            // Text
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.bodyMedium)
                    .fontWeight(.semibold)
                    .foregroundColor(.charcoal)

                Text(description)
                    .font(.bodySmall)
                    .foregroundColor(.softCharcoal)

                if isLoading {
                    Text(loadingText)
                        .font(.caption)
                        .foregroundColor(.terracotta)
                } else if isReady {
                    Text("Ready")
                        .font(.caption)
                        .foregroundColor(.successGreen)
                }
            }

            Spacer()
        }
        .padding(Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Radius.lg)
                .fill(isReady ? Color.successGreen.opacity(0.04) : Color.warmCream)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.lg)
                .strokeBorder(
                    isReady ? Color.successGreen.opacity(0.2) :
                    isLoading ? Color.terracotta.opacity(0.2) :
                    Color.terracotta.opacity(0.1),
                    lineWidth: 1
                )
        )
        .scaleEffect(isHovered ? 1.01 : 1.0)
        .animation(.smooth, value: isHovered)
        .animation(.smooth, value: isReady)
        .onHover { isHovered = $0 }
    }

    private var statusColor: Color {
        if isReady { return .successGreen }
        if isLoading { return .terracotta }
        return .softCharcoal.opacity(0.5)
    }
}

// MARK: - Preview

#if DEBUG
@available(macOS 26.0, *)
#Preview("Loading") {
    let state = OnboardingState()
    state.isLoadingModels = true
    return ModelSetupStep(state: state)
        .frame(width: 720, height: 680)
        .background(Color.cream)
}

@available(macOS 26.0, *)
#Preview("Ready") {
    let state = OnboardingState()
    state.parakeetReady = true
    state.diarizationReady = true
    return ModelSetupStep(state: state)
        .frame(width: 720, height: 680)
        .background(Color.cream)
}

@available(macOS 26.0, *)
#Preview("Error") {
    let state = OnboardingState()
    state.modelError = "Network connection failed"
    return ModelSetupStep(state: state)
        .frame(width: 720, height: 680)
        .background(Color.cream)
}
#endif
