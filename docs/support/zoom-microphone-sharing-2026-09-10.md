# Zoom microphone sharing repair

## Report and cause boundary

The September 8 support report describes Zoom losing outgoing microphone audio
while Transcripted runs/captures, then recovering when Transcripted stops.
The supplied diagnostics show built-in input with `voice_processing=true`.

Source review found no explicit CoreAudio hog/exclusive-mode request. The
relevant contention path is opt-in Apple voice processing (VPIO), enabled for
meetings and dictation by the saved processing preference or meeting boost.
[Apple describes this as coupled input/output voice processing](https://developer.apple.com/videos/play/wwdc2019/510/),
not just gain on a copied microphone buffer. Minimum playback ducking does not
guarantee that another app's microphone stream stays healthy.

Dictation also left VPIO configured on its stopped, retained engine until the
next input-readiness snapshot. A fresh idle launch does not start capture.
The opt-in persistent Bluetooth input controller already defers global route
writes while external input activity is active or unknown. This repair does
not change that controller or microphone selection.

These are source findings and a targeted contention fix, not a reproduced
CoreAudio root cause on the reporter's Mac. Earlier
[PR #1725](https://github.com/r3dbars/transcripted/pull/1725) adds diagnostic
scope only. [#1537](https://github.com/r3dbars/transcripted/pull/1537) and
[#1565](https://github.com/r3dbars/transcripted/pull/1565) addressed Bluetooth
isolation/recovery; [#1726](https://github.com/r3dbars/transcripted/pull/1726)
preserved that default while adding explicit selected-input support.

## Change

- Observe Zoom desktop app presence without opening a microphone. Check both
  an already-running Zoom and a later launch; do not depend on call detection
  being enabled or the affected mic reporting healthy activity.
- Suppress VPIO while Zoom is open. Meetings retain software autogain on the
  copied mic stream, raw/off stays raw, and dictation retains its existing
  transcription/signal recovery. The stored processing preference is unchanged.
- If Zoom opens during VPIO capture, use the existing microphone recovery path.
  Meetings retain the pinned input, system stream, and mic segments. Sharing
  stays latched for that meeting; quitting Zoom does not cause another restart.
  Starting/recovering captures recheck the guard. Stop generations reject stale
  restarts, and meeting reconciliation admits only one worker at a time.
- Do not offer or apply a VPIO boost while the meeting's sharing guard is active.
- Disarm stopped dictation processing without lazily opening an unused input
  node. If native disarm fails, finish stop bookkeeping before dropping the
  owned graph; shared startup cannot continue with VPIO still enabled. Use a
  fresh graph for Zoom-triggered dictation recovery. Release the meeting engine
  after stop, including failed VPIO disarm.

App presence deliberately covers Zoom's automatic/preferred microphone before
a call begins. The guard targets Zoom desktop (`us.zoom.xos`); browser calls
retain the existing optional Apple processing path. The fallback does not
reproduce Apple's echo cancellation/noise suppression. Saved mic quality and
remote audio therefore both need the checks below.

## Verification with Zoom and Transcripted open

Use a willing receiving participant on another device, wearing headphones.
Use ordinary test speech; no private meeting content is needed. Record macOS,
Zoom and Transcripted build versions and the selected input/output devices.

1. With Transcripted quit, select Zoom's automatic/preferred microphone and
   the Mac's built-in input. Establish that Zoom's meter moves **and the remote
   participant hears intelligible speech**. If this baseline fails, fix it
   before attributing any change to Transcripted.
2. In Transcripted, select Apple voice processing to exercise the previous
   failure path. Keep Zoom open. Launch Transcripted and leave it idle, then
   record a meeting while both people speak. Zoom must keep transmitting;
   Transcripted must retain audible local and remote tracks.
3. Stop the meeting without quitting Transcripted. Repeat a short dictation,
   stop it, then cancel another dictation. Confirm remote speech at each step
   and while Transcripted returns to idle. Repeat with the Whisper model if
   installed; it shares the same microphone capture engine.
4. Reverse startup order: quit Zoom, start a Transcripted meeting with Apple
   processing, then open/join Zoom. Expect one mic recovery gap; confirm Zoom
   hears speech, system audio continues, and the saved local track resumes.
   Repeat by opening Zoom during dictation and during capture startup. Stop
   while recovery is occurring: capture must not restart afterward.
5. Keep a meeting running while quitting/reopening Zoom. VPIO must stay off
   for that meeting. Repeat a route change and borrowed-mic dictation during
   the meeting. No global input/output setting should change because of this
   protection. A stale Boost Mic prompt must not enable VPIO or restart capture.
6. Repeat software autogain and raw/off. Inspect retained microphone audio for
   missing/quiet speech, clipping, noise and remote-speaker bleed. Compare a
   spoken phrase before and after the transition; check the saved transcript.
7. With Zoom closed, confirm Apple processing still works on the next capture.
   Recheck the existing Bluetooth isolation and selected-mic opt-in separately.

For protected meeting capture, diagnostics should show `voice_processing=false`
even when the requested preference is Apple processing. Diagnostics describe
Transcripted's own stream. They do not replace the receiver-side check.

## Review workflow and automated scope

Independent Codex audits covered meeting and idle/dictation ownership. A
separate Codex reviewer checks the complete diff against `origin/main` and
adversarially checks start/stop/recovery and boost races. The primary Codex
agent owns final review. Maestro Claude/local/Windows lanes were unavailable
because the configured `maestro-delegate` executable was absent.

Regression coverage exercises Zoom startup/launch/termination notifications,
unchanged preferences, Core VPIO suppression and software gain/raw behavior,
boost eligibility/stale actions, and dictation source ownership contracts.
Source contracts do not execute native audio. The PR records the actual build,
fast-test, Core, integration and full QA results. Live Zoom receiver-side and
saved-audio quality checks remain a separate manual gate. No release is made.
