# Autoeval: Dictation Recovery Time

## Verdict

Winner: keep the input-override settle change already on this branch.

When Transcripted applies a preferred dictation input override and the immediate
CoreAudio snapshot is already ready, the app now skips the old fixed 300 ms
settle delay. It still waits when the route is stale or invalid, so it does not
pretend to be listening before recording can actually start.

## Metric

- Primary: time from dictation start request to listening when dictation does
  not cleanly hit the ready fast path, measured by `dictation_started_after_wait`
  `wait_ms`.
- Secondary: counts of `dictation_recording_retry`,
  `dictation_fast_start_fell_back_to_wait` / `audio_start_deferred`,
  `microphone_start_timeout`, guarded recovery starts, forced input recoveries,
  and readiness refresh timeouts.
- Guardrails: no fake listening before real recording, no infinite retries, no
  extra `microphone_start_timeout`, privacy-safe route diagnostics only, and
  green build/tests.

## Event Sources

- Runtime events: `~/Library/Application Support/Transcripted/logs/events.jsonl`
- Build performance gate: `scripts/ops/performance-budget.rb`
- Synthetic guardrail: `bash run-daily-audio-reliability.sh --synthetic`
- Manual recovery checklist reference:
  `docs/qa-parakeet-start-failure-smoke.md`

Relevant event names found in code:

- `dictation_recording_fast_start`
- `dictation_fast_start_fell_back_to_wait`
- `dictation_started_after_wait`
- `dictation_recording_retry`
- `dictation_recording_recovery_start`
- `dictation_readiness_refresh_timeout`
- `input_readiness_recovery_forced`
- `audio_start_deferred`
- `audio_format_unavailable`
- `audio_engine_start_failed`
- `device_change_rewarm_deferred`
- `device_change_recovery_deferred`
- `microphone_start_timeout`

## Baseline Raw Results

Source file:

```text
~/Library/Application Support/Transcripted/logs/events.jsonl
```

Raw slice:

```text
events_total=14270
first=2026-05-09T11:01:58Z
last=2026-05-31T19:06:41Z
```

Baseline metrics:

| Metric | Raw result |
| --- | ---: |
| `dictation_started_after_wait` samples | 64 |
| wait min | 349 ms |
| wait p50 | 386 ms |
| wait p90 | 402 ms |
| wait p95 | 455 ms |
| wait max | 6547 ms |
| `dictation_recording_retry` | 61 |
| fallback-to-wait-like events | 65 |
| `dictation_recording_recovery_start` | 5 |
| `input_readiness_recovery_forced` | 4 |
| `dictation_readiness_refresh_timeout` | 1 |
| `microphone_start_timeout` | 2 |
| audio start / format failures | 8 |
| `dictation_input_device_override_settled` | 403 |

By route:

| Route | Samples | p50 | p90 | p95 | Max |
| --- | ---: | ---: | ---: | ---: | ---: |
| built-in input to built-in output | 61 | 386 ms | 399 ms | 402 ms | 455 ms |
| built-in input to Bluetooth output | 3 | 717 ms | 6547 ms | 6547 ms | 6547 ms |

Last 24h recovery counts were all zero for `dictation_started_after_wait`,
`dictation_recording_retry`, fallback-to-wait, guarded recovery starts, forced
input recovery, and `microphone_start_timeout`, so the recovery baseline is
historical rather than a fresh live repro.

## Recovery Scenarios Checked

| Scenario | Evidence |
| --- | --- |
| App just launched | 703 `app_launched` events; current last-24h logs had no recovery waits/timeouts. |
| Wake from sleep | 4 `wake_recovery` and 2 `wake_hotkey_recovery_failed` events in the log set. |
| Bluetooth reconnect/switch | 262 `default_input_device_changed`, 703 `device_change_rewarm_deferred`, and 253 `prewarm_invalid_format` events. |
| Selected route stale | 6 `audio_format_unavailable` and 2 `audio_route_not_settled` events. |
| First start fails, retry succeeds | 62 after-wait starts had more than one start attempt. |
| Format ready but start fails | 61 ready-format start-deferred/retry events. |
| Recovery waits too long before refresh | 1 `dictation_readiness_refresh_timeout` and 4 `input_readiness_recovery_forced` events. |

## Knobs Tested

