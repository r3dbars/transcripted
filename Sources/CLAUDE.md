# Sources Root

## What This Contains

Top-level app bootstrap and shared configuration for the Draft-first app that now lives in `r3dbars/transcripted`.

Current root Swift files: **5**

| File | Purpose |
|---|---|
| `DraftApp.swift` | App entry point, scene setup, and top-level boot orchestration |
| `DraftAppState.swift` | Shared app state container used across the app lifecycle |
| `DraftConstants.swift` | Cross-cutting constants and static configuration values |
| `DraftPaths.swift` | Filesystem paths and data-location helpers |
| `HotkeyPreferences.swift` | User-configurable hotkey preferences and persistence |

## Current Source Layout

`Sources/` currently contains **122** Swift files total, grouped roughly like this:
- `Accessibility/` — AX helpers
- `API/` — currently only `BetaConfig.swift`
- `Capture/` — screenshot/context capture
- `Dictation/` — dictation session plumbing
- `Draft/` — pure draft/diff helpers
- `Meeting/` — meeting capture and review pipeline
- `Observability/` — logging, telemetry, crash/update hooks
- `Speech/` — Parakeet STT wrapper
- `Style/` — style-learning utilities
- `UI/` — AppKit views/controllers

Historical placeholder directories like `Analysis/`, `Feedback/`, `Local/`, and `Prompts/` still have CLAUDE docs checked in, but currently have no live Swift files on `main`.

## Gotchas
- The old standalone Transcripted architecture docs are stale for `main`; use this file plus the active subdirectory CLAUDE docs.
- If you are looking for the current onboarding flow, it now lives in `Sources/UI/PermissionsOnboardingView.swift`, not an older multi-step onboarding tree.
