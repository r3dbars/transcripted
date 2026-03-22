# Onboarding

3-step first-run flow that gates access to the main app until permissions and models are ready. 6 Swift files.

## File Index

| File | Purpose |
|------|---------|
| `OnboardingState.swift` | Central state manager (`@Observable`). Step progression, permission status, model readiness. |
| `OnboardingContainerView.swift` | View orchestrator. Step switching with transitions, navigation buttons, skip confirmation. |
| `OnboardingWindow.swift` | NSWindowController. Frosted glass background, fade-in animation, close = skip. |
| `Steps/WelcomeStep.swift` | Welcome screen. Animated icon + 3 cascading BenefitCards. See Steps/CLAUDE.md |
| `Steps/PermissionsStep.swift` | Permission request. Mic (required) + Screen Recording (optional). See Steps/CLAUDE.md |
| `Steps/ModelSetupStep.swift` | Model downloads. Progress bars, tips carousel. See Steps/CLAUDE.md |

## Step Order
```
1. Welcome     -> always canProceed
2. Permissions  -> always canProceed (mic optional but recommended)
3. Model Setup  -> canProceed only when parakeetReady AND diarizationReady
```

## OnboardingState Key Properties
```swift
// Step navigation
currentStep: OnboardingStep (.welcome | .permissions | .modelSetup)
stepProgress: Double (0.0-1.0), stepNumber: Int (1-3), totalSteps: 3

// Permissions
microphoneStatus: AVAuthorizationStatus
screenRecordingGranted: Bool (via CGWindowListCopyWindowInfo trick)
microphoneGranted: Bool (computed: microphoneStatus == .authorized)
allPermissionsGranted: Bool  // GATES APP: requires microphone only
allPermissionsFullyGranted: Bool  // Both mic + screen recording

// Model setup
parakeetReady: Bool, diarizationReady: Bool, modelsReady: Bool (computed: both true)
parakeetProgress: Double, diarizationProgress: Double (0.0-1.0)
parakeetPhase: String, diarizationPhase: String ("Downloading...", "Compiling models...", "Ready")
isLoadingModels: Bool, modelError: String? (concatenated errors with \n)
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
- Size: 720x680, floating level, transparent background with frosted glass (NSVisualEffectView hudWindow)
- Close button visible: closing = skip onboarding (calls onComplete)
- Fade-in animation: alpha 0 -> 1 over 0.3s
- Fade-out: alpha 1 -> 0 over 0.3s, then orders out

## Step Transitions
- Asymmetric: `.opacity + .offset(x: +/-30) + .scale(0.98)`
- Direction tracked for forward/backward offset
- Respects `accessibilityReduceMotion` (opacity only)
- Model setup auto-completes: when modelsReady, 1.5s delay then close onboarding

## Permission Detection Details
- **Microphone**: Direct `AVCaptureDevice.authorizationStatus(for: .audio)`
- **Screen Recording**: Side-effect check via `CGWindowListCopyWindowInfo()` - if returns windows, permission granted. Not officially documented API.
- Permission cards show 4 states: notRequested (Grant button), pending (spinner), granted (checkmark), denied (Settings button)

## Model Download Monitoring
- Watches FluidAudio model directories for file size growth
- Expected sizes: Parakeet ~483MB, Diarization ~36MB
- Progress capped at 0.99 (avoids showing 100% before CoreML compilation finishes)
- At >95%: phase changes to "Compiling models..."
- Tips carousel: 4 tips rotating every 4s while downloading

## Skip Behavior
- "Skip for now" link shown on Welcome + Permissions (not Model Setup)
- Shows confirmation alert before skipping
- Closing window via close button also triggers skip (prevents invisible app state)

## Gotchas
- Screen recording detection is not a real API - uses CGWindowListCopyWindowInfo side-effect
- Multiple concurrent loadModels() calls blocked by isLoadingModels guard
- Model error messages concatenated with "\n" (both errors show if both fail)
- Progress monitoring caps at 0.99 to prevent premature "100%" display
- OnboardingContainerView uses `@Bindable` (not `@ObservedObject`) because state uses `@Observable` macro
- The app does NOT initialize (no menus, no audio, no floating panel) until onboarding completes
