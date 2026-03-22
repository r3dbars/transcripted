# Onboarding Steps

4 SwiftUI views implementing individual onboarding steps. Hosted by OnboardingContainerView.swift (parent). All use `@Bindable var state: OnboardingState` (Observable macro).

## File Index

| File | Step | canProceed |
|------|------|------------|
| `WelcomeStep.swift` | 1. Welcome | Always true |
| `PreviewStep.swift` | 2. Preview | Always true |
| `PermissionsStep.swift` | 3. Permissions | Always true (mic optional but recommended) |
| `ModelSetupStep.swift` | 4. Model Setup | Only when parakeetReady AND diarizationReady |

## Step Details

### WelcomeStep (Step 1)
- Hero icon: waveform.circle.fill, 56pt, terracotta linear gradient
- Icon glow: 100x100 circle, 20pt blur, terracotta.opacity(0.15)
- 3 BenefitCards (from Design/Components/):
  - "Transcribe Everything" (waveform icon)
  - "Identify Speakers" (person.2.fill icon)
  - "100% Private" (lock.shield.fill icon)
- Stagger animation: 0.3s base + 0.12s per card (delays: 0.3, 0.42, 0.54s)
- Content entry: .smooth.delay(0.1)

### PreviewStep (Step 2)
- Sample transcript showing a realistic meeting conversation
- 6 animated transcript lines appear sequentially (0.3s stagger)
- Two speakers: Sarah (terracotta) and Mike (processingPurple)
- Delivers "aha moment" — shows what Transcripted produces before asking for permissions
- No user action required, always canProceed

### PermissionsStep (Step 3)
- 2 PermissionCards (from Design/Components/):
  - **Microphone** (required): mic.fill icon. Requests via `AVCaptureDevice.requestAccess(for: .audio)`
  - **Screen Recording** (optional): rectangle.inset.filled.and.person.filled icon. Checks via `CGWindowListCopyWindowInfo()` side-effect
- Card animations: offset(x: 40→0), opacity 0→1, .smooth.delay(0.2 / 0.35)
- 4 status states per card: notRequested → pending → granted/denied
- Status icons: same icon (not requested) → hourglass (pending) → checkmark.circle.fill (granted) → xmark.circle.fill (denied)
- Success message: green checkmark 20pt, bouncy.delay(0.1) scale, .smooth.delay(0.2) text

### ModelSetupStep (Step 4)
- Downloads 2 models in parallel (`async let`):
  - **Parakeet**: ~483MB expected (ASR model)
  - **Diarization**: ~36MB expected (speaker separation)
- Auto-starts download on `.onAppear` (no manual trigger)
- Progress monitoring: polls model directories every 500ms, caps at 0.99 until CoreML compilation finishes
- At >95%: phase changes to "Compiling models..."
- Tips carousel: 4 tips, rotates every 4 seconds
- Auto-complete: when modelsReady, 1.5s delay then closes onboarding
- Error handling: red exclamationmark icon, "Retry Download" PremiumButton (secondary variant)
- Card animations: offset(x: 40→0), opacity 0→1, .smooth.delay(0.2 / 0.35)

## Shared Dependencies
- `@Bindable var state: OnboardingState` — NOT `@ObservedObject` (because `@Observable` macro)
- Design components: PremiumButton, BenefitCard, PermissionCard (from Design/Components/)
- Colors: terracotta, panelTextPrimary/Secondary, attentionGreen, recordingCoral
- Typography: .displayMedium (title), .bodyLarge (subtitle)

## Relationships
- Parent: `OnboardingContainerView.swift` (handles step switching, navigation buttons, skip confirmation)
- State: `OnboardingState.swift` (step progression, permission status, model readiness)
- Window: `OnboardingWindow.swift` (NSWindowController, frosted glass, 720x680)

## Gotchas
- `@Bindable` not `@ObservedObject` — OnboardingState uses `@Observable` macro, not ObservableObject
- ModelSetupStep auto-starts download on `.onAppear` — no user action needed
- Screen recording detection is NOT a real API — uses `CGWindowListCopyWindowInfo()` side-effect (undocumented)
- Progress capped at 0.99 to prevent premature "100%" display before CoreML compilation
- Model errors are concatenated with "\n" (both errors show if both models fail)
- The app does NOT initialize (no menus, no audio, no floating panel) until onboarding completes
