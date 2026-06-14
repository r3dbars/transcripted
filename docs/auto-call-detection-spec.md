# Spec: ad-hoc call detection via mic activity

- **Status:** Phase 1 complete + live-verified on branch `feat/auto-call-detection` (Phase 2 deferred). See "Phase 1 — results" below.
- **Created:** 2026-06-13
- **Product decisions (2026-06-14):** auto-detection ships **default ON** behind a Settings
  toggle; trigger scope is **browsers + known conferencing apps only** (unknown mic users map
  to no provider → no prompt). Phase 2 UDP hardening intentionally deferred.
- **Area:** `Sources/Meeting/` (app-side meeting detection)
- **Primary files:** `Sources/Meeting/MeetingPromptDetector.swift`, `Sources/Meeting/MeetingPromptHeuristics.swift`, `Sources/TranscriptedApp.swift`
- **Related:** existing calendar/runtime meeting prompts; `docs/ui-settings-menubar-spec.md`

## Summary

Prompt the user to start recording when a call *starts* — including a spontaneous
Google Meet with no calendar invite — by adding one app-agnostic runtime signal
(microphone activity, attributed to a process) into the existing
`MeetingPromptDetector`. This matches what Notion and Plaud do. The prompt UI,
the detector, and its backoff/snooze machinery already exist; this is mostly a
new signal feeding an existing pipe.

## Problem / current state

`MeetingPromptDetector` already treats Google Meet as a first-class provider
(`MeetingPromptProvider.googleMeet` in `MeetingPromptHeuristics.swift`). It
surfaces prompts from two channels:

1. **Calendar** — `MeetingPromptCalendarReader` reads EventKit, finds events
   whose URL/location/notes contain a recognized meeting link
   (`meet.google.com`, `zoom.us`, …), and prompts around the start time.
2. **Runtime app** — polls `NSWorkspace.runningApplications` + `frontmostApplication`
   and matches `MeetingPromptProvider.activeBundleIdentifiers`.

**The gap:** Google Meet runs in a browser, so its `activeBundleIdentifiers` is
empty (`[]`) and `supportsRuntimeOnlyPrompt` is `false`. The only browser signal
today is coarse — `activeRuntimeReason()` returns "meeting tab is active" purely
because *some* browser is frontmost, and only as an augmentation to an existing
calendar match. Net result: **a spontaneous Meet call with no calendar event is
invisible.** That is exactly the case Notion/Plaud cover and we don't.

## Prior art — how Notion and Plaud do it

Both are Electron apps in `/Applications`. Inspecting their bundles (native
`.node` addons + entitlements; reproduction commands in the appendix) shows
neither special-cases Google Meet — they detect *the act of being in any live
call*, generically, then attribute it. Two layers:

**Layer 1 — mic activity via CoreAudio (both apps).** Both attach a CoreAudio
property listener to the input device.
- Notion's `mac_utils.node`: `AudioObjectAddPropertyListenerBlock`,
  `Failed to get default input device ID from AudioObjectGetPropertyData`,
  `Removing AudioObjectRemovePropertyListenerBlock for micDeviceID`, plus
  `runningApplications` for attribution and ScreenCaptureKit for system audio.
- Plaud's `audio_monitor_mac.node` (the `[MicMonitor]`) goes further: it spins
  up its own `AudioDeviceCreateIOProcID` tap and does voice-activity detection
  (`Voice recovered on`, `Weak voice on ALL devices for 10s`), with
  device-change/fallback handling.

**Layer 2 — "is this really a call?" via per-process UDP inspection (Plaud).**
Plaud's monitor links libproc (`proc_listpids`, `proc_listchildpids`,
`proc_pidpath`, `proc_name`, `proc_pidfdinfo`, `proc_pidinfo`) and inspects each
candidate process's open **UDP sockets**, applying port heuristics
(`udpSockets`, `rejLowPort`, `sampleLowPort`, `udpPassed`) to spot WebRTC media
traffic. Per-browser logic:
- Chrome → renderer WebRTC PeerConnection (`ignored (Chromium without WebRTC PeerConnections)`, `WebRTC has active PeerConnection`)
- Firefox → its `plugin-container` child (`Firefox verified via plugin-container UDP`)
- Safari → the sibling `com.apple.WebKit.Networking` XPC process (`WebKit verified via sibling WebKit.Networking UDP`)

