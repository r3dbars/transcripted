import SwiftUI

/// Main container view for the onboarding flow
/// Dark theme matching the product aesthetic, 2-step flow
@available(macOS 26.0, *)
struct OnboardingContainerView: View {
    @Bindable var state: OnboardingState
    let onComplete: () -> Void

    @State private var direction: TransitionDirection = .forward

    @Environment(\.accessibilityReduceMotion) var reduceMotion

    enum TransitionDirection {
        case forward, backward
    }

    var body: some View {
        ZStack {
            Color.panelCharcoal
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Main content area
                contentView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(reduceMotion ? .opacity : pageTransition)
                    .id(state.currentStep)
                    .animation(reduceMotion ? .none : .smooth, value: state.currentStep)

                // Navigation buttons
                navigationButtons
                    .padding(.horizontal, Spacing.xl)
                    .padding(.bottom, Spacing.sm)

                // Skip for now link
                skipForNowLink
                    .padding(.bottom, Spacing.lg)
            }
        }
        .frame(width: 560, height: 520)
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

    // MARK: - Page Transition

    private var pageTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(x: direction == .forward ? 20 : -20)),
            removal: .opacity.combined(with: .offset(x: direction == .forward ? -20 : 20))
        )
    }

    // MARK: - Content View

    @ViewBuilder
    private var contentView: some View {
        switch state.currentStep {
        case .permissions:
            PermissionsStep(state: state)
        case .modelSetup:
            ModelSetupStep(state: state)
        }
    }

    // MARK: - Navigation Buttons

    private var navigationButtons: some View {
        HStack {
            // Back button
            if !state.isFirstStep {
                Button(action: {
                    direction = .backward
                    withAnimation(reduceMotion ? .none : .smooth) {
                        state.goBack()
                    }
                }) {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Back")
                            .font(.bodyMedium)
                    }
                    .foregroundColor(.panelTextSecondary)
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.sm)
                    .background(Color.panelCharcoalSurface)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.leftArrow, modifiers: [])
                .transition(.opacity)
            }

            Spacer()

            // Continue/Finish button
            if state.isLastStep {
                PremiumButton(
                    title: "Start Using Transcripted",
                    icon: "arrow.right",
                    variant: .primary,
                    isDisabled: !state.modelsReady
                ) {
                    state.completeOnboarding()
                    onComplete()
                }
                .keyboardShortcut(.return, modifiers: [])
            } else {
                PremiumButton(
                    title: "Continue",
                    icon: "arrow.right",
                    variant: .primary,
                    isDisabled: !state.canProceed
                ) {
                    direction = .forward
                    withAnimation(reduceMotion ? .none : .smooth) {
                        state.advance()
                    }
                }
                .keyboardShortcut(.return, modifiers: [])
            }
        }
    }

    // MARK: - Skip For Now Link

    @State private var showSkipConfirmation = false

    private var skipForNowLink: some View {
        Group {
            if !state.isLastStep {
                Button(action: {
                    showSkipConfirmation = true
                }) {
                    Text("Skip for now")
                        .font(.caption)
                        .foregroundColor(.panelTextMuted)
                        .underline()
                }
                .buttonStyle(.plain)
                .alert("Skip Onboarding?", isPresented: $showSkipConfirmation) {
                    Button("Continue Setup", role: .cancel) { }
                    Button("Skip") {
                        state.completeOnboarding()
                        onComplete()
                    }
                } message: {
                    Text("You can access settings later from the menu bar icon.")
                }
            }
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
