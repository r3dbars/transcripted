# Spec: ad-hoc call detection via mic activity

- **Status:** Phase 1 complete + live-verified (Phase 2 UDP hardening deferred). Phase 3 (aggressiveness + camera-on detection, 2026-06-20) shipped. Phase 4 (audio-output signal + unattended-prompt re-offer, 2026-07-02) is the latest layer; see "Phase 4" at the end.
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
  the set empties, but keep detector cooldowns intact so mute/unmute cannot
  re-prompt early.
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
  listener **plus a slow 60s backstop scan**, not a pure `kAudioHardwarePropertyProcessObjectList`
  listener — because the Phase 0 live test proved the process list does *not* change
  when a call starts (the browser helper already exists; only its `IsRunningInput`
  flips). All CoreAudio + state are confined to one serial queue; results hop to main.
- **Provider mapping** lives in `MeetingPromptHeuristics`/`MeetingPromptProvider` as pure,
  tested functions. Browser detection is **family-prefix** (`String.matchesBundleFamily`)
  so `com.google.Chrome.helper` and `com.apple.WebKit.GPU` attribute correctly. Native
  conferencing apps map to themselves; any browser maps to `.googleMeet`.
- **Detector**: `updateMicInputUsers(_:)` + `micInputCandidates(now:)` reuse the
  `.runtimeApp` source (snooze/dismiss/backoff untouched), score **5**, reason
  `.micInput` (new, for analytics), candidate id `mic:<provider>`. Calendar
  candidates for the same native provider win over mic candidates so scheduled
  native-app calls keep their title/context. Generic browser mic calls stay
  neutral because they may be Meet, Zoom-web, or Teams-web. Inactive edges keep
  pending/dismiss/snooze cooldowns intact so mute/unmute and brief mic drops stay
  quiet.
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
  `runtimeSuppressedUntil` already handle it. The inactive edge does not clear
  prompt cooldowns, so mute/unmute cannot bypass either the short pending
  cooldown or an explicit user dismissal.

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

## Phase 3 — "spontaneous calls feel invisible" diagnosis + aggressiveness + camera (2026-06-20)

Justin's lived experience: spontaneous browser calls (a Meet in a tab) rarely
surface a prompt, even though Phase 1 was live-verified. A deep trace settled the
question with evidence.

### Diagnosis (what was actually wrong)

The wiring and the detector policy are **correct and tested** — ruled out, with
evidence: the monitor is constructed and `start()`ed (default ON) with `onChange`
assigned before `start()` (`TranscriptedApp.swift`); the browser provider is
eligible (`micInputCandidates` does **not** gate on `supportsRuntimeOnlyPrompt`,
and `com.google.Chrome.helper` → `.googleMeet`); own-capture / enabled gates are
false when idle. The path was live-verified firing on 2026-06-14.

The real culprits, ranked:

1. **Untested CoreAudio delivery layer (primary).** The only low-latency trigger
   was a single `kAudioDevicePropertyDeviceIsRunningSomewhere` listener on the
   **default input device**. That edge fires only on a 0→1 transition of the
   device's *aggregate* running state, so a call that starts while the device is
   already running (another app held the mic, our own warmup touched it) or on a
   **non-default** device never trips it — and detection collapses onto the **60s
   backstop poll**, which a short spontaneous call slips through entirely. Nothing
   in CI exercised `start()→edge→emit`, so this stayed invisible to the gate.
2. **Discoverability (secondary).** Onboarding's calendar stage framed detection
   as calendar-only ("Want meeting reminders?", "look at your calendar"); nothing
   told users spontaneous browser calls are auto-detected. The only place that
   said so was a default-on Settings toggle users never visit. A real-but-
   occasionally-late prompt that users don't expect reads as "the feature doesn't
   exist."
3. **No "is this really a call?" confirmation.** Phase 2 (UDP hardening) was
   deferred, so the path had no min-duration gate and had to stay conservative to
   avoid false prompts on brief browser mic use.

### What changed (more aggressive, without prompting on every blip)

- **Backstop poll 60s → ~5s** (`MicActivityMonitor.pollInterval`). The poll reads
  process objects directly (device-agnostic), so it catches the already-running /
  non-default-device cases the edge misses, within seconds instead of a minute.
  The reads are cheap, so this is the high-value, low-risk reliability fix.
- **Sustain gate** (`SustainedActivityConfirmer`, shared with the camera monitor):
  a bundle must hold the mic continuously for `sustainInterval` (~3s) before it is
  emitted, with a scheduled re-scan at the confirmation deadline so a genuine call
  still surfaces within a couple of seconds. This filters momentary mic access
  (voice search, permission probes) — the lightweight on-device alternative to the
  deferred UDP layer — and is what lets us poll aggressively safely.
