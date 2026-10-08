# UI/Overlay module

Module `UIOverlay` in `.agents/modules.json`. Parent: `Sources/UI/AGENTS.md`.

## Owns

Everything on screen while you dictate or record, plus the dictation session itself:

- **The Notch island** (`NotchIsland*`), the only dictation, meeting and call-prompt window. One black shape grows out of the notch (or hangs from the top edge of a display without one) and carries dictation, the live meeting, the call-detected Record / Not now / Later prompt, and "Who was on this call?". The old dictation panel, meeting pill, call prompt pill and speaker naming window are deleted.
- **Three controllers that feed it:** `FloatingOverlayController` (dictation states, timers, global Esc monitor, not-pasted notice), `MeetingOverlayController` (recording state, warnings, prompts, Open, right-click "Discard Recording…") and `CapturePillController` (detected-meeting prompt and its timeout). Each keeps its state machine, timers and actions, has no window, and pushes a plain `NotchIsland*Content` snapshot; the island routes taps back. Detected-meeting Record / Not now / Remind live only in `CapturePillController`.
- **`DictationSessionController`** and its `+*.swift` extensions: start, stop, paste-back, persistence, recovery, presses, the 15-minute cap, telemetry. Speech-side control flow (recovery wait loop, model-warmup wait, STTRouter decisions) lives in `Sources/Speech/DictationSession.swift`; this folder keeps panel geometry, tooltips, accessibility labels, paste-back, persistence and telemetry.
- Dictation and meeting presentation policies. The start/stop policies and `DictationTrigger` live in Speech.

## Public surface

`DictationSessionController`, `FloatingOverlayController`, `MeetingOverlayController`, `CapturePillController`, `NotchIslandController`, `NotchIslandSpeakerReviewView`, `NotchIslandSpeakerReviewContent`, `NotchIslandSpeakerReviewPolicy`, `MeetingDurationFormatter`. AppShell builds the controllers; Capture routes presses into `DictationSessionController`; Settings asks the island for speaker review; the menu bar formats the meeting timer.

## May depend on

UIShared, AppState, Meeting, Dictation, Speech, Support, Observability, and Core's `core-vocab` tier. Only AppShell, Capture, UIMenuBar and UISettings may depend on UIOverlay. `.agents/modules.json` is the source of truth.


- Dictation owns `DictationSessionCapWarningPolicy`; the overlay consumes its countdown and accessible announcement.

## Where to start

Island:

