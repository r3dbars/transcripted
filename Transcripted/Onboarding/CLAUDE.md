# Onboarding

2-step first-run flow that gates access to the main app until permissions and models are ready. 5 Swift files. Dark theme matching the product.

## File Index

| File | Purpose |
|------|---------|
| `OnboardingState.swift` | Central state manager (`@Observable`). Step progression, permission status, model readiness. |
| `OnboardingContainerView.swift` | View orchestrator. Step switching with transitions, navigation buttons, skip confirmation, auto-advance. |
| `OnboardingWindow.swift` | NSWindowController. Dark opaque background, fade-in animation, close persists completion. |
| `Steps/PermissionsStep.swift` | Permission request. Mic + Screen Recording. See Steps/CLAUDE.md |
| `Steps/ModelSetupStep.swift` | Model downloads. Progress bars, download speed/ETA, structured errors. See Steps/CLAUDE.md |

## Step Order
```
1. Permissions  -> always canProceed (mic optional but recommended)
2. Model Setup  -> canProceed only when parakeetReady AND diarizationReady
```

## OnboardingState Key Properties
```swift
// Step navigation
currentStep: OnboardingStep (.permissions | .modelSetup)
stepProgress: Double (0.0-1.0), stepNumber: Int (1-2), totalSteps: 2

// Permissions
microphoneStatus: AVAuthorizationStatus
screenRecordingGranted: Bool (via CGWindowListCopyWindowInfo trick)
microphoneGranted: Bool (computed: microphoneStatus == .authorized)
allPermissionsGranted: Bool  // requires microphone only
allPermissionsFullyGranted: Bool  // Both mic + screen recording

// Model setup
parakeetReady: Bool, diarizationReady: Bool, modelsReady: Bool (computed: both true)
parakeetProgress: Double, diarizationProgress: Double (0.0-1.0)
parakeetPhase: String, diarizationPhase: String ("Downloading...", "Compiling models...", "Ready")
isLoadingModels: Bool, modelError: String? (concatenated errors with \n)
modelErrorKind: DownloadErrorKind? (structured error classification from ModelDownloadService)
downloadSpeed: Double (bytes/sec, smoothed), estimatedTimeRemaining: TimeInterval? (nil when unknown)
```

## OnboardingState Key Methods
- `checkPermissions()` - Polls current status (call on appear)
- `requestMicrophonePermission() async` - `AVCaptureDevice.requestAccess(for: .audio)`
- `openMicrophoneSettings()` / `openScreenRecordingSettings()` - Opens System Preferences deep links
- `loadModels() async` - Guards re-entry with isLoadingModels flag, inits both models in parallel (`async let`)
- `monitorDownloadProgress() async` - Polls model directories every 500ms, caps at 0.99 until ready
- `completeOnboarding()` - Sets UserDefaults "hasCompletedOnboarding" = true
- `hasCompletedOnboarding() -> Bool` / `resetOnboarding()` - Static helpers

## App Integration
```swift
// TranscriptedApp.swift -> AppDelegate.applicationDidFinishLaunching()
if !OnboardingState.hasCompletedOnboarding() {
    showOnboarding()  // -> OnboardingWindowController(onComplete: { setupApp() })
    return  // Don't initialize main app until onboarding completes
}
setupApp()
```

## Window Behavior
- Size: 560x520, floating level, dark opaque background (panelCharcoal, .darkAqua appearance)
- Close button visible: closing persists `hasCompletedOnboarding` and starts the app
- Fade-in animation: alpha 0 -> 1 over 0.3s
- Fade-out: alpha 1 -> 0 over 0.3s, then orders out

## Step Transitions
- Simple: `.opacity + .offset(x: +/-20)`
- Respects `accessibilityReduceMotion` (opacity only)

## Auto-Advance
- When `modelsReady` becomes true on the model setup step, auto-completes after 1.5s delay
- Handled via `.onChange(of: state.modelsReady)` in OnboardingContainerView

## Permission Detection Details
- **Microphone**: Direct `AVCaptureDevice.authorizationStatus(for: .audio)`
- **Screen Recording**: Side-effect check via `CGWindowListCopyWindowInfo()` - if returns windows, permission granted
- Permission cards show 4 states: notRequested (Grant button), pending (spinner), granted (checkmark), denied (Settings button)

## Model Download Monitoring
- Watches FluidAudio model directories for file size growth
- Expected sizes: Parakeet ~483MB, Diarization ~36MB
- Progress capped at 0.99 (avoids showing 100% before CoreML compilation finishes)
- At >95%: phase changes to "Compiling models..."

## Skip Behavior
- "Skip for now" link shown on permissions step (not model setup)
- Shows confirmation alert before skipping
- Closing window via close button also persists completion and starts the app

## Gotchas
- Screen recording detection is not a real API - uses CGWindowListCopyWindowInfo side-effect
- Multiple concurrent loadModels() calls blocked by isLoadingModels guard
- Model error messages concatenated with "\n" (both errors show if both fail)
- Progress monitoring caps at 0.99 to prevent premature "100%" display
- OnboardingContainerView uses `@Bindable` (not `@ObservedObject`) because state uses `@Observable` macro
- The app does NOT initialize (no menus, no audio, no floating panel) until onboarding completes
- Onboarding creates throwaway ParakeetService/DiarizationService for downloads; setupApp() creates fresh instances (fast cache hit)
