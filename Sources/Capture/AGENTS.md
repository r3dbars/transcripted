# Capture Directory

## What This Does

`Sources/Capture/` owns the active global-trigger layer for:

- dictation start/stop
- meeting start/stop
- configurable physical-key triggers. Defaults: Right Option = the one dictation key (not Fn, which also opens emoji) (hold to talk, tap to keep listening), Option-M = meeting. The global paste-last-dictation binding and routing have been removed; the island’s "Paste again" action remains.

## Module

`Capture` in `.agents/modules.json`.

- **Owns:** global physical triggers and their routing (dictation, meeting start/stop).
- **Public surface:** `ContextCaptureEngine`, `PhysicalShortcutMatcher`.
- **May depend on:** UIOverlay, Dictation, Speech, Support, Observability. It sits above UIOverlay because `ContextCaptureEngine` drives `DictationSessionController` and `FloatingOverlayController` directly; a trigger-sink protocol would let it drop below the UI later.
- **Entry points:** `ContextCaptureEngine` (owned by `TranscriptedAppState`).
- **Tests:** `bash run-tests.sh --filter ContextCaptureEngine`, `--filter PhysicalShortcut`.
- **Rules:** see "Guardrails" below. Not to be confused with the capture *library* (`Sources/Support/CaptureLibrary*.swift`).

## Key Files

- `ContextCaptureEngine.swift` — accessibility-backed physical trigger detection,
  shortcut debounce, and routing into dictation or meeting handlers
- `PhysicalShortcutMatcher.swift` — Foundation-pure binding-selection helpers for
  exact/fallback shortcut precedence, release matching, and shared-modifier chord checks

## Current Hotkey Flow

- The physical dictation trigger routes into `DictationSessionController`
- Dictation has one key (the stored Push to Talk binding). `HotkeyPreferences.dictationKeyBehavior` decides its action in `PhysicalShortcutMatcher.configuredBindings`: Hold or tap (default) and Hold only register it as `.dictationPushToTalk`; Tap to toggle registers it as `.dictationHandsFree`. The old hands-free binding is still stored but no longer registered. The physical shortcut action identifies the mode passed to `DictationSessionController`
- Hold or tap makes the dictation key do both, like Handy's Auto mode: hold it and the release stops and pastes; tap it (under `DictationHoldKeyTapPolicy.tapThresholdSeconds`, no other key or modifier pressed while held) and the take flips to hands-free, so the next press stops it and that press's release is swallowed. The detector tells a tap from a hold on the tap thread (`.tapRelease`), not on the main actor, so a busy main thread can't stretch a tap into a hold. Hold only is plain Push to Talk
- `PhysicalDictationTriggerPreferences` stores the configurable trigger bindings, defaulting to Right Option for dictation and Option-M for meetings, and supporting modifier-only or keyed chords
- The configured meeting physical trigger routes meeting toggles through the
  app-provided meeting closure
- Rapid press repeats are ignored using `TranscriptedConstants.hotkeyActionDebounceInterval`
- A Push to Talk key on a modifier other shortcuts also use (the default Right Option vs Option-M) fires on press too, through `pushToTalkComboWindow`, unless a key was typed in the last second or the press would stop a take; then it waits out the 0.14 s chord delay. Only a key inside that 0.14 s window counts as a combo (`PushToTalkModifierComboWindow`) and drops the start through `.comboInterrupted`; a key later in the hold is typing and never drops the take. On a built-in or wired mic the start click still plays on press, so Right Option+M after a pause clicks and flashes the island, as Right Option hands-free did in 1.1.69
- A modifier-only hands-free key (Tap to toggle) fires on press, and `HandsFreeModifierComboTracker` follows every one until release, so Fn+arrow drops the start. One that other shortcuts also use (right Option vs Option-M) also fires on press, so the hold isn't added to every start. If a key was typed in the last second it waits for release instead, and if another key goes down while it's held the detector sends `.comboInterrupted` and the dictation that press started is dropped with no sound (`abandonDictationStartForModifierCombo`). `HandsFreeModifierComboTracker` follows the held key from the tap's own events. Don't gate it on `CGEventSource.keyState(.combinedSessionState, ...)`: the tap consumes the modifier's flagsChanged, so that state never sees it go down, and every Option+M left a stray dictation running
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

- with Tap to toggle, the dictation key starts and stops dictation
- right Option then M (or typing é with right Option+E) does not leave a dictation running
- push-to-talk starts dictation on press and stops/pastes on release
- with Hold or tap, a quick Right Option tap keeps listening and the next press pastes; a hold starts on press and pastes on release; Option+M and Right Option+E leave no dictation running (the start is dropped; after a pause it can click first); a stray key late in a hold still pastes, and within a second of typing the press waits out the 0.14 s chord delay instead
- meeting hotkey toggles meeting capture
- the configured physical dictation trigger starts/stops dictation in the expected shortcut mode
- rapid repeat presses are ignored cleanly