- `NotchIslandPresentation.swift` is Foundation-pure and decides what the wings and drop-down show for every dictation, meeting and call-prompt state. A live meeting keeps the left wing while a dictation takes the right; the call prompt waits while a dictation runs; with a drop-down open the wings only report status. Change behavior here, not in the view.
- `NotchIslandGeometry.swift` is pure geometry (notch detection, content-sized wings, the 460 pt drop-down, envelope, screen-width clamp) plus `NotchIslandMotion` (springs, fades, blur timing).
- `NotchIslandController.swift` builds the panel at launch (`prewarm`), picks the display once per show (`NotchIslandScreenChoice`: for a dictation with several displays, the one holding the focused text field, else under the pointer, else main), and keeps it while shown. Motion is Core Animation: fixed-size envelope, a mask layer that springs out of the notch, nothing resizes mid-animation. Mouse monitors make the envelope click-through except over the island and drive hover (drop-down opens 0.12 s in, 0.38 s out; messages and prompts open it themselves; a finished dictation lingers about 2.6 s with Copy / Paste again).
- `NotchIslandView.swift` is AppKit drawing (no SwiftUI hosting), with `NotchIslandButton`, `NotchIslandBarsView`, `NotchIslandView+Blur` (show-time blur set up once during the alpha-0 prewarm). `NotchIslandPanel.swift` is the borderless non-activating status-level panel.
- Dictation waveform: `NotchIslandLevelScroller` steps bars at `audioMeteringInterval` (20/s) on the display clock, at most once per frame, no catch-up burst. `NotchIslandController+DictationBars.swift` feeds it and runs `NotchIslandFrameClock` (an `NSView.displayLink`) only while a take listens on screen.
- Meeting wing levels: one row (`NotchIslandMeetingLevelRow`, drawn by `NotchIslandMeetingLevelsView` in `NotchIslandBarsView.swift`). Your bars enter on the right and move left, the call's enter on the left and move right, and they cross; at rest the whole row is dim accent dots and only your audible bars go full accent. Core publishes levels only every 0.15 s, so readings just pick the next bar and the view's own `Timer` steps the row every 0.11 s (no display link). The timer stops once the row is at rest with no readings, because a hidden island keeps its last wing items. Dictating mid-meeting swaps the row for the mic icon and the 9-bar waveform.
- Dictation hover: `NotchIslandDictationPreviewView`, `NotchIslandDropView+Dictation`, `NotchIslandController+DictationPreview` show a four-line window onto the whole take from `LiveDictationCaptions` (follows the newest words unless you scroll up; last two words dimmed), then Cancel and "Insert into <app>". The words stay through Writing and Pasted and crossfade into the written text, which the recent-insert hover then keeps. The controller sets `NotchIslandDictationContent.showsLivePreview`. To keep hover cheap, `NotchIslandView` keeps the drop-down built between hovers while the take is spoken (`NotchIslandDrop.staysBuiltBetweenHovers`, `NotchIslandController+DictationDrop.swift`), the app icon is drawn once per take (`NotchIslandAppIconCache`), and the drop-down height is measured once per render. During a meeting the hover is the meeting's.
- Meeting drop-down: `NotchIslandLiveTranscriptView` + `NotchIslandController+LiveTranscript.swift` show the scrolling live transcript fed from `LiveMeetingCaptions` (one view kept across rebuilds; appends finished words, replaces only the faded tail). Copy all (`meetingCopyTranscript`) is handled by the island.
- Speaker review: `NotchIslandSpeakerReviewPolicy` (Foundation-pure rules), `NotchIslandSpeakerReviewView`, `NotchIslandSpeakerReviewControls`. It is the only post-meeting review. Yes/No or a name box per voice; the first three calendar invitees as one-tap names; autocomplete from saved people, invitees first; the 20 s Later ring runs only while the review is on screen and not hovered; Return/Tab and Done/Later save the arrowed-to row, else an exact match, else the typed name as a new person, never a longer saved name. A calendar 1:1 prefills the remote voice's name. "All me" keeps local mic voices as You; "Not a person" discards (Keep as You wins over discard). It builds the `SpeakerNameUpdate`s Core writes back and reports analytics with `surface: speaker_review_island`. When every remote voice was recognized it lists who was on the call, asks nothing, and offers "Not <name>?" corrections; Core queues that review only while `reviewListsRecognizedVoicesProvider` says the island is selected, and it closes itself after about two minutes even while hidden (`NotchIslandSpeakerReviewPolicy.recognizedOnlyHardCapSeconds`).
- `CapturePillController` owns the call-prompt countdown. `CallPromptTimeoutClock` pauses while the pointer is over the island and while the prompt waits behind a dictation (off-screen waiting capped at two minutes, then it expires unanswered).
- `MeetingPromptPriority` is the one precedence rule for the overlay's four warning prompts (audio inactivity, system-audio degradation, route instability, mic boost). `MeetingDurationFormatter` is timer formatting.

Dictation session (`DictationSessionController` plus):

