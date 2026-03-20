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
        case preview = 2
        case permissions = 3
        case modelSetup = 4
        case ready = 5

        var title: String {
            switch self {
            case .welcome: return "Welcome"
            case .howItWorks: return "How It Works"
            case .preview: return "Preview"
            case .permissions: return "Permissions"
            case .modelSetup: return "Model Setup"
            case .ready: return "Ready"
            }
        }
    }

    // MARK: - Permission Status

    var microphoneStatus: AVAuthorizationStatus = .notDetermined
    var screenRecordingGranted: Bool = false

    var microphoneGranted: Bool {
        microphoneStatus == .authorized
    }

    /// For proceeding through onboarding, we require microphone permission.
    /// Screen recording is recommended but not required to continue.
    var allPermissionsGranted: Bool {
        microphoneGranted
    }

    /// True when both mic and screen recording are granted
    var allPermissionsFullyGranted: Bool {
        microphoneGranted && screenRecordingGranted
    }

    // MARK: - Loading States

    var isMicrophoneRequestInProgress = false

    // MARK: - Model Setup State

    var parakeetReady = false
    var diarizationReady = false
    var modelError: String?
    var isLoadingModels = false

    var modelsReady: Bool {
        parakeetReady && diarizationReady
    }

    // MARK: - Computed Properties

    var canProceed: Bool {
        switch currentStep {
        case .preview:
            return true
        case .permissions:
            // Soft gate: allow proceeding without mic permission
            return true
        case .modelSetup:
            return modelsReady
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
        // Check screen recording permission (needed for system audio capture)
        screenRecordingGranted = checkScreenRecordingPermission()
    }

    /// Check if screen recording permission is granted by testing CGWindow list access.
    /// This is the standard macOS technique — if we can list windows for other apps, we have permission.
    private func checkScreenRecordingPermission() -> Bool {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        // If we can see windows from other apps (not just our own), permission is granted
        let myPID = ProcessInfo.processInfo.processIdentifier
        return windowList.contains { dict in
            guard let pid = dict[kCGWindowOwnerPID as String] as? Int32 else { return false }
            return pid != myPID
        }
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

    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func requestScreenRecordingPermission() {
        // Screen recording doesn't have a programmatic request API —
        // opening System Settings is the only way to guide the user
        openScreenRecordingSettings()
    }

    // MARK: - Model Loading

    /// Download and initialize Parakeet + Sortformer models.
    /// These temporary instances trigger the download/cache so models are on disk
    /// for the real Transcription object created in setupApp().
    @MainActor
    func loadModels() async {
        guard !isLoadingModels else { return }
        isLoadingModels = true
        modelError = nil

        let parakeet = ParakeetService()
        let diarization = DiarizationService()

        // Initialize both in parallel
        async let p: Void = parakeet.initialize()
        async let s: Void = diarization.initialize()
        await p
        await s

        // Check results
        if case .ready = parakeet.modelState {
            parakeetReady = true
        } else if case .failed(let e) = parakeet.modelState {
            modelError = "Speech recognition: \(e)"
        }

        if case .ready = diarization.modelState {
            diarizationReady = true
        } else if case .failed(let e) = diarization.modelState {
            modelError = (modelError != nil ? modelError! + "\n" : "") + "Speaker diarization: \(e)"
        }

        isLoadingModels = false
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
