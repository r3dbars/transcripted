# Onboarding — CLAUDE.md

## Purpose
Four-step first-launch onboarding flow: Welcome → How It Works → Permissions → Ready. Requests microphone, screen recording, and optionally Reminders permissions.

## Key Files

| File | Responsibility |
|------|---------------|
| `OnboardingState.swift` | State management, step tracking, completion persistence (UserDefaults) |
| `OnboardingWindow.swift` | NSWindowController for the onboarding window |
| `OnboardingContainerView.swift` | Step container with navigation and progress |
| `Steps/WelcomeStep.swift` | Step 1: App introduction |
| `Steps/HowItWorksStep.swift` | Step 2: Feature overview |
| `Steps/PermissionsStep.swift` | Step 3: Request mic, screen recording, reminders |
| `Steps/ReadyStep.swift` | Step 4: Completion with celebration animation |
| `Animations/ParticleExplosionView.swift` | Celebration particle effects for completion |

## Flow

```
App launch → OnboardingState.hasCompletedOnboarding() check
  → false: show OnboardingWindow
    Step 1 (Welcome) → Step 2 (How It Works) → Step 3 (Permissions) → Step 4 (Ready)
    → onComplete callback → setupApp() runs
  → true: skip to setupApp()
```

## Permissions Requested

| Permission | Required | Purpose |
|-----------|----------|---------|
| Microphone | Yes | Record voice audio |
| Screen Recording | For system audio | Capture meeting/call audio via process taps |
| Reminders | Optional | Send extracted action items to Apple Reminders |

## Common Tasks

| Task | Files to touch | Watch out for |
|------|---------------|---------------|
| Add onboarding step | New step view, `OnboardingContainerView.swift`, `OnboardingState.swift` | Update step count and navigation |
| Fix permissions | `Steps/PermissionsStep.swift` | macOS permission APIs are async |
| Change onboarding theme | Step views + `DesignTokens.swift` | Warm cream + terracotta color scheme |
| Test onboarding | Menu bar → "Reset Onboarding (Debug)" | DEBUG builds only |

## Dependencies

**Imports from Design/**: DesignTokens (onboarding color scheme)
**Imported by**: TranscriptedApp.swift (shows onboarding or skips to setupApp)