- `+RecordingStart` (opening the mic, warmup, recovery wait, permission errors), `+Stop` (checkpoint, transcribe, paste or save), `+PasteBack` (not-pasted notices, the paste, Auto Enter), `+Persistence`, `+Recovery` (saved-audio cleanup, Quit admission, Retry Saving, interruptions), `+Presses` (queued starts, modifier combos, early release, a tap keeping the take listening), `+SessionCap`, `+Muffle` (mute other audio while dictating; rules in `DictationMufflePolicy`), `+Telemetry`, and `DictationSessionDeliveryTypes`.
- `DictationStartAdmission` decides whether a press becomes a take and counts it. A press while dictating or queued is not counted yet; every other press is counted (`dictation_start_requested`) before any guard can refuse it, and each refusal reports its own reason. `DictationSessionPipeline` holds the start/stop wiring behind `DictationSessionPipelineHost` (the controller conforms): refusal messages, Try Again marked as retries, the start click (once per session, queued before the fast-path mic start), stop from the stale-task fence through checkpoint and model wait, empty takes (mis-tap, no speech, Paste Anyway, saved recording, Retry Saving) and Quit. Tests run both on fakes.
- Policies: `DictationEscapeCancelPolicy` (a short take cancels on the first Esc; a long one asks "Press Esc again to discard" and a second press within 3 s discards), `DictationQueuedStartPolicy` (a press while the last take is transcribing waits up to 2 s instead of being refused), `DictationStartCuePolicy` (the start click plays on key press for a built-in or wired mic, but waits until recording starts on a headset, any input that could be one, or a mic `PinnedDictationSpeedPath` moved back to the engine), `DictationSessionCapWarningPolicy` (live "28s left" in the last 30 s before the 15-minute cap, worded for push-to-talk vs a hands-free take), `DictationWarmupPresentationPolicy` (model-warmup copy, before vs after the stop; `DictationPostStopModelWaitPolicy` keeps paste-back on the original app after a long wait), `DictationNoSpeechPresentationPolicy` (no-speech copy; "Transcribe It" runs the same import as Capture → Transcribe Audio File), `DictationMicrophoneLoadingPresentationPolicy`, `DictationMeterPolicy` (when the meter renders, clamps level), `DictationOverlayPlacementPolicy` (AX rect to Cocoa, for display choice), `DictationStartActivation` (optional foreground-activation retry after a failed background mic start; a recovery attempt, not a readiness signal).

## Tests

```bash
bash run-tests.sh --filter NotchIsland
bash run-tests.sh --filter Dictation
bash run-tests.sh --filter MeetingPill
bash run-tests.sh --filter CapturePill
```

Also `MeetingPromptPriorityTests`, `MeetingDurationFormatterTests`, `DictationOverlayPlacementPolicyTests`, `OverlayScreenSharePrivacyTests` (scans all of `Sources/UI`). The island is excluded from screenshots, so review a visual change by rendering `NotchIslandView` offscreen with `NSView.cacheDisplay(in:to:)` (`layer.render(in:)` drops AppKit text).

## Rules

- **Keep the product surface.** Meeting detection's record / dismiss / remind flow and the speaker review stay reachable from the island.
- **Out of screen capture by default.** The island panel sets `sharingType = .none`, or `.readOnly` only when the user turned on `NotchIslandPreferences.visibleInScreenSharing`. `OverlayScreenSharePrivacyTests` checks both.
- **Never steal focus.** Panels are non-activating. The island takes the keyboard only while someone types in "Who was on this call?" (`acceptsKeyForTyping`); when naming ends or the review leaves the screen, `NotchIslandController` hands the keyboard back to the app they were in without hiding the island or activating Transcripted. The panel may sit over the menu bar.
- **AppKit renderers, controller-owned state.** Controllers push `update(...)` into views; no SwiftUI hosting in the island.
- **AirPods.** Nothing here builds an `AVAudioEngine` or touches `inputNode`. The start click waits for recording on a headset (`DictationStartCuePolicy`); read `Sources/Speech/AGENTS.md` before changing start timing.
- **Source pins.** `DictationSessionController.swift` and `MeetingOverlayController.swift` are heavily pinned; run `python3 scripts/dev/check-source-pins.py --changed-only` before editing.
