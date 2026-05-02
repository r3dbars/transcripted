# Daily Audio Reliability Check

Run this when you want to make Transcripted audio boring.

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

## When It Fails

Do not call one pass a proof.

Use the failed scenario folder as the before-run, patch narrowly, then rerun the
same scenario. After a fix, run:

```bash
bash build.sh
bash run-tests.sh
bash run-integration-smoke.sh
```

Run `swift test` too if the fix touches `Sources/TranscriptedCore/`,
`Package.swift`, or the public core package seam.
