# Onboarding Steps

6 SwiftUI views implementing individual onboarding steps. Hosted by OnboardingContainerView.swift (parent). WelcomeStep, PreviewStep, and HowItWorksStep are stateless; PermissionsStep, ModelSetupStep, and TestRecordingStep use `@Bindable var state: OnboardingState`.

## File Index

| File | Step | canProceed |
|------|------|------------|
| `WelcomeStep.swift` | 1. Welcome | Always true |
| `PreviewStep.swift` | 2. Preview | Always true |
| `PermissionsStep.swift` | 3. Permissions | Only when microphoneGranted (mic REQUIRED) |
| `ModelSetupStep.swift` | 4. Model Setup | Only when parakeetReady AND diarizationReady |
| `HowItWorksStep.swift` | 5. How It Works | Always true |
| `TestRecordingStep.swift` | 6. Test Recording | Only when testRecordingPhase == .complete |

## Step Details

### WelcomeStep (Step 1)
- Value proposition with benefit cards showing what Transcripted does
- Dark theme matching the floating pill aesthetic
- No user action required, always canProceed

### PreviewStep (Step 2)
- Sample transcript showing a realistic meeting conversation
- 6 transcript lines with staggered reveal (0.2s per line)
- Two speakers: Sarah (recordingCoral) and Mike (processingPurple)
- Delivers "aha moment" — shows what Transcripted produces before asking for permissions
- No user action required, always canProceed

### PermissionsStep (Step 3)
- 2 simple PermissionRow components (Draft-style HStack layout):
  - **Microphone** (required): mic.fill icon. Requests via `AVCaptureDevice.requestAccess(for: .audio)`
  - **Screen Recording** (recommended): rectangle.inset.filled.and.person.filled icon. Opens System Settings
- 4 status states per row: notRequested (Grant button), pending (spinner), granted (checkmark), denied (Settings button)
- Denied state shows guidance text: "Microphone access wasn't granted. Tap 'Try Again' to see the permission prompt, or open Settings to enable it manually."
- Amber warning callout when screen recording not granted: explains system audio won't capture other participants without it
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

### HowItWorksStep (Step 5)
- Explains where the app lives (menu bar pill above dock), the global hotkey, and transcript save path
- 3 InfoCards: "Lives in your menu bar", HotkeyCard (interactive), "Transcripts saved to: ~/Documents/Transcripted/"
- Simple opacity fade-in animation; no user action required, always canProceed
- `@available(macOS 26.0, *)`

### TestRecordingStep (Step 6)
- 8-screen guided product demo (`DemoScreen` enum: meetPill, hoverExpand, duringRecording, letsRecord, liveRecording, processing, result, ready)
- Live mic level monitoring (smoothedMicLevel), countdown timer, silence detection
- Drives a real test recording via OnboardingState (`startTestRecording()`, `stopTestRecording()`)
- Auto-polls transcription result; canProceed only when `testRecordingPhase == .complete`
- `@available(macOS 26.0, *)`

## Shared Dependencies
- `@Bindable var state: OnboardingState` — NOT `@ObservedObject` (because `@Observable` macro)
- Design components: BenefitCard (from Design/Components/)
- Colors: panelCharcoal, panelCharcoalElevated, panelCharcoalSurface, panelTextPrimary/Secondary/Muted, recordingCoral, attentionGreen, errorRed
- Typography: .displayMedium/.displayLarge (titles), .bodyLarge (subtitles)

## Relationships
- Parent: `OnboardingContainerView.swift` (handles step switching, navigation buttons, auto-advance)
- State: `OnboardingState.swift` (step progression, permission status, model readiness, test recording)
- Window: `OnboardingWindow.swift` (NSWindowController, 640x560)

## Gotchas
- `@Bindable` not `@ObservedObject` — OnboardingState uses `@Observable` macro, not ObservableObject
- ModelSetupStep auto-starts download on `.onAppear` — no user action needed
- Screen recording detection uses official `CGPreflightScreenCaptureAccess()` API
- Progress capped at 0.99 to prevent premature "100%" display before CoreML compilation
- Model errors are concatenated with "\n" (both errors show if both models fail)
- The app does NOT initialize (no menus, no audio, no floating panel) until onboarding completes
- Microphone permission is REQUIRED — users cannot proceed without granting it
- TestRecordingStep requires min 8 seconds of recording before stop is valid
