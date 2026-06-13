# Capture Directory

## What This Does

`Sources/Capture/` owns the active global-trigger layer for:

- dictation start/stop
- paste-last-dictation
- meeting start/stop
- configurable physical-key dictation triggers (default: right Option)

## Key Files

- `ContextCaptureEngine.swift` — accessibility-backed physical trigger detection,
  shortcut debounce, and routing into dictation, paste-last-dictation, or meeting handlers
- `PhysicalShortcutMatcher.swift` — Foundation-pure binding-selection helpers for
  exact/fallback shortcut precedence, release matching, and shared-modifier chord checks

## Current Hotkey Flow

- The physical dictation trigger routes into `DictationSessionController`
- Dictation can run as hands-free toggle or push-to-talk, based on `HotkeyPreferences`
- `PhysicalDictationTriggerPreferences` stores the configurable trigger bindings, defaulting to right Option for hands-free dictation, Option-Shift-V for paste-last-dictation, and supporting modifier-only or keyed chords
- The configured meeting physical trigger routes meeting toggles through the
  app-provided meeting closure
- Rapid press repeats are ignored using `TranscriptedConstants.hotkeyActionDebounceInterval`
- Accessibility-backed trigger registration failures surface through `hotkeyError` so the menubar can explain why dictation trigger capture is unavailable

## Guardrails

- Keep callback-style routing tiny and bounce into `@MainActor` work
- Keep meeting routing separate from dictation routing
- Do not reintroduce screenshot/OCR assumptions here unless that feature
  returns in the same change

## Verification

After changing this directory:

```bash
bash build.sh --no-open
bash run-tests.sh
```

Manual checks:

- hands-free dictation hotkey starts and stops dictation
- push-to-talk starts dictation on press and stops/pastes on release
- paste-last-dictation uses its configured shortcut without depending on dictation shortcuts being enabled
- meeting hotkey toggles meeting capture
- the configured physical dictation trigger starts/stops dictation in the expected shortcut mode
- rapid repeat presses are ignored cleanly
