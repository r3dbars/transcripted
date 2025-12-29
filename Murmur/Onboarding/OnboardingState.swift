import SwiftUI
import AVFoundation

/// Manages the state of the onboarding flow
/// Uses @Observable macro for automatic SwiftUI integration
@available(macOS 26.0, *)
@Observable
class OnboardingState {

    // MARK: - Step Navigation

    var currentStep: OnboardingStep = .welcome

    enum OnboardingStep: Int, CaseIterable {
        case welcome = 0
        case howItWorks = 1
        case permissions = 2
        case ready = 3

        var title: String {
            switch self {
            case .welcome: return "Welcome"
            case .howItWorks: return "How It Works"
            case .permissions: return "Permissions"
            case .ready: return "Ready"
            }
        }
    }

    // MARK: - Permission Status

    var microphoneStatus: AVAuthorizationStatus = .notDetermined

    var microphoneGranted: Bool {
        microphoneStatus == .authorized
    }

    /// For proceeding through onboarding, we require microphone permission
    var allPermissionsGranted: Bool {
        microphoneGranted
    }

    // MARK: - Loading States

    var isMicrophoneRequestInProgress = false

    // MARK: - Computed Properties

    var canProceed: Bool {
        switch currentStep {
        case .permissions:
            return allPermissionsGranted
        default:
            return true
        }
    }

    var isFirstStep: Bool {
        currentStep == .welcome
    }

    var isLastStep: Bool {
        currentStep == .ready
    }

    var stepProgress: Double {
        Double(currentStep.rawValue) / Double(OnboardingStep.allCases.count - 1)
    }

    var stepNumber: Int {
        currentStep.rawValue + 1
    }

    var totalSteps: Int {
        OnboardingStep.allCases.count
    }

    // MARK: - Navigation Methods

    func advance() {
        guard canProceed else { return }

        if let next = OnboardingStep(rawValue: currentStep.rawValue + 1) {
            withAnimation(.easeInOut(duration: 0.3)) {
                currentStep = next
            }
        }
    }

    func goBack() {
        if let prev = OnboardingStep(rawValue: currentStep.rawValue - 1) {
            withAnimation(.easeInOut(duration: 0.3)) {
                currentStep = prev
            }
        }
    }

    func goToStep(_ step: OnboardingStep) {
        withAnimation(.easeInOut(duration: 0.3)) {
            currentStep = step
        }
    }

    // MARK: - Permission Methods

    func checkPermissions() {
        // Check microphone status
        microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    }

    func requestMicrophonePermission() async {
        await MainActor.run {
            isMicrophoneRequestInProgress = true
        }

        let granted = await AVCaptureDevice.requestAccess(for: .audio)

        await MainActor.run {
            microphoneStatus = granted ? .authorized : .denied
            isMicrophoneRequestInProgress = false
        }
    }

    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Completion

    func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
    }

    static func hasCompletedOnboarding() -> Bool {
        UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
    }

    // For testing: reset onboarding state
    static func resetOnboarding() {
        UserDefaults.standard.removeObject(forKey: "hasCompletedOnboarding")
    }
}