| # | Knob | Change | Raw result | Decision |
| ---: | --- | --- | --- | --- |
| 1 | Skip fixed input-override settle delay when immediate format is ready | 300 ms -> 0 ms only for `.ready`; keep 300 ms for `.routeNotSettled` / `.invalid` | Recovery projection: 3 eligible Bluetooth-output after-wait samples. All waits p95 455 -> 417 ms. Bluetooth waits p50 717 -> 417 ms. Max 6547 -> 6247 ms. | Keep |
| 2 | Readiness polling interval | Considered 150 ms -> lower | Logs show common built-in waits are dominated by one recovery delay plus actual start, not by polling alone. Would add more UI/CoreAudio polling with weak evidence. | Reject |
| 3 | Readiness refresh interval | Considered 0.3 s -> lower | Timeout path already has a 0.9 s stale-refresh guard; route-settling failures were mostly stale Bluetooth output, not slow refresh cadence. | Reject |
| 4 | Forced recovery threshold | Considered forcing earlier than 6 refreshes | Historical hard cases still had `.routeNotSettled`; earlier hard rebuilds risk more rebuild churn without proof of fewer timeouts. | Reject |
| 5 | Device recovery timeout budget | Considered reducing 4 s | Could reduce the 6547 ms outlier, but there are 78 idle recovery-deferred events and no local success-duration event proving 3 s is safe. | Reject |
| 6 | Max start attempts before hard recovery | Already bounded by policy | Existing policy caps normal ready-input starts and recovery starts; changing it would risk more retries rather than fewer. | No change |
| 7 | Trust stale ready state | Keep current distrust | Code already requires not recovering plus ready format before normal start; recovery attempts are explicitly marked. | No change |
| 8 | Move failure cleanup/reporting off critical path | Not applicable | Timeout cleanup is after the 6 s budget and does not improve start-to-listening. | Reject |

Projection command for the kept knob:

```bash
ruby -rjson -rtime - "$HOME/Library/Application Support/Transcripted/logs/events.jsonl"
```

Projection output:

```text
eligible_recovery_wait_samples=3
all_waits count=64 p50=386.0->386.0 p90=402.0->400.0 p95=455.0->417.0 max=6547.0->6247.0
bluetooth_waits count=3 p50=717.0->417.0 p90=6547.0->6247.0 p95=6547.0->6247.0 max=6547.0->6247.0
eligible_rows:
2026-05-19T11:13:18Z built_in_input_to_bluetooth_output 681.0->381.0
2026-05-20T17:30:35Z built_in_input_to_bluetooth_output 717.0->417.0
2026-05-27T01:08:08Z built_in_input_to_bluetooth_output 6547.0->6247.0
```

## Kept Changes

- `Sources/Speech/ParakeetEngine.swift`
  - Checks immediate audio format readiness after applying a preferred input
    override.
  - Returns immediately when the format is `.ready`.
  - Keeps the old settle wait when the route is stale or invalid.
- `Sources/Speech/ParakeetStartRecordingFailurePolicy.swift`
  - Adds `ParakeetInputOverrideSettlePolicy`.
- `Tests/ParakeetStartRecordingFailurePolicyTests.swift`
  - Covers ready, route-not-settled, and invalid settle decisions.

## Rejected Attempts

- Did not lower polling/refresh intervals. The measured recovery waits do not
  prove those are the dominant delay, and lower intervals would increase churn.
- Did not reduce the 4 s device recovery timeout. It might help one outlier but
  could prematurely abandon slower real device recovery.
- Did not raise retry counts. The goal is fewer retries and clearer failure, not
  more attempts.
- Did not change timeout cleanup. It happens after the recovery budget is
  exhausted, so it does not reduce start-to-listening.

## Tests Run

```bash
bash build.sh --no-open
bash run-tests.sh
bash run-daily-audio-reliability.sh --synthetic
ruby -c scripts/ops/performance-budget.rb
ruby scripts/ops/performance-budget.rb --allow-missing-parakeet-model --events "$HOME/Library/Application Support/Transcripted/logs/events.jsonl" --stats "$HOME/Library/Application Support/Transcripted/state/stats.sqlite"
```

Results:

- `bash build.sh --no-open`: passed. The build's built-in performance budget
  passed.
- `bash run-tests.sh`: passed, 2929 passed / 0 failed.
- `bash run-daily-audio-reliability.sh --synthetic`: passed, 72 passed / 0
  failed / 0 skipped.
- `ruby -c scripts/ops/performance-budget.rb`: passed.
- Full historical `performance-budget.rb --events --stats`: failed on existing
  transcription and meeting throughput budgets, not on dictation recovery
  metrics. It does not currently score `dictation_started_after_wait`.

## Remaining Risks

- This is a historical projection plus unit/build verification, not a fresh live
  Bluetooth recovery capture from this exact build.
- The biggest 6547 ms case is mostly route-settling/device-recovery timeout, so
  the kept change only shaves the final ready override settle delay from it.
- There is no local event for successful device-recovery duration, which makes
  lowering `audioDeviceRecoveryTimeout` too speculative.

## Next Run

Capture 10-20 fresh starts on a Bluetooth-output route from this branch and
compare `dictation_started_after_wait`, `dictation_recording_retry`,
`dictation_recording_recovery_start`, and `microphone_start_timeout` against the
baseline above.
