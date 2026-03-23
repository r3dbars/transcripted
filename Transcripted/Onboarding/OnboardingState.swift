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
        case preview = 1
        case permissions = 2
        case modelSetup = 3

        var title: String {
            switch self {
            case .welcome: return "Welcome"
            case .preview: return "Preview"
            case .permissions: return "Permissions"
            case .modelSetup: return "Model Setup"
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
    var parakeetProgress: Double = 0
    var diarizationProgress: Double = 0
    var parakeetPhase: String = ""
    var diarizationPhase: String = ""
    var modelError: String?
    var modelErrorKind: DownloadErrorKind?
    var isLoadingModels = false
    var downloadSpeed: Double = 0  // bytes per second (smoothed)
    var estimatedTimeRemaining: TimeInterval?  // seconds, nil when unknown

    var modelsReady: Bool {
        parakeetReady && diarizationReady
    }

    // MARK: - Computed Properties

    var canProceed: Bool {
        switch currentStep {
        case .welcome:
            return true
        case .preview:
            return true
        case .permissions:
            return microphoneGranted
        case .modelSetup:
            return modelsReady
        }
    }

    var isFirstStep: Bool {
        currentStep == .welcome
    }

    var isLastStep: Bool {
        currentStep == .modelSetup
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
            // Ensure the app is frontmost so the system permission dialog
            // appears above the onboarding window (app uses .accessory policy)
            NSApp.activate()
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

    /// Download and initialize Parakeet + diarization models with progress tracking.
    /// Monitors the FluidAudio cache directory to estimate download progress.
    @MainActor
    func loadModels() async {
        guard !isLoadingModels else { return }
        isLoadingModels = true
        modelError = nil
        modelErrorKind = nil
        parakeetProgress = 0
        diarizationProgress = 0
        downloadSpeed = 0
        estimatedTimeRemaining = nil
        parakeetPhase = "Downloading..."
        diarizationPhase = "Downloading..."

        // Pre-flight: check network connectivity before starting long downloads
        let networkAvailable = await ModelDownloadService.checkNetworkReachability()
        if !networkAvailable {
            modelErrorKind = .networkOffline
            modelError = DownloadErrorKind.networkOffline.detail
            isLoadingModels = false
            return
        }

        // Pre-flight: check disk space (~700MB needed for Parakeet + Diarization)
        if let available = ModelDownloadService.availableDiskSpace(), available < 1_000_000_000 {
            modelErrorKind = .diskSpace
            modelError = DownloadErrorKind.diskSpace.detail
            isLoadingModels = false
            return
        }

        // Start monitoring download progress on disk
        let progressTask = Task { @MainActor in
            await monitorDownloadProgress()
        }

        // These services are created just for download/validation during onboarding.
        // setupApp() creates fresh instances afterward; the second init is a fast cache hit.
        let parakeet = ParakeetService()
        let diarization = DiarizationService()

        // Initialize both in parallel (retry logic built into each service)
        async let p: Void = parakeet.initialize()
        async let s: Void = diarization.initialize()
        await p
        await s

        progressTask.cancel()

        // Check results
        if case .ready = parakeet.modelState {
            parakeetReady = true
            parakeetProgress = 1.0
            parakeetPhase = "Ready"
        } else if case .failed(let e) = parakeet.modelState {
            modelError = "Speech recognition: \(e)"
        }

        if case .ready = diarization.modelState {
            diarizationReady = true
            diarizationProgress = 1.0
            diarizationPhase = "Ready"
        } else if case .failed(let e) = diarization.modelState {
            modelError = (modelError != nil ? modelError! + "\n" : "") + "Speaker diarization: \(e)"
        }

        isLoadingModels = false
    }

    // Expected model sizes (bytes) for progress estimation
    private static let expectedParakeetSize: Double = 483_000_000  // ~461 MB on disk
    private static let expectedDiarizationSize: Double = 36_000_000 // ~34 MB on disk

    /// Poll the FluidAudio Models directory to estimate download progress, speed, and ETA
    @MainActor
    private func monitorDownloadProgress() async {
        let modelsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/FluidAudio/Models")
        let parakeetDir = modelsDir.appendingPathComponent("parakeet-tdt-0.6b-v3-coreml")
        let diarizationDir = modelsDir.appendingPathComponent("speaker-diarization-coreml")

        // Speed tracking state
        var previousTotalBytes: Double = 0
        var previousTimestamp: Date = Date()
        var smoothedSpeed: Double = 0
        let smoothingFactor = 0.3  // EMA: 30% new, 70% old

        while !Task.isCancelled {
            let parakeetBytes = Self.directorySize(parakeetDir)
            let diarizationBytes = Self.directorySize(diarizationDir)
            let totalBytes = parakeetBytes + diarizationBytes

            let pProgress = min(parakeetBytes / Self.expectedParakeetSize, 0.99)
            let sProgress = min(diarizationBytes / Self.expectedDiarizationSize, 0.99)

            // Compute download speed
            let now = Date()
            let elapsed = now.timeIntervalSince(previousTimestamp)
            if elapsed > 0.1 {  // Avoid division by near-zero
                let bytesPerSecond = (totalBytes - previousTotalBytes) / elapsed
                if bytesPerSecond > 0 {
                    smoothedSpeed = smoothedSpeed == 0
                        ? bytesPerSecond
                        : smoothedSpeed * (1 - smoothingFactor) + bytesPerSecond * smoothingFactor
                }
                previousTotalBytes = totalBytes
                previousTimestamp = now
            }

            downloadSpeed = smoothedSpeed

            // Compute ETA from remaining bytes and smoothed speed
            let totalExpected = Self.expectedParakeetSize + Self.expectedDiarizationSize
            let remainingBytes = max(0, totalExpected - totalBytes)
            if smoothedSpeed > 1000 {  // Only show ETA when speed is meaningful
                estimatedTimeRemaining = remainingBytes / smoothedSpeed
            } else {
                estimatedTimeRemaining = nil
            }

            if !parakeetReady {
                parakeetProgress = pProgress
                if pProgress > 0.95 {
                    parakeetPhase = "Compiling models..."
                } else if pProgress > 0 {
                    let mb = Int(parakeetBytes / 1_000_000)
                    parakeetPhase = "Downloading... \(mb) MB"
                }
            }

            if !diarizationReady {
                diarizationProgress = sProgress
                if sProgress > 0.95 {
                    diarizationPhase = "Compiling models..."
                } else if sProgress > 0 {
                    let mb = Int(diarizationBytes / 1_000_000)
                    diarizationPhase = "Downloading... \(mb) MB"
                }
            }

            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    /// Calculate total size of a directory in bytes
    private static func directorySize(_ url: URL) -> Double {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else {
            return 0
        }
        var total: Double = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Double(size)
            }
        }
        return total
    }

    // MARK: - Completion

    func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
    }

    static func hasCompletedOnboarding() -> Bool {
        UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
    }

    // MARK: - Pill Callout (first-time coach mark)

    static func hasShownPillCallout() -> Bool {
        UserDefaults.standard.bool(forKey: "hasShownPillCallout")
    }

    static func markPillCalloutShown() {
        UserDefaults.standard.set(true, forKey: "hasShownPillCallout")
    }

    // For testing: reset onboarding state
    static func resetOnboarding() {
        UserDefaults.standard.removeObject(forKey: "hasCompletedOnboarding")
        UserDefaults.standard.removeObject(forKey: "hasShownPillCallout")
    }
}
