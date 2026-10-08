# Capture

Global physical triggers: the dictation key and the meeting key, from a CGEvent tap. Not the capture *library* (`Sources/Support/CaptureLibrary*.swift`, where saved Markdown and audio live).

## Module

`Capture` in `.agents/modules.json`.

- **Owns:** global physical triggers and their routing (dictation, meeting start/stop).
- **Public surface:** `ContextCaptureEngine` (owned by `TranscriptedAppState`), `PhysicalShortcutMatcher`.
- **May depend on:** UIOverlay, Dictation, Speech, Support, Observability. It sits above UIOverlay because the engine drives `DictationSessionController` and `FloatingOverlayController` directly.
- **Tests:** `bash run-tests.sh --filter ContextCaptureEngine`, `--filter PhysicalShortcut`, `--filter HotkeyPreferences`.

## Files

- `ContextCaptureEngine.swift` — the event tap (`PhysicalShortcutDetector`), shortcut debounce, delayed modifier presses, `hotkeyError`, and the routing switch in `handlePhysicalShortcut`.
- `ContextCaptureEngine+DictationKeys.swift` — the dictation keys as session commands: Push to Talk press, release and combo-interrupt, and the hands-free toggle. Press/release semantics live in `DictationHotkeyRouter` (`Sources/Speech/DictationTrigger.swift`).
- `PhysicalShortcutMatcher.swift` — Foundation-pure helpers: `configuredBindings`, exact/fallback binding precedence, release matching, and the tap and combo trackers below.

## Dictation key behavior

Defaults (`Sources/Support/PhysicalDictationTriggerPreferences.swift`): Right Option for dictation (not Fn, which also opens emoji), Option-M for meetings. There is one dictation key, the stored Push to Talk binding. `HotkeyPreferences.dictationKeyBehavior` picks what it does, in `PhysicalShortcutMatcher.configuredBindings`:

- **Hold or tap** (default): registers as `.dictationPushToTalk`. Hold, and the release stops and pastes. Tap it (held under `DictationHoldKeyTapPolicy.tapThresholdSeconds`, no other key or modifier meanwhile) and the take flips to hands-free: the next press stops it and that press's release is swallowed.
- **Hold only**: the same `.dictationPushToTalk` registration, plain Push to Talk with no tap flip.
- **Tap to toggle**: registers as `.dictationHandsFree`.

The paste-last-dictation shortcut is no longer registered. The unused paste-last action, detector routing, callback and binding helpers have been removed; the island's Paste again action and feedback remain. The old hands-free binding is retained only for the one-key migration and reset, not registered as a separate shortcut.

## Invariants

- **Tap vs hold is decided on the tap thread** (`PushToTalkTapTracker`, phase `.tapRelease`), not the main actor, so a busy main thread can't stretch a tap into a hold.
- **A modifier that other shortcuts share** (Right Option vs Option-M) fires on press, so no start waits for a release. It waits out `modifierChordDelay` (0.14 s) instead only if a key was typed in the last second (`typingWindowForModifierCombos`) or the press would stop a running take, since a stop can't be undone.
- **Combo drops the start.** A key down inside that 0.14 s window (`PushToTalkModifierComboWindow`) sends `.comboInterrupted`, and the dictation that press started is dropped with no sound (`abandonDictationStartForModifierCombo`). A key later in the hold is typing and never drops the take. On a built-in or wired mic the start click can still play first, so Right Option+M after a pause can click and flash the island.
- **Tap to toggle is followed too.** `HandsFreeModifierComboTracker` follows a press that starts a take until release, so Fn+arrow can't leave dictation running. It trusts only the tap's own events. Never gate it on `CGEventSource.keyState(.combinedSessionState, ...)`: the tap consumes the modifier's flagsChanged, so that state never sees it go down, and every Option+M left a stray dictation running.
- Rapid repeats are ignored with `TranscriptedConstants.hotkeyActionDebounceInterval`.
- Registration failures surface as `hotkeyError`, which the menubar shows. The Accessibility one has its own message (`accessibilityPermissionErrorMessage`) so the menubar can offer to open that pane.
- Keep tap callbacks tiny and bounce into `@MainActor`. Keep meeting routing separate from dictation routing.
- No screenshot or OCR assumptions here unless that feature returns in the same change.

## Verify

`bash build.sh --no-open`, `bash run-tests.sh`, then by hand:

- Tap to toggle: the key starts and stops dictation.
- Hold or tap: a quick Right Option tap keeps listening and the next press pastes. A hold starts on press and pastes on release. Right Option then M, or é via Right Option+E, leaves no dictation running. A stray key late in a hold still pastes. Within a second of typing, the press waits out the chord delay.
- The meeting key toggles meeting capture. Rapid repeats are ignored.
- Sleep and wake: see `Sources/Reliability/AGENTS.md`.
