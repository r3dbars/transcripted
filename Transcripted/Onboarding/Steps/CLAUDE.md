# Onboarding Steps

6 SwiftUI views live in this folder, but the current onboarding flow uses only 4 of them. Hosted by `OnboardingContainerView.swift` (parent). `WelcomeStep` and `PreviewStep` are stateless. `PermissionsStep` and `ModelSetupStep` use `@Bindable var state: OnboardingState`.

## File Index

| File | Live Step? | Purpose |
|------|------------|---------|
| `WelcomeStep.swift` | Yes, step 1 | Welcome screen with value-prop benefit cards |
| `PreviewStep.swift` | Yes, step 2 | Sample transcript preview with staggered reveal |
| `PermissionsStep.swift` | Yes, step 3 | Requests microphone and screen recording access |
| `ModelSetupStep.swift` | Yes, step 4 | Downloads and initializes local AI models |
| `HowItWorksStep.swift` | Legacy | Older explainer step, not referenced by the current container |
| `TestRecordingStep.swift` | Legacy | Older guided recording demo, not referenced by the current container |

## Live Step Order

| Step | File | canProceed |
|------|------|------------|
| 1 | `WelcomeStep.swift` | Always true |
| 2 | `PreviewStep.swift` | Always true |
| 3 | `PermissionsStep.swift` | Only when `microphoneGranted` |
| 4 | `ModelSetupStep.swift` | Only when `parakeetReady && diarizationReady` |

## Step Details

### WelcomeStep
- Value proposition with 3 benefit cards
- Messaging focuses on local transcription, speaker identification, and privacy
- No user action required

### PreviewStep
- Shows 6 transcript lines with staggered reveal (`0.2s` between lines)
- Demo speakers: Sarah (`recordingCoral`) and Mike (`processingPurple`)
- Delivers the "aha" moment before asking for permissions

### PermissionsStep
- 2 `PermissionRow`s:
  - **Microphone Access** (required)
  - **Screen Recording** (recommended)
- Microphone row supports 4 states: `notRequested`, `pending`, `granted`, `denied`
- Denied microphone state shows both **Try Again** and **Settings** buttons
- Screen recording row opens System Settings because there is no direct request API
- Shows an amber warning callout when screen recording is still missing
- Continue button remains disabled until mic permission is granted

### ModelSetupStep
- Downloads 2 models in parallel:
  - **Speech Recognition**: Parakeet TDT V3
  - **Speaker Diarization**: PyAnnote
- Auto-starts `state.loadModels()` on appear when models are not already ready
- Displays progress, phase text, speed, ETA, and structured error states
- When both models are ready, shows a success banner and the container auto-completes after 1.5s

## Shared Dependencies
- `@Bindable var state: OnboardingState` for stateful steps
- Benefit cards from `Transcripted/Design/Components/`
- Colors: `panelCharcoal`, `panelCharcoalElevated`, `panelCharcoalSurface`, `panelTextPrimary`, `panelTextSecondary`, `panelTextMuted`, `recordingCoral`, `processingPurple`, `attentionGreen`, `warningAmber`, `errorRed`

## Relationships
- Parent: `OnboardingContainerView.swift`
- State: `OnboardingState.swift`
- Window: `OnboardingWindow.swift`

## Gotchas
- The folder still contains 2 legacy views from the old 6-step flow
- `PermissionsStep` calls `state.checkPermissions()` on appear so the UI refreshes after returning from System Settings
- `ModelSetupStep` does not require a manual "Download" click
- The app does not initialize until the live 4-step onboarding completes
