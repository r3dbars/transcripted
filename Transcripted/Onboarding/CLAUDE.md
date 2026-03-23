# Onboarding

4-step first-run flow that gates access to the main app until permissions and models are ready. 7 Swift files. Dark theme matching the product.

## File Index

| File | Purpose |
|------|---------|
| `OnboardingState.swift` | Central state manager (`@Observable`). Step progression, permission status, model readiness. |
| `OnboardingContainerView.swift` | View orchestrator. Opacity transitions, circle progress dots, standard nav buttons, auto-advance. |
| `OnboardingWindow.swift` | NSWindowController. 640x560 window, dark opaque background, fade-in animation, close = skip. |
| `Steps/WelcomeStep.swift` | Welcome screen. Icon + 3 BenefitCards with simple fade-in. See Steps/CLAUDE.md |
| `Steps/PreviewStep.swift` | Sample transcript preview. Staggered line reveal showing "aha moment". See Steps/CLAUDE.md |
| `Steps/PermissionsStep.swift` | Permission request. Mic (REQUIRED to proceed) + Screen Recording (optional). See Steps/CLAUDE.md |
| `Steps/ModelSetupStep.swift` | Model downloads. Progress bars, download speed/ETA, structured errors. See Steps/CLAUDE.md |

## Step Order
```
1. Welcome     -> always canProceed
2. Preview     -> always canProceed (sample transcript "aha moment")
3. Permissions  -> canProceed only when microphoneGranted (mic REQUIRED)
4. Model Setup  -> canProceed only when parakeetReady AND diarizationReady
```

## OnboardingState Key Properties
```swift
// Step navigation
currentStep: OnboardingStep (.welcome | .preview | .permissions | .modelSetup)
stepProgress: Double (0.0-1.0), stepNumber: Int (1-4), totalSteps: 4

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
- Size: 640x560, floating level, dark opaque background (panelCharcoal, .darkAqua appearance)
- Close button visible: closing persists `hasCompletedOnboarding` and starts the app
- Fade-in animation: alpha 0 -> 1 over 0.3s
- Fade-out: alpha 1 -> 0 over 0.3s, then orders out

## Step Transitions
- Opacity-only transitions with `.easeInOut(duration: 0.3)`
- No directional offset or scale — simple fade between steps

## Auto-Advance
- When `modelsReady` becomes true on the model setup step, auto-completes after 1.5s delay
- Handled via `.onChange(of: state.modelsReady)` in OnboardingContainerView

## Permission Detection Details
- **Microphone**: Direct `AVCaptureDevice.authorizationStatus(for: .audio)` — REQUIRED to proceed past step 3
- **Screen Recording**: Side-effect check via `CGWindowListCopyWindowInfo()` - if returns windows, permission granted. Not officially documented API.
- Permission rows show 4 states: notRequested (Grant button), pending (spinner), granted (checkmark), denied (Settings button)
- Denied state shows guidance text: "Enable it in System Settings to continue"
- Continue button DISABLED until mic permission granted (canProceed = microphoneGranted)
- No "Continue without mic" bypass

## Model Download Monitoring
- Watches FluidAudio model directories for file size growth
- Expected sizes: Parakeet ~483MB, Diarization ~36MB
- Progress capped at 0.99 (avoids showing 100% before CoreML compilation finishes)
- At >95%: phase changes to "Compiling models..."

## Navigation
- Progress indicator: 4 circle dots (8pt), recordingCoral filled for completed/active, panelCharcoalSurface for upcoming
- Nav buttons: standard SwiftUI `.borderedProminent` / `.bordered` tinted recordingCoral
- No "Skip for now" link — user must complete onboarding properly
- Close button still calls completeOnboarding + onComplete as safety valve (prevents invisible app state)

## Gotchas
- Screen recording detection is not a real API - uses CGWindowListCopyWindowInfo side-effect
- Multiple concurrent loadModels() calls blocked by isLoadingModels guard
- Model error messages concatenated with "\n" (both errors show if both fail)
- Progress monitoring caps at 0.99 to prevent premature "100%" display
- OnboardingContainerView uses `@Bindable` (not `@ObservedObject`) because state uses `@Observable` macro
- The app does NOT initialize (no menus, no audio, no floating panel) until onboarding completes
- Microphone permission is REQUIRED — canProceed returns false on permissions step until mic is granted
- Onboarding creates throwaway ParakeetService/DiarizationService for downloads; setupApp() creates fresh instances (fast cache hit)
