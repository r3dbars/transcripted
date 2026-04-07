# Onboarding

4-step first-run flow that gates access to the main app until required permissions and local models are ready. 9 Swift files. Dark theme matching the product.

## File Index

| File | Purpose |
|------|---------|
| `OnboardingState.swift` | Central state manager (`@Observable`). Step progression, permission state, model readiness, download progress, and completion helpers. |
| `OnboardingContainerView.swift` | View orchestrator. Opacity transitions, 4 progress dots, standard nav buttons, auto-complete when models finish. |
| `OnboardingWindow.swift` | NSWindowController. 640x560 window, dark opaque background, fade-in animation, close = skip. |
| `Steps/WelcomeStep.swift` | Welcome step with benefit cards. See Steps/CLAUDE.md |
| `Steps/PreviewStep.swift` | Sample transcript preview with staggered line reveal. See Steps/CLAUDE.md |
| `Steps/PermissionsStep.swift` | Permission request. Microphone required, screen recording recommended. See Steps/CLAUDE.md |
| `Steps/ModelSetupStep.swift` | Model downloads. Progress bars, speed/ETA, structured errors. See Steps/CLAUDE.md |
| `Steps/HowItWorksStep.swift` | Legacy file from the older 6-step flow. Not part of the live onboarding sequence. |
| `Steps/TestRecordingStep.swift` | Legacy guided demo from the older 6-step flow. Not part of the live onboarding sequence. |

## Live Step Order
```
1. Welcome      -> always canProceed
2. Preview      -> always canProceed
3. Permissions  -> canProceed only when microphoneGranted
4. Model Setup  -> canProceed only when parakeetReady AND diarizationReady
```

## OnboardingState Key Properties
```swift
// Step navigation
currentStep: OnboardingStep (.welcome | .preview | .permissions | .modelSetup)
stepProgress: Double (0.0-1.0), stepNumber: Int (1-4), totalSteps: 4
isFirstStep: Bool, isLastStep: Bool, canProceed: Bool

// Permissions
microphoneStatus: AVAuthorizationStatus
screenRecordingGranted: Bool
isMicrophoneRequestInProgress: Bool
microphoneGranted: Bool
allPermissionsGranted: Bool          // microphone only
allPermissionsFullyGranted: Bool     // microphone + screen recording
screenRecordingSkipped: Bool         // onboarding completed without screen recording

// Model setup
parakeetReady: Bool, diarizationReady: Bool, modelsReady: Bool
parakeetProgress: Double, diarizationProgress: Double
parakeetPhase: String, diarizationPhase: String
isLoadingModels: Bool
modelError: String?
modelErrorKind: DownloadErrorKind?
downloadSpeed: Double
estimatedTimeRemaining: TimeInterval?
```

## Permission Notes
- **Microphone** is required to continue past step 3.
- **Screen Recording** is recommended, not required. It uses `CGPreflightScreenCaptureAccess()` for detection.
- `requestMicrophonePermission()` calls `NSApp.activate()` before `AVCaptureDevice.requestAccess(for: .audio)` so the system prompt appears in front of the onboarding window.
- Denied microphone state shows both **Try Again** and **Settings** actions.

## Model Download Behavior
- `loadModels()` blocks re-entry with `isLoadingModels`
- Runs network and disk-space preflight checks before long downloads
- Initializes `ParakeetEngineAdapter` and `DiarizationService` in parallel with `async let`
- Progress monitoring polls model directories every 500ms and caps at 0.99 until initialization fully completes
- Shows smoothed download speed and ETA when enough data is available
- `OnboardingContainerView` auto-completes onboarding 1.5s after `modelsReady` flips true on the final step

## App Integration
```swift
// TranscriptedApp.swift -> AppDelegate.applicationDidFinishLaunching()
if !OnboardingState.hasCompletedOnboarding() {
    showOnboarding()
    return
}
setupApp()
```

## Window Behavior
- Size: 640x560
- Dark opaque background (`panelCharcoal`, `.darkAqua`)
- Fade in/out animation on show and dismiss
- Closing the window still calls `completeOnboarding()` as a safety valve so the app does not get stuck invisible

## Legacy Files Still Present
`HowItWorksStep.swift` and `TestRecordingStep.swift` are still in the tree, but the current `OnboardingStep` enum and `OnboardingContainerView` no longer route to them. Treat docs or comments describing a 6-step onboarding flow as stale.

## Gotchas
- `OnboardingState` uses the `@Observable` macro, so views bind with `@Bindable`, not `@ObservedObject`
- The main app does not initialize until onboarding completes
- Screen recording is optional for onboarding, but missing it means Transcripted cannot hear other participants' app audio
- Model setup creates temporary service instances for download/validation; `setupApp()` constructs fresh runtime instances afterward