This is how Plaud tells "Chrome is open" from "Chrome is in a Meet/Zoom-web call"
— without ever reading a tab URL.

**Note:** both apps carry the `com.apple.security.automation.apple-events`
entitlement, but there is no `osascript`/`tell application` in the detection
path. The earlier hypothesis that they read the browser's active-tab URL via
AppleScript was wrong — they use the network-socket approach, which is more
robust and needs no per-browser Automation prompt.

## Design decision: use the modern Core Audio process-object API

Plaud uses libproc socket-sniffing because it supports macOS 11. **Transcripted
targets macOS 26+**, so it can use the **Core Audio process-object API**
(introduced macOS 14.2) instead:

- `kAudioHardwarePropertyProcessObjectList` → every process Core Audio knows about
- per process: `kAudioProcessPropertyIsRunningInput` (using the mic right now?),
  `kAudioProcessPropertyPID`, `kAudioProcessPropertyBundleID`

This yields the mic-active signal **and** attribution (which bundle ID is in the
call) in a single read — no audio tapping, no continuous orange-mic indicator,
and self-exclusion is just "drop our own bundle ID." It makes Plaud's UDP-socket
layer optional rather than required, because a browser process holding the mic
input is already a strong call signal (browsers rarely hold the mic otherwise).

## Architecture

```
MicActivityMonitor (new)          MeetingPromptDetector (extend)          existing, unchanged
┌──────────────────────┐         ┌──────────────────────────┐           ┌──────────────────────┐
│ CA process-object     │ bundle  │ micInputCandidates()      │ Candidate │ overlayController     │
│ listener → set of     │ IDs in  │  → map bundleID→provider  │──────────▶│ .presentDetected      │
│ bundleIDs using mic   │────────▶│  → gate on own-capture    │           │  MeetingPrompt()      │
│ (minus our own)       │  use    │  → score, into evaluate() │           │ (already built)       │
└──────────────────────┘         └──────────────────────────┘           └──────────────────────┘
```

Data flow: monitor emits the set of non-self bundle IDs currently using the mic
→ `detector.updateMicInputUsers(_:)` stores it and re-runs `evaluate()` →
`evaluate()` adds mic-input candidates alongside calendar/runtime candidates →
highest-scored candidate goes to the existing `onPromptRequest` →
`meetingOverlayController.presentDetectedMeetingPrompt(candidate)`.

## Phase 0 — spike (de-risk first, ~half day)

**The one real risk:** confirm that reading `kAudioHardwarePropertyProcessObjectList`
+ `kAudioProcessPropertyIsRunningInput` + `kAudioProcessPropertyBundleID` works
**without** the `NSAudioCaptureUsageDescription` TCC permission (it shouldn't —
we read metadata, not audio). Build a throwaway binary that prints mic-active
bundle IDs while a Meet call runs.

- **No permission needed** → proceed with the clean design below.
- **Permission needed** → fall back to `kAudioDevicePropertyDeviceIsRunningSomewhere`
  (coarse boolean, definitely permission-free) for the *trigger*, and attribute
  via `NSWorkspace` running/frontmost apps (less precise). The rest of the design
  is unchanged; only `MicActivityMonitor`'s internals differ.

### Phase 0 — results (2026-06-14)

Throwaway spike: `scripts/dev/mic-activity-spike.swift` (run with `swift
scripts/dev/mic-activity-spike.swift [--watch] [--dump]`). Ran on macOS 26.5.1.

- **No permission needed — confirmed.** Reading `kAudioHardwarePropertyProcessObjectList`
  (39 process objects) plus per-process `kAudioProcessPropertyIsRunningInput`,
  `kAudioProcessPropertyPID`, and `kAudioProcessPropertyBundleID` all returned
  `noErr` with **no TCC prompt** and no `NSAudioCaptureUsageDescription`. We read
  metadata, not audio. → proceed with the clean process-object design.
- **Attribution works.** 36/39 process objects resolved a bundle ID (the 3 without
  are system/anonymous audio objects, e.g. the default device aggregate).
