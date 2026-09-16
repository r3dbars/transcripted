# Dictation recovery overlay component fixture

This folder holds sanitized, native AppKit component renders of the production
`OverlayDraftingView` and `OverlayTokens` at the current error-panel body size.
The text matches the current undecoded-audio, startup-pending-recovery,
missing-recovery, and model-failure messages, with the production `Show Audio`
action label where recovery exists.

The renderer creates a prohibited-activation, temporary offscreen AppKit window
and an injected action closure. It does not launch Transcripted, reveal customer
audio, access the production clipboard, or exercise the actual dictation/ASR,
Finder reveal, Accessibility, or live panel lifecycle. These PNGs are component
layout evidence only; they are not customer or real-device confirmation.

Source: `Sources/UI/Overlay/OverlayDraftingView.swift`, `OverlayTokens.swift`,
`DictationNoSpeechPresentationPolicy.swift`, and
`DictationSessionController.swift` at integration HEAD `40bb0e57`. The corrected
recovery route matches the actual app menu entry `Capture > Transcribe Audio
File…` in `Sources/TranscriptedMenuCommands.swift`; that entry opens the audio
file picker through `menuImportAudio()`.

## Observed fixture results

The production `errorPanelSize()` rule yields a 360×140-point panel for the three
long actionable messages, leaving a 360×107-point drafting body after the
32-point header and 1-point divider. The long no-action fallback uses a
360×110-point panel and 360×77-point body. The renderer captured these bodies
at the Mac's 2× backing scale and the PNGs were visually inspected:

| Variant | Image | Layout/interaction |
| --- | --- | --- |
| Undecoded audio with retained WAV | [undecoded-audio-40bb0e57.png](undecoded-audio-40bb0e57.png) | Corrected menu-route copy wraps to two readable lines; label is inside bounds; `Show Audio` is fully visible and an injected target closure was invoked by button click. |
| Pending stopped recording at startup | [startup-pending-recovery-40bb0e57.png](startup-pending-recovery-40bb0e57.png) | Corrected menu-route copy wraps to two readable lines, not three; label and `Show Audio` are inside bounds and the injected target closure was invoked. |
| Undecoded audio without recoverable WAV | [missing-recovery.png](missing-recovery.png) | Exact fallback copy wraps to two readable lines; no `Show Audio` button is shown, matching the controller branch. |
| Model failure with retained WAV | [model-failure.png](model-failure.png) | Exact production model-failure copy wraps to two readable lines; `Show Audio` is fully visible and an injected target closure was invoked. |

In the actionable bodies, the button frame is 89×28 points at y=3.5; it is
not clipped, but the lower clearance is tight and the control is smaller than
`OverlayTokens.minimumHitTarget` (40 points). This fixture establishes visible
copy and target wiring in the component, not live panel clickability or Finder
reveal. The actual production `Show Audio` closure points at
`NSWorkspace.activateFileViewerSelecting([recovery.url])` only when a recovery
checkpoint exists; this renderer intentionally substitutes an injected closure.

Recreate, without touching production app state:

```bash
swiftc -framework AppKit Sources/UI/Overlay/OverlayTokens.swift Sources/UI/Overlay/OverlayDraftingView.swift .agent-review/visuals/reliability-2026-09-15/OverlayRecoveryFixture.swift -o /private/tmp/overlay-recovery-fixture-20260915
/private/tmp/overlay-recovery-fixture-20260915 undecoded-audio .agent-review/visuals/reliability-2026-09-15/undecoded-audio-40bb0e57.png
/private/tmp/overlay-recovery-fixture-20260915 startup-pending-recovery .agent-review/visuals/reliability-2026-09-15/startup-pending-recovery-40bb0e57.png
/private/tmp/overlay-recovery-fixture-20260915 missing-recovery .agent-review/visuals/reliability-2026-09-15/missing-recovery.png
/private/tmp/overlay-recovery-fixture-20260915 model-failure .agent-review/visuals/reliability-2026-09-15/model-failure.png
```
