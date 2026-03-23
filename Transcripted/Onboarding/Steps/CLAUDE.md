# Onboarding Steps

4 SwiftUI views implementing individual onboarding steps. Hosted by OnboardingContainerView.swift (parent). WelcomeStep and PreviewStep are stateless; PermissionsStep and ModelSetupStep use `@Bindable var state: OnboardingState`.

## File Index

| File | Step | canProceed |
|------|------|------------|
| `WelcomeStep.swift` | 1. Welcome | Always true |
| `PreviewStep.swift` | 2. Preview | Always true |
| `PermissionsStep.swift` | 3. Permissions | Only when microphoneGranted (mic REQUIRED) |
| `ModelSetupStep.swift` | 4. Model Setup | Only when parakeetReady AND diarizationReady |

## Step Details

### WelcomeStep (Step 1)
- Hero icon: waveform.circle.fill, 56pt, flat terracotta color
- 3 BenefitCards (from Design/Components/):
  - "Transcribe Meetings" (waveform icon)
  - "Identify Speakers" (person.2.fill icon)
  - "Completely Private" (lock.shield.fill icon)
- Simple opacity fade-in (0.3s easeInOut), no stagger

### PreviewStep (Step 2)
- Sample transcript showing a realistic meeting conversation
- 6 transcript lines with staggered reveal (0.2s per line)
- Two speakers: Sarah (terracotta) and Mike (processingPurple)
- Delivers "aha moment" — shows what Transcripted produces before asking for permissions
- No user action required, always canProceed

### PermissionsStep (Step 3)
- 2 simple PermissionRow components (Draft-style HStack layout):
  - **Microphone** (required): mic.fill icon. Requests via `AVCaptureDevice.requestAccess(for: .audio)`
  - **Screen Recording** (recommended): rectangle.inset.filled.and.person.filled icon. Opens System Settings
- 4 status states per row: notRequested (Grant button), pending (spinner), granted (checkmark), denied (Settings button)
- Denied state shows guidance text: "Enable it in System Settings to continue"
- Continue button DISABLED until mic permission granted (canProceed = microphoneGranted)
- No "Continue without mic" bypass

### ModelSetupStep (Step 4)
- Downloads 2 models in parallel (`async let`):
  - **Parakeet**: ~483MB expected (ASR model)
  - **Diarization**: ~36MB expected (speaker separation)
- Auto-starts download on `.onAppear` (no manual trigger)
- Progress monitoring: polls model directories every 500ms, caps at 0.99 until CoreML compilation finishes
- Download speed + ETA display when speed > 1KB/s
- Auto-advance: when modelsReady, container auto-completes after 1.5s
- Error handling: structured error card with retry button
- Success message when both models ready

## Shared Dependencies
- `@Bindable var state: OnboardingState` — NOT `@ObservedObject` (because `@Observable` macro)
- Design components: BenefitCard (from Design/Components/)
- Colors: panelCharcoal, panelCharcoalElevated, panelCharcoalSurface, panelTextPrimary/Secondary/Muted, recordingCoral, attentionGreen, errorRed
- Typography: .displayMedium/.displayLarge (titles), .bodyLarge (subtitles)

## Relationships
- Parent: `OnboardingContainerView.swift` (handles step switching, navigation buttons, auto-advance)
- State: `OnboardingState.swift` (step progression, permission status, model readiness)
- Window: `OnboardingWindow.swift` (NSWindowController, 640x560)

## Gotchas
- `@Bindable` not `@ObservedObject` — OnboardingState uses `@Observable` macro, not ObservableObject
- ModelSetupStep auto-starts download on `.onAppear` — no user action needed
- Screen recording detection is NOT a real API — uses `CGWindowListCopyWindowInfo()` side-effect (undocumented)
- Progress capped at 0.99 to prevent premature "100%" display before CoreML compilation
- Model errors are concatenated with "\n" (both errors show if both models fail)
- The app does NOT initialize (no menus, no audio, no floating panel) until onboarding completes
- Microphone permission is REQUIRED — users cannot proceed without granting it