- **Discoverability:** onboarding's calendar stage now adds one additive line that
  spontaneous calls are detected automatically (kept minimal to avoid colliding
  with the in-flight calendar pre-arm work, which is doc-only today); the Settings
  "Auto-detect calls" info copy now mentions the camera signal too.

### Camera-on detection (net-new complementary signal)

**API (researched, not guessed):** CoreMediaIO exposes **no** public per-process
camera API (no CMIO analog of `kAudioHardwarePropertyProcessObjectList`). The one
public, on-device, metadata-only, **TCC-free** signal is
`kCMIODevicePropertyDeviceIsRunningSomewhere` ('gone') per CMIO device — the exact
camera analog of the mic device boolean. Reading `kCMIOHardwarePropertyDevices` +
that boolean enumerates and watches cameras **without opening a stream**, so it
needs **no camera permission and no `NSCameraUsageDescription` /
`com.apple.security.device.camera` entitlement** (same metadata-only shape used
by tools like OverSight/Guard, which detect camera-on this way and read no
frames). **Needs-extra-permission: NO.**

`CameraActivityMonitor` mirrors `MicActivityMonitor` (one serial CMIO queue,
debounce, ~5s poll, sustain) and emits a single boolean. Because the boolean has
no attribution, the detector attributes it via
`MeetingPromptProvider.cameraCallProvider(forFrontmostBundleID:)` — a frontmost
browser → `.googleMeet`, a frontmost native conferencing app → that provider,
anything else (Photo Booth, QuickTime) → no prompt. That frontmost-call-app
requirement *is* the non-call sanity check. The camera-only case (camera on, mic
muted — a camera-first Meet join) uses the `.cameraInput` reason.

**De-dupe:** mic and camera signals merge in `callSignals` keyed by provider and
produce candidate id `mic:<provider>`, so a normal video call (mic **and** camera)
raises exactly one prompt, with the mic signal winning the reason. The camera path
reuses the `.runtimeApp` source and is gated by the same `isOwnCaptureActive` /
`AutoCallDetectionPreferences` gates as the mic path.

**Coverage:** `SustainedActivityConfirmerTests`, `CameraActivityMonitorTests`, and
new `MeetingPromptHeuristicsTests` / `SyntheticMeetingPromptTests` /
`MeetingPromptDetectorTests` cases (camera attribution, Photo-Booth quiet,
mic+camera one-prompt de-dupe, own-capture/disabled gates). Current branch
verification should follow `.agents/test-matrix.yml`.

## Phase 4 — listen-only calls + unattended-prompt re-offer (2026-07-02)

Two remaining leaks in "the system thinks you're in a meeting → the user taps
record", found by auditing the prompt pipeline end to end:

### Leak 1 — the listen-only / hard-muted call is invisible

Every ad-hoc sensor so far requires *this Mac* to be sending something: the mic
signal needs a process holding the input, the camera signal needs a camera on.
A call you join muted with the camera off — a webinar, a big all-hands, a call
where you mostly listen — produces neither, and without a calendar invite it
never prompts.

**The signal:** the same Core Audio process objects also expose
`kAudioProcessPropertyIsRunningOutput`. A native conferencing app playing
sustained audio output means remote people are talking — a live call — with real
per-process attribution and the same metadata-only, TCC-free posture as the mic
read (no audio is tapped).

**Scope (deliberately narrow):** native conferencing families only
(`MeetingPromptProvider.audioOutputProvider`): Zoom, Teams, Webex, FaceTime.
Browsers are excluded — browser output is dominated by YouTube/music — so the
spontaneous-browser-call gap stays covered by the mic/camera signals only. The
filter runs inside `MicActivityMonitor.callOutputBundleIDs` *before* the sustain
confirmer, so media apps never even churn the monitor's state.

**Sustain:** output uses a longer sustain than the mic (`outputSustainInterval`,
10s vs 3s) because conferencing apps also play short notification sounds
(message dings, join/leave chimes) that must not prompt.

**Tiering in `callSignals` (both implementations, kept in lockstep):** mic
providers win outright; else native-output providers (`.audioOutput` reason);
else the camera. Output outranks the camera because it carries process
attribution while the camera boolean only has the frontmost-app guess. Same
`mic:<provider>` candidate id, so all three sensors on one call de-dupe to a
single prompt and existing snooze/dismiss/backoff applies unchanged.

