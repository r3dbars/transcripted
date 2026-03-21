# Onboarding

Manages the first-run experience and gates access to the main app until permissions and models are ready.

## Step Order

1. **Welcome** (`WelcomeStep.swift`) — Value proposition with animated benefit cards
2. **Preview** (`PreviewStep.swift`) — Shows sample transcript to deliver the "aha moment"
3. **Permissions** (`PermissionsStep.swift`) — Requests microphone access (required), screen recording (optional)
4. **Model Setup** (`ModelSetupStep.swift`) — Downloads Parakeet STT and PyAnnote diarization models

## Key Files

- `OnboardingState.swift` — Central state manager using `@Observable` macro. Tracks `currentStep`, permission statuses, and model readiness flags (`parakeetReady`, `diarizationReady`).
- `Steps/WelcomeStep.swift` — Welcome screen with animated cards
- `Steps/PreviewStep.swift` — Sample transcript animation
- `Steps/PermissionsStep.swift` — Permission request UI with status mapping
- `Steps/ModelSetupStep.swift` — Model download progress with tips

## How It Gates the App

`OnboardingState.allPermissionsGranted` returns `true` only when microphone permission is authorized. The main app view checks this flag and shows the onboarding overlay if false. Screen recording is recommended but not required to proceed.

## Permissions Required

- **Microphone** — Required for audio capture
- **Screen Recording** — Optional but recommended for video meeting capture

## Threading

All state updates happen on the main actor. Permission requests use `AVAudioSession` and `ScreenCaptureKit` APIs with async callbacks.

## Next Steps

After onboarding completes, the app initializes the Core audio pipeline and begins listening for recording shortcuts.