- **KEY FINDING — browser audio lives in helper/service processes, so the bundle→provider
  map must match the browser *family by prefix*, not exact bundle IDs:**
  - Chrome appears as `com.google.Chrome` **and** `com.google.Chrome.helper`.
    **Confirmed against a live Google Meet call:** the only process holding the mic
    input was `com.google.Chrome.helper` (the Audio Service utility process), *not*
    the main `com.google.Chrome`. Exact-bundle-ID matching would have missed the
    call entirely — prefix/family matching is required, not a nicety.
  - Safari/WebKit audio runs in `com.apple.WebKit.GPU` (sibling service), which is
    **not** prefixed by `com.apple.Safari`. WebKit services share the
    `com.apple.WebKit` prefix and also cover any WKWebView-based app in a web call.
  - So browser detection recognizes: `com.google.Chrome*`, `com.google.Chrome.canary*`,
    `com.microsoft.edgemac*`, `com.brave.Browser*`, `company.thebrowser.Browser*`,
    `org.mozilla.firefox*`, `com.apple.Safari`, and `com.apple.WebKit*`.
- **Self-exclusion:** our bundle ID is `com.justinbetker.draft` (legacy Draft id);
  exclude it by prefix so any future helper process is dropped too.
- Aside: `ai.plaud.desktop.plaud` + `.helper` show up in the process list — Plaud
  registers its own audio objects, matching the prior-art findings.

## Phase 1 — MicActivityMonitor + wiring

### New file `Sources/Meeting/MicActivityMonitor.swift`
- Registers `AudioObjectAddPropertyListenerBlock` for
  `kAudioHardwarePropertyProcessObjectList` on a dedicated utility queue.
  **CoreAudio threading rule (see root `CLAUDE.md`):** do no heavy work, locks,
  or allocations in the callback beyond collecting; hop to `@MainActor` to emit.
- On change: enumerate process objects, keep those with
  `kAudioProcessPropertyIsRunningInput == true`, read `kAudioProcessPropertyBundleID`,
  drop our own bundle ID, emit `Set<String>`.
- Debounce ~1–2s so a blip doesn't fire. Emit an explicit "inactive" edge when
  the set empties so transient pending prompt state can reset without wiping a
  user's explicit dismiss/snooze backoff.
- Keep it thin: all *decision* logic (bundle→provider, candidate construction,
  self-exclusion) lives in pure functions for testability — the CoreAudio
  listener itself is not unit-testable.

### Extend `Sources/Meeting/MeetingPromptDetector.swift`
- Store `micActiveBundleIDs: Set<String>`; add `updateMicInputUsers(_:)` setter
  that re-runs `evaluate()`.
- Add `micInputCandidates(now:)` to the candidates array in `evaluate()`
  (currently builds calendar + `runtimeReminderCandidates`).
- Map bundle ID → provider: native apps reuse `activeBundleIdentifiers`
  (`us.zoom.xos`→zoom, `com.microsoft.teams2`→teams, …); **any browser bundle ID
  using the mic → treat as a live browser call** (Meet/Zoom-web/Teams-web). This
  browser branch is what closes the Google Meet gap and makes the current
  `supportsRuntimeOnlyPrompt = false` for `googleMeet` moot.
