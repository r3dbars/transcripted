import SwiftUI

/// Main container view for the onboarding flow
/// Dark theme matching the floating pill aesthetic
@available(macOS 26.0, *)
struct OnboardingContainerView: View {
    @Bindable var state: OnboardingState
    let onComplete: () -> Void

    var body: some View {
        ZStack {
            Color.panelCharcoal
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Progress dots
                progressDots
                    .padding(.top, Spacing.lg)

                // Main content area
                contentView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
                    .id(state.currentStep)
                    .animation(.easeInOut(duration: 0.3), value: state.currentStep)

                // Navigation buttons
                navigationButtons
                    .padding(.horizontal, Spacing.xl)
                    .padding(.bottom, Spacing.lg)
            }
        }
        .frame(width: 640, height: 560)
        .onAppear {
            state.checkPermissions()
        }
        .onChange(of: state.modelsReady) { _, ready in
            if ready && state.currentStep == .modelSetup {
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    state.completeOnboarding()
                    onComplete()
                }
            }
        }
    }

    // MARK: - Progress Dots

    private var progressDots: some View {
        HStack(spacing: 10) {
            ForEach(OnboardingState.OnboardingStep.allCases, id: \.rawValue) { step in
                Circle()
                    .fill(dotColor(for: step))
                    .frame(width: 8, height: 8)
                    .animation(.easeInOut(duration: 0.2), value: state.currentStep)
            }
        }
    }

    private func dotColor(for step: OnboardingState.OnboardingStep) -> Color {
        if step.rawValue <= state.currentStep.rawValue {
            return .recordingCoral
        } else {
            return .panelCharcoalSurface
        }
    }

    // MARK: - Content View

    @ViewBuilder
    private var contentView: some View {
        switch state.currentStep {
        case .welcome:
            WelcomeStep()
        case .preview:
            PreviewStep()
        case .permissions:
            PermissionsStep(state: state)
        case .modelSetup:
            ModelSetupStep(state: state)
        }
    }

    // MARK: - Navigation Buttons

    private var navigationButtons: some View {
        HStack {
            if !state.isFirstStep {
                Button(action: { state.goBack() }) {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Back")
                    }
                }
                .buttonStyle(.bordered)
                .tint(.panelTextSecondary)
                .controlSize(.regular)
                .keyboardShortcut(.leftArrow, modifiers: [])
            }

            Spacer()

            if state.isLastStep {
                Button(action: {
                    state.completeOnboarding()
                    onComplete()
                }) {
                    HStack(spacing: Spacing.xs) {
                        Text("Start Using Transcripted")
                        Image(systemName: "arrow.right")
                            .font(.system(size: 12, weight: .semibold))
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.recordingCoral)
                .controlSize(.large)
                .disabled(!state.modelsReady)
                .keyboardShortcut(.return, modifiers: [])
            } else {
                Button(action: { state.advance() }) {
                    HStack(spacing: Spacing.xs) {
                        Text(continueButtonText)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 12, weight: .semibold))
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.recordingCoral)
                .controlSize(.large)
                .disabled(!state.canProceed)
                .keyboardShortcut(.return, modifiers: [])
            }
        }
    }

    private var continueButtonText: String {
        switch state.currentStep {
        case .welcome: return "Get Started"
        case .preview: return "Continue"
        case .permissions: return "Continue"
        case .modelSetup: return state.modelsReady ? "Start Using Transcripted" : "Setting Up..."
        }
    }
}

// MARK: - Preview

#if DEBUG
@available(macOS 26.0, *)
#Preview {
    OnboardingContainerView(
        state: OnboardingState(),
        onComplete: {}
    )
    .background(Color.panelCharcoal)
}
#endif
