# Issue #500 — "Mic audio recording is a lot quieter": state of play and fix plan

Date: 2026-06-11. Deep-dive against main after the #825 work.

> **Status:** P1–P4 shipped via PR #1075 (merged 2026-06-11):
> `QuietMicAttenuationDetector`, the in-meeting "Boost Mic" consent prompt with
> mid-recording VPIO switch, post-meeting `audio_health` surfacing, and the
> Settings copy rewrite. Still open: the manual hardware QA in section 5 (run it
> before the release that ships this) and the P5 dashboard check.

## 1. What's already landed (and works)

The issue has two distinct sub-mechanisms, now classified per-recording by
`MeetingCaptureVolumeDiagnostics.attenuationKind` (MeetingCaptureSupport.swift:208-230):

- **`scalar_drop`** — a meeting app drove the input device's volume scalar down.
  Linear, fully recoverable by gain. Handled: `RealtimeAGC` (default path, max
  25x, real-time safe in the tap callback) + `AudioSignalRecovery.normalizeForSpeech`
  in the pipeline before STT and diarization (TranscriptionPipeline.swift:447,918).
- **`voice_processed`** — a foreign app (Safari/Firefox WebRTC, native WhatsApp,
  Zoom) holds the shared input in macOS voice/communication mode. The copy other
  clients get has AEC + noise gating baked in: **nonlinear, lossy, only partially
  recoverable by gain**. The code comment itself calls this "issue #500's
  still-open case."

The escape hatch exists: opt-in VPIO (`MicrophoneProcessingPreferences`,
default off) arms `setVoiceProcessingEnabled(true)` + `isVoiceProcessingAGCEnabled`
+ `duckingLevel: .min` (Audio.swift:709-750), giving Transcripted its own
properly-leveled mic copy.

**Default-on VPIO is ruled out by this repo's own history** (commit 1e635997):
v1.1.24 shipped it unconditionally, PR #535 added `.min` ducking, and it still
wasn't enough — Apple documents `.min` as the *lowest* level, not zero, so Zoom
playback audibly dimmed and it was reverted to opt-in. MacWhisper, Granola, and
SuperWhisper all avoid VPIO on record-only paths for the same reason.

## 2. The actual remaining gaps

1. **Detection is stop-time only.** `annotatedStopContext` classifies the
   recording at stop/cancel (MeetingSessionController.swift:612,867,1515) — it
   feeds Sentry, not the user. Someone whose 1h meeting is being gated finds
   out after the meeting, from a transcript missing their own speech.
2. **Live peaks can't drive detection.** `recordMicSignalPeaks` keeps a
   recording-lifetime max (Audio.swift:446-451) — one loud cough at minute 1
   masks two hours of attenuation.
3. **Nobody tells the user what happened or what to do.** The VPIO toggle
   exists in Settings, but the user has no way to connect "my transcript is
   missing me" to "enable that toggle."
4. **Unknown real-world split.** Sentry now receives `attenuation_kind` +
   `quiet_mic_unrecovered`; nobody has checked the distribution yet.

## 3. The fix: detection → guided, consent-based escalation

Keep software AGC the default for everyone. When the lossy case is detected,
tell the user and offer the VPIO escape hatch scoped to their decision.

### P1 — Live unrecovered-quiet detection (Core)
- Add a small rolling window (ring buffer, lock-guarded, allocation-free) of
  recent raw/processed mic peaks next to the existing lifetime-max in
  `recordMicSignalPeaks`.
- Detector runs on the existing 0.2s recording timer (NOT the tap callback):
  fires when, for a sustained window (~20-30s), windowed raw peak < 0.05,
  AGC `appliedGain` pinned at/near `maxGain`, and windowed processed peak <
  0.12 (the existing `usableMicProcessedPeakThreshold`). The thresholds reuse
  the stop-time classification so live and post-hoc agree.
- Emits a capture lifecycle cue (`onCaptureLifecycleCue`), e.g.
  `.micAttenuatedByForeignVoiceProcessing`. One-shot per recording.

### P2 — In-meeting prompt (app)
- Cue → menubar pill/banner: "Your mic is coming through very quiet — another
  app is using it in voice mode."
- Action button: **Boost mic for this meeting** → set the VPIO preference and
  trigger the existing device-recovery restart (`recoverFromDeviceChange`
  already re-arms VPIO and swaps out the AGC on restart —
  AudioDeviceRecovery.swift:144-155). The 1-2s restart gap is recorded as a
  segment gap; the #825 segment-merge + journal work makes this restart safe
  and crash-recoverable.
- Honest caveat in the prompt: "Audio from other apps may get slightly quieter
  while recording." Declining keeps AGC, never asks again that meeting.

### P3 — Post-meeting surfacing
- When stop diagnostics classify `voice_processed` + `quiet_mic_unrecovered`,
  write an `audio_health` hint into the transcript frontmatter and show it on
  the Home row ("Your mic was muffled by another call app") with a one-click
  "Use enhanced mic pickup next time" action that flips the Settings toggle.
- Catches everyone who missed or declined the live prompt.

### P4 — Settings copy
- Reframe the toggle as "Enhanced mic pickup during calls (Apple voice
  processing)" with the trade-off stated plainly. Today's framing assumes the
  user already understands VPIO.

### P5 — Data validation (before and after)
- Check Sentry/PostHog `attenuation_kind` distribution to size the
  voice_processed-unrecovered population (manual dashboard step).
- Success metric: `quiet_mic_unrecovered` rate trends to ~0 on meetings where
  the prompt was accepted; no rise in output-ducking complaints because VPIO
  engages only on user consent, scoped to recording sessions (already disarmed
  at stop).

## 4. Explicitly rejected
- **Default-on VPIO** — proven regression (ducking ≠ zero at `.min`).
- **Raising AGC maxGain** — amplifies the noise floor and cannot restore
  AEC-gated speech; revisit only if data shows recoverable headroom.
- **Alternative capture APIs** — none: macOS process taps are output-only;
  there is no public API for an unprocessed copy of a device another process
  holds in voice mode.

## 5. Test plan
- Core unit tests (SPM): windowed-peak detector with synthetic peak sequences
  — sustained attenuation fires once; loud meeting never fires; brief quiet
  (mute button) never fires; AGC-pinned-gain condition.
- Policy tests for the cue → prompt wiring (mirroring MeetingSessionUIPolicy
  test style).
- Manual QA recipe (matches the original repro): empty Google Meet in Safari +
  internal mic; verify banner appears ~30s after speaking quietly, accepting
  restores level mid-recording, transcript includes post-boost speech, and
  Zoom playback loudness is unchanged when the prompt is declined.
- Live-capture smoke unchanged (no TCC-dependent additions).

## 6. Effort
P1+P2 roughly a week including UI; P3+P4 a few days. P5 is a dashboard check.
Ship P1-P4 together — detection without the prompt is invisible, and the
prompt without detection is noise.
