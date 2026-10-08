# Reliability

Part of the `Support` module in `.agents/modules.json` (with `Sources/Support/` and `Sources/Accessibility/`), so it may depend only on Core's `core-vocab` tier. The module card is in `Sources/AGENTS.md`.

## What this owns

One file: `WakeRecoveryCoordinator.swift`, the system-wake recovery for global hotkeys. It is `@MainActor`, UI-free, and takes everything as closures.

- Wiring: `TranscriptedApp.swift` observes `NSWorkspace.didWakeNotification` and calls `TranscriptedAppState.handleSystemWake()`, which hands the closures (unregister, register, current error, readiness wait) to the coordinator. `TranscriptedAppState` also owns the retry numbers: 3 attempts, 0.5 s apart.
- Recovery: unregister then re-register the hotkeys, up to the attempt limit, stopping at the first attempt with no `hotkeyError`. Then wait for runtime readiness.
- De-duping: a wake while a recovery is running joins it. A wake within 1 s of a *successful* recovery reuses its result. A failed recovery is never reused, so the next wake tries again. Joined calls return `performedRecovery: false`, and the caller skips its telemetry for them.

## Invariants

- Coordinate existing subsystems, don't duplicate them. Speech and audio wake recovery stays in `Sources/Speech/` (`ParakeetEngine` observes the wake itself), and Writing and the overlay have their own `handleSystemWake()`.
- Keep it UI-free and injected, so `Tests/WakeRecoveryCoordinatorTests.swift` can run it with fake closures and a fake sleep.
- A bug here breaks dictation and meeting hotkeys after sleep. Capture's side of the same flow is `Sources/Capture/AGENTS.md`.

## Test

- `bash run-tests.sh --filter WakeRecovery`; `Tests/Integration/WakeRecoveryIntegrationSmoke.swift` via `bash run-integration-smoke.sh`.
- Manual: sleep and wake the Mac, then check both hotkeys work and the log shows one recovery, not a loop.
