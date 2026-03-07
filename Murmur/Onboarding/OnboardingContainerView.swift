import SwiftUI

/// Main container view for the onboarding flow
/// Features warm cream aesthetic, smooth transitions, and premium navigation
/// Aesthetic: Recording Studio Library - professional yet welcoming
@available(macOS 26.0, *)
struct OnboardingContainerView: View {
    @Bindable var state: OnboardingState
    let onComplete: () -> Void

    @State private var isTransitioning = false
    @State private var direction: TransitionDirection = .forward

    // Accessibility: Respect reduce motion preference
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    enum TransitionDirection {
        case forward, backward
    }

    var body: some View {
        ZStack {
            // Warm cream background
            Color.cream
                .ignoresSafeArea()

            // Subtle gradient overlay at top
            VStack {
                LinearGradient(
                    colors: [Color.terracotta.opacity(0.03), Color.clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 200)
                Spacer()
            }
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // Premium step indicator at top
                StepProgressIndicator(
                    currentStep: state.currentStep.rawValue,
                    totalSteps: state.totalSteps
                )
                .padding(.top, Spacing.lg)
                .padding(.horizontal, Spacing.xxl)

                // Main content area with transitions
                contentView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(reduceMotion ? .opacity : pageTransition)
                    .id(state.currentStep)
                    .animation(reduceMotion ? .none : .smooth, value: state.currentStep)

                // Navigation buttons
                navigationButtons
                    .padding(.horizontal, Spacing.xl)
                    .padding(.bottom, Spacing.sm)

                // Skip for now link (UX: Zeigarnik Effect - don't trap users)
                skipForNowLink
                    .padding(.bottom, Spacing.lg)
            }
        }
        .frame(width: 720, height: 680)
        .clipShape(RoundedRectangle(cornerRadius: Radius.xl))
        .shadow(color: .black.opacity(0.15), radius: 30, y: 10)
        .onAppear {
            state.checkPermissions()
        }
    }

    // MARK: - Page Transition

    private var pageTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity
                .combined(with: .offset(x: direction == .forward ? 30 : -30))
                .combined(with: .scale(scale: 0.98)),
            removal: .opacity
                .combined(with: .offset(x: direction == .forward ? -30 : 30))
                .combined(with: .scale(scale: 0.98))
        )
    }

    // MARK: - Content View

    @ViewBuilder
    private var contentView: some View {
        switch state.currentStep {
        case .welcome:
            WelcomeStep()
        case .howItWorks:
            HowItWorksStep()
        case .permissions:
            PermissionsStep(state: state)
        case .ready:
            ReadyStep()
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
                    .foregroundColor(.softCharcoal)
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.sm)
                    .background(Color.charcoal.opacity(0.05))
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
                    variant: .primary
                ) {
                    state.completeOnboarding()
                    onComplete()
                }
                .keyboardShortcut(.return, modifiers: [])
            } else {
                PremiumButton(
                    title: continueButtonText,
                    icon: continueButtonIcon,
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

    private var continueButtonText: String {
        switch state.currentStep {
        case .welcome:
            return "Get Started"
        case .howItWorks:
            return "Continue"
        case .permissions:
            return state.canProceed ? "Continue" : "Grant Permissions"
        case .ready:
            return "Start Using Transcripted"
        }
    }

    private var continueButtonIcon: String {
        switch state.currentStep {
        case .welcome:
            return "arrow.right"
        case .permissions:
            return state.canProceed ? "arrow.right" : "lock.open"
        default:
            return "arrow.right"
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
                        .foregroundColor(.softCharcoal.opacity(0.6))
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
}
#endif
