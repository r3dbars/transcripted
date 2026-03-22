# Onboarding Steps

2 SwiftUI views implementing individual onboarding steps. Hosted by OnboardingContainerView.swift (parent). All use `@Bindable var state: OnboardingState` (Observable macro).

## File Index

| File | Step | canProceed |
|------|------|------------|
| `PermissionsStep.swift` | 1. Permissions | Always true (mic optional but recommended) |
| `ModelSetupStep.swift` | 2. Model Setup | Only when parakeetReady AND diarizationReady |

## Step Details

### PermissionsStep (Step 1)
- 2 permission cards (dark theme, panelCharcoalElevated background):
  - **Microphone**: mic.fill icon. Requests via `AVCaptureDevice.requestAccess(for: .audio)`
  - **Screen Recording**: rectangle.inset.filled.and.person.filled icon. Checks via `CGWindowListCopyWindowInfo()` side-effect
- 4 status states per card: notRequested → pending → granted/denied
- Status icons: same icon (not requested) → hourglass (pending) → checkmark.circle.fill (granted) → xmark.circle.fill (denied)
- No hover effects, no animations, no success celebration

### ModelSetupStep (Step 2)
- Downloads 2 models in parallel (`async let`):
  - **Parakeet**: ~483MB expected (ASR model)
  - **Diarization**: ~36MB expected (speaker separation)
- Auto-starts download on `.onAppear` (no manual trigger)
- Progress monitoring: polls model directories every 500ms, caps at 0.99 until CoreML compilation finishes
- At >95%: phase changes to "Compiling models..."
- Auto-advance: when modelsReady, container auto-completes after 1.5s
- Error handling: errorRed icon, "Retry Download" PremiumButton (secondary variant)
- No hover effects, no tips carousel

## Shared Dependencies
- `@Bindable var state: OnboardingState` — NOT `@ObservedObject` (because `@Observable` macro)
- Design components: PremiumButton (from Design/Components/)
- Colors: panelCharcoal, panelCharcoalElevated, panelCharcoalSurface, panelTextPrimary/Secondary/Muted, terracotta, successGreen, errorRed
- Typography: .displayMedium (title), .bodyLarge (subtitle)

## Relationships
- Parent: `OnboardingContainerView.swift` (handles step switching, navigation buttons, skip confirmation, auto-advance)
- State: `OnboardingState.swift` (step progression, permission status, model readiness)
- Window: `OnboardingWindow.swift` (NSWindowController, dark opaque background, 560x520)

## Gotchas
- `@Bindable` not `@ObservedObject` — OnboardingState uses `@Observable` macro, not ObservableObject
- ModelSetupStep auto-starts download on `.onAppear` — no user action needed
- Screen recording detection is NOT a real API — uses `CGWindowListCopyWindowInfo()` side-effect (undocumented)
- Progress capped at 0.99 to prevent premature "100%" display before CoreML compilation
- Model errors are concatenated with "\n" (both errors show if both models fail)
- The app does NOT initialize (no menus, no audio, no floating panel) until onboarding completes