- **Reuse the `.runtimeApp` source** (do not add a new `MeetingPromptSource`
  case) so the existing snooze/dismiss/backoff in `MeetingPromptHeuristics` keeps
  working untouched. Candidate id `mic:<provider>`, score **5** (above the
  frontmost-browser score of 4 — mic-in-use is a stronger signal than "a browser
  is frontmost").

### Self-exclusion in `Sources/TranscriptedApp.swift`
- Add `var isOwnCaptureActive: (() -> Bool)?` to the detector; wire it beside the
  existing `onPromptRequest` block to return
  `meetingSession.isRecording == true || <dictation active>`.
  `MeetingSessionController.isRecording` already exists (`@Published private(set) var isRecording`).
  Dictation-active reads from `STTRouter` / `ContextCaptureEngine`.
- Gate the whole mic-candidate path on `!isOwnCaptureActive()` so we never prompt
  while *we* hold the mic (belt-and-suspenders with the own-bundle-ID filter).
- Construct the monitor in app setup, point it at `detector.updateMicInputUsers`,
  `start()` it beside `detector.start()`, `stop()` it beside `detector.stop()`.

### Current wiring anchors (as of 2026-06-13, branch `fix/home-row-actions`; verify line numbers before editing)
- `Sources/TranscriptedApp.swift:82` — `lazy var meetingPromptDetector = MeetingPromptDetector()`
- `Sources/TranscriptedApp.swift:168` — `onPromptRequest = { … }`
- `Sources/TranscriptedApp.swift:171` — `meetingOverlayController.presentDetectedMeetingPrompt(candidate)`
- `Sources/TranscriptedApp.swift:180` / `:261` — `start()` / `stop()`
- `Sources/Meeting/MeetingPromptDetector.swift:189` — `evaluate()`; `:199-211` — candidates array; `:278` — `runtimeReminderCandidates`
- `Sources/Meeting/MeetingPromptHeuristics.swift:3` — `MeetingPromptProvider`; `:19` — `activeBundleIdentifiers`; `:38` — `supportsRuntimeOnlyPrompt`; `:181` — `runtimePresentation`
- `Sources/Meeting/MeetingSessionController.swift:150` — `isRecording`

## Phase 1 — results (2026-06-14)

Implemented on branch `feat/auto-call-detection` as five atomic commits (Phase 0
spike, then provider mapping → monitor → detector wiring → app/Settings wiring).

What shipped, and where it diverged from the original sketch:
- **`MicActivityMonitor`** (`Sources/Meeting/MicActivityMonitor.swift`) emits the set
  of non-self mic-holding bundle IDs. It uses a device "is-running-somewhere" edge
  listener **plus a slower 15s backstop scan**, not a pure `kAudioHardwarePropertyProcessObjectList`
  listener — because the Phase 0 live test proved the process list does *not* change
  when a call starts (the browser helper already exists; only its `IsRunningInput`
  flips). All CoreAudio + state are confined to one serial queue; results hop to main.
- **Provider mapping** lives in `MeetingPromptHeuristics`/`MeetingPromptProvider` as pure,
  tested functions. Browser detection is **family-prefix** (`String.matchesBundleFamily`)
  so `com.google.Chrome.helper` and `com.apple.WebKit.GPU` attribute correctly. Native
  conferencing apps map to themselves; any browser maps to `.googleMeet`.
- **Detector**: `updateMicInputUsers(_:)` + `micInputCandidates(now:)` reuse the
  `.runtimeApp` source (snooze/dismiss/backoff untouched), score **5**, reason
  `.micInput` (new, for analytics), candidate id `mic:<provider>`. The inactive edge
  clears only transient pending state; explicit dismiss/snooze backoff survives
  mute/unmute and brief mic drops.
- **Self-exclusion**: detector `isOwnCaptureActive` (recording OR dictation) gates the
  whole mic path, plus the monitor drops our own bundle (`com.justinbetker.draft`) by prefix.
- **Settings**: "Auto-detect calls" on the General page, **default ON**.

Open questions resolved: (1) default **ON**; (2) scope = **browsers + known conferencing
apps** (unknown mic users → no prompt); (3) **yes**, a distinct `.micInput` reason for
analytics while still reusing `.runtimeApp` for backoff.

Verification (all green): `bash build.sh --no-open` incl. the GUI launch-smoke; full fast
suite (5292 tests, incl. new heuristics / monitor / detector / preference coverage);
`run-integration-smoke.sh`. The live CoreAudio attribution was confirmed against a real Meet
call via the Phase 0 spike (the mic was held by `com.google.Chrome.helper`).

(One detour worth recording: the launch-smoke first appeared to hang in `getxattr` during
`MeetingSessionController.init`. It was a first-launch macOS **file-access TCC prompt** —
the app blocks on `getxattr` until the dialog is answered, and the dialog was sitting
unclicked. Not endpoint-security, not a code issue; once allowed, the app launches in ~1s.)

**Live-verified (2026-06-14):** both attribution branches fire correctly during real calls —
a spontaneous Google Meet with no calendar invite → "Call detected in your browser"
(browser-family branch, the exact gap this spec targeted), and a native Zoom call → "Zoom
call detected" (native-app branch with provider-specific copy). (Self-exclusion — no prompt
while Transcripted itself records — is covered by unit tests.)

## Phase 2 — optional UDP hardening (only if needed)

If non-call browser mic use (voice search, a web recorder) causes false prompts
in practice, add Plaud's per-process UDP-socket check via libproc
(`proc_pidfdinfo`) as a confirmation gate for browser candidates. Skip until
real-world false positives justify it — browsers rarely hold the mic outside
calls, so Phase 1 alone is likely enough.

