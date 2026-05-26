# BET-88 QA Smoke: Parakeet `startRecording` Failure Hardening

This checklist validates the BET-88 fix around `ParakeetEngine.startRecording()`
failure handling and retry behavior.

## Preconditions

- Build includes BET-88 changes.
- Transcripted launches normally.
- Dictation hotkey works in a normal path.
- You can monitor logs/events while testing.

## Suggested Log Monitoring

Use one of these during the smoke run:

```bash
tail -f ~/Library/Application\ Support/Transcripted/logs/events.jsonl | rg "audio_format_unavailable|audio_engine_start_failed|recording_interrupted|zombie_engine"
```

or, if you want full event context without filtering:

```bash
tail -f ~/Library/Application\ Support/Transcripted/logs/events.jsonl
```

You should see `is_recovery_attempt` in the relevant Parakeet start-failure payloads.

## Scenario 1: Bluetooth device reconnect churn during dictation start

1. Connect a Bluetooth headset/mic.
2. Start dictation and confirm normal capture once.
3. Stop dictation.
4. Trigger device instability:
   - disconnect/reconnect the headset quickly, or
   - switch default input between Bluetooth and built-in mic rapidly.
5. Immediately start dictation again during/after the churn.

Expected:

- App does not get stuck in an infinite retry loop.
- Dictation either starts successfully after recovery or fails with a clear error.
- Recovery attempts do not chain extra retries indefinitely.
- Event diagnostics for start failures include `is_recovery_attempt`.

## Scenario 2: Sleep/wake + start failure handling

1. Put Mac to sleep.
2. Wake Mac and wait briefly for device graph to settle.
3. Start dictation.
4. If it fails, retry once after a short pause.

Expected:

- Failure path resets cleanly (no stale recording state).
- Format-ready state transitions recover correctly before next successful start.
- Start failures during recovery attempts do not schedule repeated nested retries.

## Scenario 3: Regression sanity

1. Run 3-5 normal dictation starts/stops on a stable input device.

Expected:

- Normal start/stop behavior is unchanged.
- No new startup latency or repeated warning spam on healthy devices.

## Pass Criteria

- No runaway retry behavior observed.
- No persistent “stuck” state after a failed start.
- Dictation can recover and start again after transient device instability.
- Logged failure events include enough context for debugging (`audio_device`, format details, `is_recovery_attempt`).

## QA Result Comment Format (for `#428`)

The manual BET-88 gate helper reads the first non-empty line of your top-level
comment on `#428`. The GitHub auto-close workflow is additionally gated by the
`qa-gate-auto-close` label so old issue comments cannot mutate closed issues by
accident.

Use one of these exact first-line forms:

- `PASS`
- `PASS: <short summary>`
- `FAIL`
- `FAIL: <short summary>`

Example PASS comment:

```text
PASS: smoke validated on sleep/wake + Bluetooth churn, no nested retry loops observed.

Evidence:
- Scenario 1: pass
- Scenario 2: pass
- Scenario 3: pass
```

Example FAIL comment:

```text
FAIL: scenario 2 still gets stuck after wake when device graph flaps.

Evidence:
- Repro steps: <what you did>
- Observed events: <relevant event names / snippets>
- Expected vs actual: <brief delta>
```
