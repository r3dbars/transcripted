# Safe Quit overlay component fixture

This sanitized AppKit fixture links the production `OverlayDraftingView` and
`OverlayTokens` with the new unsafe-Quit and failed-checkpoint copy at the
production error-panel sizes. It creates only a temporary
prohibited-activation offscreen window. It does not launch Transcripted,
record audio, access customer data, or prove a real termination callback or
native-driver stall.

The image and measured label bounds are component layout evidence only.

The three exact production messages were rendered and visually inspected:

| Case | Panel/body | Component observation |
| --- | --- | --- |
| [quit-paused.png](quit-paused.png), in-flight timeout | 360×110 / 360×77 | Copy wraps to two lines; label `(12, 7.5, 336, 30)` fits; warning and dismiss remain visible. |
| [active-unsaved.png](active-unsaved.png), settled stop without WAV while finalization active | 360×110 / 360×77 | Copy wraps to two lines; label `(12, 7.5, 336, 30)` fits; warning and dismiss remain visible. |
| [retry-saving.png](retry-saving.png), inactive retained native audio/no WAV | 360×140 / 360×107 | Copy wraps to two lines; label `(12, 41.5, 336, 30)` and `Retry Saving` button `(133, 3.5, 94, 28)` fit; injected target closure fired on click. |

The actionable button's 28-point height is smaller than the declared
40-point minimum hit target, as with the existing recovery action. This fixture
does not test the live overlay lifecycle, driver failure, or OS termination
callback. `Retry Saving` is backed by the owning controller's guarded stop
retry in source, but the fixture substitutes an injected no-data closure.

Recreate without starting the production app:

```bash
swiftc -framework AppKit Sources/UI/Overlay/OverlayTokens.swift Sources/UI/Overlay/OverlayDraftingView.swift .agent-review/visuals/termination-quit/OverlayTerminationFixture.swift -o /private/tmp/overlay-termination-fixture-20260915
/private/tmp/overlay-termination-fixture-20260915 quit-paused .agent-review/visuals/termination-quit/quit-paused.png
/private/tmp/overlay-termination-fixture-20260915 active-unsaved .agent-review/visuals/termination-quit/active-unsaved.png
/private/tmp/overlay-termination-fixture-20260915 retry-saving .agent-review/visuals/termination-quit/retry-saving.png
```
