# Reliability

## What this directory owns

`Sources/Reliability/` contains cross-cutting runtime recovery logic that does
not belong to the UI, capture, or speech subsystems directly.

## Important file

- `WakeRecoveryCoordinator.swift` — deduplicates system-wake recovery, retries hotkey re-registration, waits for runtime readiness, and avoids duplicate recovery work across near-simultaneous wake signals

## Current behavior

- `TranscriptedAppDelegate` listens for `NSWorkspace.didWakeNotification`
- `TranscriptedAppState.handleSystemWake()` delegates recovery here
- hotkeys are unregistered and re-registered with bounded retries
- repeated wake calls reuse an in-flight or just-completed recovery task briefly to avoid stampedes

## Guardrails

- keep this layer UI-free and dependency-injected through closures
- recovery should coordinate existing subsystem behavior, not duplicate it
- changes here can affect both dictation and meeting hotkeys after sleep / wake

## Verify

```bash
bash build.sh
bash run-tests.sh
```

Manual check:

- sleep and wake the Mac, then confirm hotkeys still work and the app does not enter duplicate recovery loops
