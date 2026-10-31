# Capture

Global physical triggers: the dictation key and the meeting key, from a CGEvent tap. Not the capture *library* (`Sources/Support/CaptureLibrary*.swift`, where saved Markdown and audio live).

## Module

`Capture` in `.agents/modules.json`.

- **Owns:** global physical triggers and their routing (dictation, meeting start/stop).
- **Public surface:** `ContextCaptureEngine` (owned by `TranscriptedAppState`), `PhysicalShortcutMatcher`, `PhysicalShortcutTapPolicy`, `SecureKeyboardEntryWarningPolicy`.
- **May depend on:** UIOverlay, Dictation, Speech, Support, Observability. It sits above UIOverlay because the engine drives `DictationSessionController` and `FloatingOverlayController` directly.
- **Tests:** `bash run-tests.sh --filter ContextCaptureEngine`, `--filter PhysicalShortcut`, `--filter HotkeyPreferences`, `--filter SecureKeyboardEntry`.

## Files

- `ContextCaptureEngine.swift` — shortcut debounce, `hotkeyError`, and the routing switch in `handlePhysicalShortcut`. The event tap itself (`PhysicalShortcutDetector`, delayed modifier presses) is in `PhysicalShortcutDetector.swift`. `secureKeyboardEntryNotice` is the menu-bar warning while another app holds Secure Keyboard Entry and dictation is bound to a non-modifier key.
- `PhysicalShortcutDetector.swift` — the CGEvent tap (`keyDown` / `keyUp` / `flagsChanged` / `NSSystemDefined`). Media-key events always pass through and never fire dictation. NSSystemDefined skips `NSEvent` wrapping unless dictation is F1–F12. F1–F20 matching ignores Fn; Cmd, Ctrl, Opt, and Shift still have to match. Logs `physical_shortcut_tap_disabled` with the reason and whether it was re-enabled. Other diagnostics hop through `onLog` onto the main actor.
- `PhysicalShortcutTapPolicy.swift` — Foundation-pure tap mask, media-key parse (`NX_KEYTYPE_PLAY` = 16 for F8), NSEvent-wrap gate, F8 press/repeat/release sequence, modifier-mismatch logging (saved dictation key only, never the meeting key), tap-disable and install context. Fast-tested so a macOS Fn/media-key change is diagnosable without reading Sources as text.
- `ContextCaptureEngine+DictationKeys.swift` — the dictation keys as session commands: Push to Talk press, release and combo-interrupt, and the hands-free toggle. Press/release semantics live in `DictationHotkeyRouter` (`Sources/Speech/DictationTrigger.swift`).
- `ContextCaptureEngine+SecureKeyboardEntry.swift` — polls Secure Keyboard Entry (~2.5 s) and also checks on app activation and `flagsChanged`, because a CGEventTap cannot see F8 `keyDown` while another app holds it. Queued activation/`flagsChanged` work after stop must not restart the poll. Harness launches skip the watch.
- `SecureKeyboardEntryWarningPolicy.swift` — Foundation-pure on/off, owner-change, modifier-silence, notice-text rebuild, and local-log decisions. Fast tests drive it with snapshots.
- `SecureEventInputSource.swift` — Carbon `IsSecureEventInputEnabled()` and the public IOKit `IOConsoleUsers` / `kCGSSessionSecureInputPID` probe on the IORegistry root, plus `NSRunningApplication` / `proc_name` naming, behind protocols. Never shells out to `ioreg`.
- `SecureKeyboardEntryMonitor.swift` — holds watch state and talks to those protocols so tests can fake Carbon/IOKit. Caches the owner lookup for the rest of a hold; the poll refreshes it.
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
- **Secure Keyboard Entry:** a non-modifier dictation key (F8) can go silent while another app holds Secure Keyboard Entry, and the tap cannot see that F8 press. Warn once per owner in the menu bar; rebuild the copy if the bound key or resolved owner name changes; clear when it releases; stay quiet when dictation is a modifier (that binding still arrives as `flagsChanged`). Log `secure_input_state_changed` locally only — never PostHog or Sentry. Do not treat our own PID as a foreign owner.
- Keep tap callbacks tiny and bounce into `@MainActor`. Keep meeting routing separate from dictation routing.
- A saved F1–F20 dictation key ignores `maskSecondaryFn` when matching, so F8 fires with or without the implicit Fn flag macOS attaches in media-key mode. Arrow keys still need an exact Fn match. Local diagnostics: `hotkey_fkey_arrived_as_media_key` (rate-limited 5s, never swallows play/pause), `hotkey_modifier_mismatch` (saved dictation key only), `physical_shortcut_trigger_installed`. None of these go to PostHog. A stored F8 vs Fn+F8 clash with the meeting shortcut is a duplicate: Settings shows it, and the tap does not install the meeting binding.
- No screenshot or OCR assumptions here unless that feature returns in the same change.

## Verify

`bash build.sh --no-open`, `bash run-tests.sh`, then by hand:

- Tap to toggle: the key starts and stops dictation.
- Hold or tap: a quick Right Option tap keeps listening and the next press pastes. A hold starts on press and pastes on release. Right Option then M, or é via Right Option+E, leaves no dictation running. A stray key late in a hold still pastes. Within a second of typing, the press waits out the chord delay.
- The meeting key toggles meeting capture. Rapid repeats are ignored.
- Sleep and wake: see `Sources/Reliability/AGENTS.md`.
- Bind dictation to F8, enable Secure Keyboard Entry in Terminal or another app: the menu bar names that app and says shortcuts are blocked until it releases. Rebinding the key or a later-resolved owner name must update the copy. Right Option as the dictation key must stay quiet. Releasing Secure Keyboard Entry clears the notice.
