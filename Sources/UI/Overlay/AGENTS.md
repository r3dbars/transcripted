# UI/Overlay module

Module `UIOverlay` in `.agents/modules.json`. The file-by-file notes stay in `Sources/UI/AGENTS.md` ("Overlay/"); this page is the module card.

## Owns

Everything on screen while you dictate or record, plus the dictation session itself:

- The Notch island (`NotchIsland*`): the only dictation, meeting and call-prompt window since #1946. One black shape grows out of the notch (or hangs from the top edge of a display without one) and carries dictation, the live meeting, the call-detected Record / Not now / Later prompt, and "Who was on this call?".
- The three controllers that feed it: `FloatingOverlayController` (dictation), `MeetingOverlayController` (recording state, warnings, prompts) and `CapturePillController` (the detected-meeting prompt and its timeout). Each keeps its own state machine, timers and actions and pushes a plain `NotchIsland*Content` snapshot to the island; the island routes taps back. None of them has a window of its own: the old dictation panel, meeting pill, call prompt pill and speaker naming window are deleted.
- `DictationSessionController` and its `+*.swift` extensions: start, stop, paste-back, persistence, recovery, presses, the 5-minute cap and telemetry. `DictationSessionPipeline` and `DictationStartAdmission` hold the start/stop wiring behind protocols so tests run them on fakes.
- The dictation presentation policies (`Dictation*Policy`, `DictationStartActivation`; the start/stop policies and `DictationTrigger` live in Speech) and the meeting policies (`MeetingPromptPriority`, `MeetingDurationFormatter`).

## Public surface

What other modules name today: `DictationSessionController`, `FloatingOverlayController`, `MeetingOverlayController`, `CapturePillController`, `NotchIslandController`, `NotchIslandSpeakerReviewView`, `NotchIslandSpeakerReviewContent`, `NotchIslandSpeakerReviewPolicy`, `MeetingDurationFormatter`. AppShell builds the controllers; Capture routes presses into `DictationSessionController`; Settings asks the island for speaker review; the menu bar formats the meeting timer.

## May depend on

UIShared, AppState, Meeting, Dictation, Speech, Support, Observability, and Core's `core-vocab` tier. Only AppShell, Capture, UIMenuBar and UISettings may depend on UIOverlay. `.agents/modules.json` is the source of truth; `python3 scripts/dev/check-module-boundaries.py --explain <file>` answers for one file.

Grandfathered crossings (`.agents/module-boundary-baseline.json`):

- Into Core outside `core-vocab`: `MeetingOverlayController` (`CaptureRouteStabilizationOutcome`, `DisplayStatus`) and `NotchIslandSpeakerReviewView` (the speaker-review value types).
- From below: Dictation's cap timer names `DictationSessionCapWarningPolicy`. Moving that policy file down into Dictation removes the edge.

## Entry points

- `NotchIslandController.swift` — builds the island panel at launch (`prewarm`), picks a display per show, runs the Core Animation grow/shrink, and owns hover and click-through.
- `NotchIslandPresentation.swift` / `NotchIslandGeometry.swift` — Foundation-pure rules for what shows where, and the geometry and springs. Change behavior here, not in the view.
- `NotchIslandLiveTranscriptView.swift` — the recording drop-down's scrolling live transcript. The controller keeps one alive across drop-down rebuilds and feeds it from `LiveMeetingCaptions`; it appends finished words and replaces only the faded tail, so long meetings stay cheap. Copy all (`meetingCopyTranscript`) is handled by the island itself, in `NotchIslandController+LiveTranscript.swift`.
- `NotchIslandDictationPreviewView.swift` / `NotchIslandDropView+Dictation.swift` / `NotchIslandController+DictationPreview.swift` — the dictation hover: a four-line window onto the whole take (newest line at the bottom; no fade, so scrolling up clearly stops at the start), scrollable back to the start (it follows the newest words unless you scrolled up) from `LiveDictationCaptions` (newest at the bottom, last two words dimmed), then Cancel and "Insert into <app>" with the app's icon. The words stay through Writing and Pasted and crossfade into the written text, which the recent-insert hover then keeps. The controller keeps one preview view alive like the live transcript and sets `NotchIslandDictationContent.showsLivePreview`; during a meeting the hover is the meeting's.
- `DictationSessionController.swift` — `startDictation` / stop entry; the STT control flow it composes lives in `Sources/Speech/DictationSession.swift`.
- `MeetingOverlayController.swift` / `CapturePillController.swift` — meeting pill state and the detected-meeting prompt (the record / dismiss / remind flow is a protected product surface).

## Tests

```bash
bash run-tests.sh --filter NotchIsland
bash run-tests.sh --filter Dictation
bash run-tests.sh --filter MeetingPill
bash run-tests.sh --filter CapturePill
```

Also `MeetingPromptPriorityTests`, `MeetingDurationFormatterTests`, `DictationOverlayPlacementPolicyTests`, and `OverlayScreenSharePrivacyTests` (it scans all of `Sources/UI`). The island normally can't be screenshotted; review a visual change by rendering `NotchIslandView` offscreen with `NSView.cacheDisplay(in:to:)`.

## Rules

- **Keep the product surface.** Meeting detection's record / dismiss / remind flow and the speaker review stay reachable from the island.
- **Out of screen capture by default.** The old panels set `sharingType = .none`. The island does too unless the user turned on `NotchIslandPreferences.visibleInScreenSharing` (then `.readOnly`). `OverlayScreenSharePrivacyTests` checks it.
- **Never steal focus.** Panels are non-activating. The island takes the keyboard only while someone types a name in "Who was on this call?", then hands it back to the app they were in without activating Transcripted.
- **AppKit renderers, controller-owned state.** Controllers own Combine subscriptions and push `update(...)` calls into views; no SwiftUI hosting in the island.
- **AirPods.** Nothing here builds an `AVAudioEngine` or touches `inputNode`. The start click waits for recording to start on a headset (`DictationStartCuePolicy`); read `Sources/Speech/AGENTS.md` before changing start timing.
- **Source pins.** `DictationSessionController.swift` is one of the most-pinned files; run `python3 scripts/dev/check-source-pins.py --changed-only` before editing.
