# Daily Audio Reliability Check

Run this when you want to make Transcripted audio boring.

The contract is a small state machine, not a pile of random checks:

- success
- degraded success
- recoverable failure
- permanent failure
- no-artifact failure

Every failure should also name its stage, retryability, artifact retention, and
user-visible state.

```bash
bash run-daily-audio-reliability.sh
```

It builds the app, relaunches `build/Transcripted.app`, walks through the daily
manual scenarios, collects local logs after each scenario, and writes a report
under:

```text
/tmp/transcripted-repro-lab/audio-daily-YYYYMMDD-HHMMSS/
```

Use only synthetic speech, for example:

```text
Transcripted daily test one two three.
```

## What This Catches

- start dictation after launch
- start dictation after sleep/wake
- start dictation after Bluetooth or input-device change
- start meeting after device change
- recover when mic/audio route is weird
- clear user message when capture cannot start
- retry path that feels calm, not broken
- fast meeting start/stop races

For the issue #500 meeting-volume matrix, use:

```text
docs/qa-issue-500-meeting-audio.md
```

## Daily Pass Bar

The run passes only when the normal flows work and any failed meeting can answer:

- did recording start?
- was audio captured?
- did transcription fail?
- did diarization fail?
- did save fail?
- was there a recoverable artifact?
- can the user retry?

If a scenario fails, keep the report folder. It is the repro packet.

## Options

Skip the build when you already built the exact app you want to test:

```bash
bash run-daily-audio-reliability.sh --skip-build
```

Use the current running app instead of relaunching:

```bash
bash run-daily-audio-reliability.sh --skip-build --no-launch
```

Run the deterministic synthetic-only pass:

```bash
bash run-daily-audio-reliability.sh --synthetic
```

Compare a rerun against an earlier run:

```bash
bash run-daily-audio-reliability.sh --compare audio-daily-YYYYMMDD-HHMMSS
```

## Evidence

Each scenario calls the repro-lab collector from:

```text
~/.codex/skills/transcripted-repro-lab/scripts/collect_repro_logs.sh
```

The collector copies local app logs, recent Transcripted crash reports, repo
metadata, and audio-device state into the run folder. Keep raw artifacts local.
Do not upload user audio, transcripts, raw paths, tokens, or private content.

Useful searches:

```bash
rg "audio_format_unavailable|audio_engine_start_failed|microphone_start_timeout|device_change|recover|retry" /tmp/transcripted-repro-lab/<run-id>
rg "meeting_recording_started|meeting_capture_health_snapshot|meeting_transcript_saved|meeting_transcription_failed" /tmp/transcripted-repro-lab/<run-id>
```

## Synthetic Mode

`--synthetic` does not touch Bluetooth, sleep/wake, or the live app. It creates
local WAV fixtures for silence, quiet audio, normal audio, too-short audio,
speaker-like tones, and corrupted input. It also writes a deterministic failure
matrix for the state-machine contract:

- stage
- outcome kind
- retryability
- artifact retention
- user-visible state
- the seven meeting-failure questions

It also creates deterministic meeting-route fixture folders under the report
directory. These simulate shared mic, system audio present/missing, quiet mic
recovery, output ducking, route churn, stop timeout, and retained failed-queue
states. The saved-artifact path is covered by fast/Core tests; the generated
fixtures are synthetic proof, not real Zoom or browser proof.

It also writes an audio route automation proxy matrix for dictation pasteback,
meeting mic/system audio, mic/output mismatch diagnostics, WebRTC/Zoom
contention, Bluetooth/AirPods settling, and privacy/security. Those rows
document deterministic coverage only; real Zoom/Meet/AirPods volume proof still
uses `docs/qa-issue-500-meeting-audio.md`.

The same seven-field contract is covered by fast tests in:

```text
Tests/MeetingFailureExplanationTests.swift
Tests/MeetingRouteFixtureTests.swift
Sources/Meeting/MeetingFailureExplanation.swift
```

## When It Fails

Do not call one pass a proof.

Use the failed scenario folder as the before-run, patch narrowly, then rerun the
same scenario. After a fix, run:

```bash
bash build.sh --no-open
bash run-tests.sh
bash run-integration-smoke.sh
```

Run `swift test` too if the fix touches `Sources/TranscriptedCore/`,
`Package.swift`, or the public core package seam.