## False positives & backoff (mostly free)

- Our own capture / dictation → self-exclusion (own-bundle filter + `isOwnCaptureActive`).
- QuickTime, Voice Memos, Photo Booth → map to no provider → no prompt.
- Repeated nagging → existing `snooze` / `dismiss` / `remindSoon` +
  `runtimeSuppressedUntil` already handle it. The inactive edge clears only
  transient pending state, so a later call can re-prompt if the first prompt was
  merely shown, but an explicit user dismissal stays quiet through mute/unmute.

## Settings / privacy

- Add a preference (likely `Sources/Support`) + a Settings toggle, e.g.
  "Auto-detect calls", surfaced near the existing meeting-prompt settings.
- **Default on or off is an open question** (below). Passive "watch which apps
  use the mic" is privacy-adjacent even though everything stays on-device.
- Observability: anything logged stays local; if we log a detected provider via
  `EventReporter`, log the provider only — never titles, never raw device names
  (per the observability rules in root `CLAUDE.md`).

## Files touched

- **New:** `Sources/Meeting/MicActivityMonitor.swift`
- **Edit:** `Sources/Meeting/MeetingPromptDetector.swift` (new candidate source + setter),
  `Sources/Meeting/MeetingPromptHeuristics.swift` (bundle→provider for browsers,
  mic presentation/score), `Sources/TranscriptedApp.swift` (construct/wire/start/stop
  + self-capture closure)
- **Maybe:** a `Sources/Support` preference + a Settings toggle
- **Tests:** extend `Tests/MeetingPromptHeuristicsTests.swift`; register any new
  root test file in `Tests/FastTests.manifest`

## Testing & verification

Per root `CLAUDE.md` (touching `Sources/Meeting/**`):

```bash
bash build-deps.sh --force && bash build.sh --no-open && bash run-tests.sh && bash run-integration-smoke.sh
```

Keep CoreAudio in the thin monitor; put bundle→provider mapping, scoring, and
self-exclusion in pure functions so they are covered by fast tests. The CoreAudio
listener itself is not unit-testable — verify it live with a real Meet call (and
confirm no prompt fires while Transcripted itself is recording).

## Open questions

1. **Default on or off** for auto-detection? (Notion/Plaud default on. Lean: on,
   with a clear Settings toggle — product call.)
2. **Trigger scope:** prompt only for browsers + known conferencing apps (safe,
   what's specced), or on *any* non-self mic use (more aggressive, more false
   positives)?
3. Do we want a distinct `MeetingPromptReason` for the mic-input signal for
   analytics, even while reusing the `.runtimeApp` source?

## Appendix — reproducing the prior-art findings

```bash
# Entitlements (both declare apple-events + audio-input; Notion also camera/bluetooth)
codesign -d --entitlements :- /Applications/Plaud.app 2>/dev/null | plutil -p -

# Native addons
ls -lhS /Applications/Plaud.app/Contents/Resources/*.node
#   audio_monitor_mac.node  (MicMonitor)   recorder_mac.node
otool -L /Applications/Plaud.app/Contents/Resources/audio_monitor_mac.node   # CoreAudio + AudioToolbox

# CoreAudio + libproc symbols / diagnostic strings
nm -u /Applications/Plaud.app/Contents/Resources/audio_monitor_mac.node | grep -iE 'proc_|pidinfo'
strings -n 5 /Applications/Plaud.app/Contents/Resources/audio_monitor_mac.node | grep -iE 'MicMonitor|WebRTC|UDP|PeerConnection'

# Notion's native helper
otool -L "/Applications/Notion.app/Contents/Resources/app.asar.unpacked/node_modules/@notionhq/desktop-native/build/Release/mac_utils.node"
strings -n 6 "/Applications/Notion.app/Contents/Resources/app.asar.unpacked/node_modules/@notionhq/desktop-native/build/Release/mac_utils.node" | grep -iE 'AudioObject|runningApplications|ScreenCapture'

# Neither hardcodes a meeting host (detection is host-agnostic): both return 0
strings -n 5 /Applications/Notion.app/Contents/Resources/app.asar | grep -icE 'meet\.google\.com|zoom\.us'
```
