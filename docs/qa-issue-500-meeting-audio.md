# Issue 500 Meeting Audio QA

## 2026-07-03 status update

GitHub issue #500 is closed (2026-06-12), but that reflects code landing, not
a completed run of the matrix below — every row in the Results Sheet is still
an unfilled template. Since the 1.1.47 release-candidate notes were written:

- `v1.1.47` (2026-06-08) shipped the baseline fixes: the mic downmix fix
  (PR #959) and a higher software AGC gain cap, 12x → 25x (PR #960).
- `v1.1.48` (2026-06-13) shipped the real follow-through: live quiet-mic
  attenuation detection with a consent-based "Boost Mic" prompt (PR #1075),
  plus about two weeks of self-audit hardening passes (edge-case/race fixes,
  wording clarification, applying the same boost preference to dictation).
  None of those follow-ups trace back to a new user report — the original
  reporter (LeonStaufer) has not commented since the closing comment, and no
  regression has resurfaced on the issue thread.
- The in-repo automation (`scripts/ops/daily-audio-reliability-check.sh`)
  generates its own report saying, verbatim: "Manual route proof still
  required before issue #500 can be called green" and lists the exact gaps —
  real Safari/Firefox/Chrome Meet and Zoom audio, AirPods/Bluetooth/USB
  routes, user-perceived volume, and saved-transcript proof that the
  processed mic path was used. The most recent local run of that script
  (2026-07-02) was `--synthetic`-only; no real-hardware run is on record.

**Bottom line:** the code and automated-test coverage are meaningfully
stronger than at 1.1.47, and the shipped fix has had ~3 weeks of real usage
in `v1.1.48` with no negative follow-up. That is a reasonable signal, but it
is not the same as running this matrix for real. Treat #500 as
code-complete-but-not-manually-validated until someone actually runs the
matrix below (or a Sentry/PostHog meeting-audio-health check scoped to
`v1.1.48`+ is done and comes back clean).

Use this checklist before changing meeting mic processing again.

The goal is to prove three things:

- STT and the saved mic file receive Transcripted's processed mic copy.
- System audio capture stays separate and untouched.
- Transcripted does not change the user's default input or output volume.

## Setup

Build and launch the app you are testing:

```bash
bash build.sh --no-open
open build/Transcripted.app
```

Watch the local event log:

```bash
tail -f ~/Library/Application\ Support/Transcripted/logs/events.jsonl | rg --line-buffered "meeting_recording_started|meeting_recording_stopped|meeting_recording_cancelled"
```

For end-call prompt and degraded-route diagnostics, include the inactivity
warning events too:

```bash
tail -f ~/Library/Application\ Support/Transcripted/logs/events.jsonl | rg --line-buffered "meeting_recording_started|meeting_recording_stopped|meeting_recording_cancelled|meeting_audio_inactivity_warning_started|meeting_audio_inactivity_timeout_deferred|meeting_audio_inactivity_timeout|meeting_audio_inactivity_end_requested|meeting_audio_inactivity_warning_dismissed|meeting_audio_inactivity_warning_cleared"
```

Use a simple spoken phrase so no private content lands in logs or transcripts:

```text
Transcripted issue five hundred audio test one two three.
```

## Matrix

Run each meeting app with each available device route.

Meeting apps:

- Chrome Meet
- Safari Meet
- Firefox Meet
- WhatsApp Mac
- Zoom
- no meeting app

Device routes:

- built-in mic and speakers
- AirPods or Bluetooth
- USB mic, if available

For Safari and Firefox, run once with Apple voice processing off and once with it on. For every other app, start with it off.

## What To Record

For each run, capture:

- app
- device route
- Apple voice processing: on or off
- user-perceived meeting volume: same, quieter, louder, unusable
- `mic_raw_peak`
- `mic_processed_peak`
- `system_peak`
- `default_input_volume_before`
- `default_input_volume_during`
- `default_input_volume_after`
- `default_output_volume_before`
- `default_output_volume_during`
- `default_output_volume_after`
- `default_system_output_volume_before`
- `default_system_output_volume_during`
- `default_system_output_volume_after`
- `default_output_volume_dropped`
- `default_system_output_volume_dropped`
- `attenuation_kind`
- `output_ducking_detected`
- `warning_kind`
- `automatic_stop_allowed`
- pass or fail
- notes

The volume `before` and `during` values come from `meeting_recording_started` or `meeting_recording_stopped`. The `after` values and peak values come from `meeting_recording_stopped` or `meeting_recording_cancelled`.
`system_peak` is the system-audio peak.
The dropped flags are generated from the same scalar fields and are also attached to degraded-capture diagnostics.
The warning fields come from `meeting_audio_inactivity_*` events and help
separate quiet-audio capture from the prompt that asks whether the meeting
should end.

## Results Sheet

Copy this table into the issue or local notes before a run. Keep the raw scalar
values in `event values` so the pass/fail call can be checked later.

| App | Route | Voice processing | Meeting volume | Mic usable | System audio present | Output dropped | Result | Event values | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Chrome Meet | built-in mic/speakers | off | same / quieter / louder / unusable | yes / no | yes / no / n/a | yes / no | pass / fail | `mic_raw_peak=`, `mic_processed_peak=`, `system_peak=`, `default_output_volume_before=`, `default_output_volume_during=`, `default_output_volume_after=`, `attenuation_kind=`, `output_ducking_detected=`, `warning_kind=`, `automatic_stop_allowed=` |  |
| Safari Meet | built-in mic/speakers | off | same / quieter / louder / unusable | yes / no | yes / no / n/a | yes / no | pass / fail |  |  |
| Safari Meet | built-in mic/speakers | on | same / quieter / louder / unusable | yes / no | yes / no / n/a | yes / no | pass / fail |  |  |
| Firefox Meet | built-in mic/speakers | off | same / quieter / louder / unusable | yes / no | yes / no / n/a | yes / no | pass / fail |  |  |
| Firefox Meet | built-in mic/speakers | on | same / quieter / louder / unusable | yes / no | yes / no / n/a | yes / no | pass / fail |  |  |
| WhatsApp Mac | built-in mic/speakers | off | same / quieter / louder / unusable | yes / no | yes / no / n/a | yes / no | pass / fail |  |  |
| Zoom | built-in mic/speakers | off | same / quieter / louder / unusable | yes / no | yes / no / n/a | yes / no | pass / fail |  |  |
| no meeting app | built-in mic/speakers | off | same / quieter / louder / unusable | yes / no | yes / no / n/a | yes / no | pass / fail |  | baseline |
| Chrome Meet | AirPods/Bluetooth | off | same / quieter / louder / unusable | yes / no | yes / no / n/a | yes / no | pass / fail |  |  |
| Safari Meet | AirPods/Bluetooth | off | same / quieter / louder / unusable | yes / no | yes / no / n/a | yes / no | pass / fail |  |  |
| Safari Meet | AirPods/Bluetooth | on | same / quieter / louder / unusable | yes / no | yes / no / n/a | yes / no | pass / fail |  |  |
| Firefox Meet | AirPods/Bluetooth | off | same / quieter / louder / unusable | yes / no | yes / no / n/a | yes / no | pass / fail |  |  |
| Firefox Meet | AirPods/Bluetooth | on | same / quieter / louder / unusable | yes / no | yes / no / n/a | yes / no | pass / fail |  |  |
| WhatsApp Mac | AirPods/Bluetooth | off | same / quieter / louder / unusable | yes / no | yes / no / n/a | yes / no | pass / fail |  |  |
| Zoom | AirPods/Bluetooth | off | same / quieter / louder / unusable | yes / no | yes / no / n/a | yes / no | pass / fail |  |  |
| no meeting app | AirPods/Bluetooth | off | same / quieter / louder / unusable | yes / no | yes / no / n/a | yes / no | pass / fail |  | baseline |
| Chrome Meet | USB mic | off | same / quieter / louder / unusable | yes / no | yes / no / n/a | yes / no | pass / fail |  | if available |
| Safari Meet | USB mic | off | same / quieter / louder / unusable | yes / no | yes / no / n/a | yes / no | pass / fail |  | if available |
| Safari Meet | USB mic | on | same / quieter / louder / unusable | yes / no | yes / no / n/a | yes / no | pass / fail |  | if available |
| Firefox Meet | USB mic | off | same / quieter / louder / unusable | yes / no | yes / no / n/a | yes / no | pass / fail |  | if available |
| Firefox Meet | USB mic | on | same / quieter / louder / unusable | yes / no | yes / no / n/a | yes / no | pass / fail |  | if available |
| WhatsApp Mac | USB mic | off | same / quieter / louder / unusable | yes / no | yes / no / n/a | yes / no | pass / fail |  | if available |
| Zoom | USB mic | off | same / quieter / louder / unusable | yes / no | yes / no / n/a | yes / no | pass / fail |  | if available |
| no meeting app | USB mic | off | same / quieter / louder / unusable | yes / no | yes / no / n/a | yes / no | pass / fail |  | baseline, if available |

## Pass Bar

A run passes when:

- the meeting stays audible to the user
- output volume scalars do not drop unless the tester changed them
- `mic_processed_peak` is usable for quiet mic cases
- `system_peak` stays present when the meeting app is playing audio
- the saved transcript uses the processed mic path

If the user's meeting gets quieter, stop. Do not ship another behavior change from that run.
