# Onboarding — CLAUDE.md

## Purpose
Five-step first-launch onboarding flow: Welcome → How It Works → Permissions → Model Setup → Ready. Gates app setup behind microphone permission and model initialization.

## Files

| File | Responsibility |
|---|---|
| `OnboardingState.swift` | @Observable state manager, step tracking, permission requests, completion persistence |
| `OnboardingWindow.swift` | NSWindowController (720×680), frosted glass (`hudWindow` material), fade animations |
| `OnboardingContainerView.swift` | Step container with navigation, progress indicator, page transitions, keyboard shortcuts |
| `Steps/WelcomeStep.swift` | Step 1: App intro with icon and tagline |
| `Steps/HowItWorksStep.swift` | Step 2: Auto-advancing 4-phase animation (Recording → Transcribing → Analyzing → Insights) |
| `Steps/PermissionsStep.swift` | Step 3: Microphone permission request with status-dependent UI |
| `Steps/ModelSetupStep.swift` | Step 4: Downloads and initializes Parakeet + Sortformer models |
| `Steps/ReadyStep.swift` | Step 5: Celebration + Quick Start Guide (4 tips) |
| `Animations/ParticleExplosionView.swift` | Celebration particle effects |

## Key Types

**OnboardingState** (@Observable class):
- `currentStep: OnboardingStep` — `.welcome(0)` → `.howItWorks(1)` → `.permissions(2)` → `.modelSetup(3)` → `.ready(4)`
- `microphoneStatus: AVAuthorizationStatus`
- `parakeetReady`, `sortformerReady`, `modelError`, `isLoadingModels`, `modelsReady`
- Computed: `microphoneGranted`, `allPermissionsGranted`, `canProceed` (varies by step), `stepProgress` (0.0-1.0)
- `advance()`, `goBack()`, `goToStep(_:)` — navigation
- `requestMicrophonePermission()` async — requests and updates status
- `completeOnboarding()` — sets UserDefaults `hasCompletedOnboarding` to true
- `static hasCompletedOnboarding()` / `static resetOnboarding()` — persistence

**OnboardingWindowController** (NSWindowController):
- 720×680, transparent title bar, floating level, hudWindow material
- `onComplete: (() -> Void)?` callback → triggers `TranscriptedApp.setupApp()`
- `showWithAnimation()` — 0.3s fade-in
- `handleOnboardingComplete()` — fade-out, call onComplete

**OnboardingContainerView** (SwiftUI View):
- Warm cream background with terracotta gradient
- Asymmetric page transitions (forward/backward)
- Keyboard: Left arrow = back, Return = advance
- "Skip for now" link with confirmation alert
- Respects `accessibilityReduceMotion`

## Flow
```
App launch → OnboardingState.hasCompletedOnboarding() check
  → false: show OnboardingWindow
    Step 1 (Welcome) → Step 2 (How It Works) → Step 3 (Permissions) → Step 4 (Model Setup) → Step 5 (Ready)
    Step 3 blocks advance until microphone granted
    Step 4 downloads and initializes Parakeet + Sortformer models
    → completeOnboarding() → onComplete → TranscriptedApp.setupApp()
  → true: skip directly to setupApp()
```

## Permissions

| Permission | Required | API |
|---|---|---|
| Microphone | Yes | `AVCaptureDevice.requestAccess(for: .audio)` |
| Screen Recording | For system audio | System preferences link (not requested in onboarding) |

## Modification Recipes

| Task | Files to touch |
|---|---|
| Add onboarding step | New `Steps/` view + `OnboardingContainerView.swift` + `OnboardingState.swift` (update step count) |
| Fix permissions | `Steps/PermissionsStep.swift` — macOS permission APIs are async |
| Change theme | Step views + `DesignTokens.swift` (warm cream + terracotta scheme) |
| Test onboarding | Menu bar → "Reset Onboarding (Debug)" — DEBUG builds only |
| Change window size | `OnboardingWindow.swift` — constructor dimensions |

## Dependencies
**From Design/**: DesignTokens (onboarding color scheme: cream, terracotta, charcoal)
**Imported by**: `TranscriptedApp.swift` (shows onboarding or skips to setupApp)