### Leak 2 — an ignored prompt was treated as an explicit "no"

The detected-meeting prompt shows a 30s countdown
(`MeetingOverlayTokens.defaultDetectedMeetingPromptTimeoutSeconds`). Before this
phase, countdown expiry took the *same* path as clicking × —
`detector.dismiss(candidate:)` — which suppresses the provider for up to 30
minutes (Teams: 2h). A user heads-down in the call, on another Space, or away
from the screen for the first minute lost the entire meeting to one missed
30-second pill.

**The fix:** expiry is now its own path. `MeetingOverlayController.onPromptExpired`
→ `MeetingPromptDetector.expire(candidate:)` schedules a short *candidate-level*
re-offer (`promptExpiryReofferInterval`, 3 min) with **no provider-wide
suppression**, so the same call re-prompts while its evidence persists.
Consecutive unattended expiries are capped (`maxPromptExpiryReoffers` = 2, streak
forgotten after `promptExpiryStreakResetInterval`); past the cap the candidate
falls back to the normal `dismiss` backoff so an ignored call eventually goes
quiet. Net: up to 3 offers per call (~t+0, ~t+3.5min, ~t+7min), then silence.
Explicit × dismissals and remind-soon behave exactly as before.

**Analytics:** no new event names. Expiry reuses `meeting_prompt_dismissed` with
`backoff_kind`/`cooldown_reason` = `expired_reoffer` and `workflow_abandoned`
`reason_kind` = `expired`, so dashboards can now separate "user said no" from
"user never saw it" — the number that tells us whether the prompt surface itself
needs to be louder.

**Coverage:** new `MicActivityMonitorTests` (output attribution + self-exclusion),
`MeetingPromptHeuristicsTests` (output provider mapping, expiry policy),
`SyntheticMeetingPromptTests` (output prompts, mic-wins de-dupe, tier order,
media-app quiet, gates), and `MeetingPromptDetectorTests` (listen-only prompt,
one-prompt de-dupe, expire re-offer + cap + cooldown shape).

### Phase 4 follow-on — always running, longer live prompts, missed-call awareness

Three more layers on the same funnel, in trust order:

1. **Launch-at-login defaults on (one-time, post-onboarding).** The whole
   detection stack is dead while the app is closed — the worst-case failure is
   "the human never launched the app." `LaunchAtLoginController
   .applyDefaultEnableIfNeeded` registers the login item once per install, only
   after onboarding completes (so the macOS "added to Login Items" notice has
   context), never over an explicit Settings choice, and never re-applied after
   the user removes the item in System Settings (the applied-marker in
   `LaunchAtLoginPreferences` guarantees at-most-once).
2. **Live-call prompts last 60s instead of 30s**
   (`MeetingPromptHeuristics.promptTimeoutSeconds`). An ad-hoc call prompt's
   moment doesn't age out the way a calendar reminder does — the call is
   happening *now* — so it waits longer before the expiry/re-offer machinery
   takes over. Combined with Phase 4's re-offers, an unrecorded 10-minute call
   now sees up to 3 minutes of cumulative prompt time instead of 30 seconds.
3. **Missed-call nudge (awareness loop).** When a detected call session ends
   unrecorded (`MeetingPromptDetector` folds the ad-hoc signals into a session
   across evaluate() passes), a one-line overlay nudge says what was missed —
   "That Zoom call wasn't recorded · About 42 minutes" — with Got It / Don't
   show again. `MissedCallNudgePolicy` keeps it rare: ≥10-minute calls only,
   never after an explicit prompt dismissal, never when a recording overlapped,
   4-hour cooldown. Preference-gated (`MissedCallNudgePreferences`, default on,
   Settings toggle). The nudge cannot recover the meeting; its job is to make
   the invisible miss visible, which is what converts "the feature doesn't
   exist" into "I should tap Record next time." Analytics:
   `meeting_missed_call_nudge` with `action` / `duration_bucket` / `provider`.

**Deliberately not built: default auto-record.** A visible countdown that
auto-starts recording (Notion-style) remains the documented *opt-in* design in
`docs/MEETING_CAPTURE_PROMPTING.md` — short countdown (~8s, with the prompt
already visible ~60s), never silent at t=0, default OFF. The gentle default
keeps the product invariant "no file is ever written without a human signal,"
which is the line that keeps false positives from ever becoming privacy
incidents. Revisit once `meeting_prompt_dismissed` telemetry separates
`expired_reoffer` (never saw it) from explicit dismissals (said no): if misses
dominate, the aggressive tier earns its switch.
