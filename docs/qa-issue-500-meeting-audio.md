# Issue 500 Meeting Audio QA

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
- pass or fail
- notes

The volume `before` and `during` values come from `meeting_recording_started` or `meeting_recording_stopped`. The `after` values and peak values come from `meeting_recording_stopped` or `meeting_recording_cancelled`.
`system_peak` is the system-audio peak.
The dropped flags are generated from the same scalar fields and are also attached to degraded-capture diagnostics.

## Results Sheet

Copy this table into the issue or local notes before a run. Keep the raw scalar
values in `event values` so the pass/fail call can be checked later.

| App | Route | Voice processing | Meeting volume | Mic usable | System audio present | Output dropped | Result | Event values | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Chrome Meet | built-in mic/speakers | off | same / quieter / louder / unusable | yes / no | yes / no / n/a | yes / no | pass / fail | `mic_raw_peak=`, `mic_processed_peak=`, `system_peak=`, `default_output_volume_before=`, `default_output_volume_during=`, `default_output_volume_after=` |  |
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
