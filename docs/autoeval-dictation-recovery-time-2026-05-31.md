# Autoeval: Dictation Recovery Time

## Verdict

Winner: keep the bounded recovery-loop combo.

Changes kept:

- Poll the dictation readiness wait loop every 100 ms instead of 150 ms.
- Force hard input-readiness recovery after 5 stale refreshes instead of 6.
- Cap ready-flag microphone start failures at 2 attempts instead of 3.

Controlled recovery harness result:

- Baseline slow-path p95/max: 2440 ms / 2440 ms.
- Winning combo p95/max: 1990 ms / 1990 ms.
- Change: -450 ms p95 and max, -1 start attempt, no new unexpected success
  failures, no new `microphone_start_timeout`.

This is the fastest safe combo from the expanded pass. More aggressive knobs
looked tempting, but they either started recovery too early for late Bluetooth
settling or increased refresh/rebuild churn.

## Metric

- Primary: request-to-listening time for dictation starts that miss the clean
  ready fast path.
- Secondary: start attempts, guarded recovery starts, forced recoveries,
  refresh timeouts, and `microphone_start_timeout`.
- Guardrails: no fake listening before real recording, no infinite retry loops,
  no worse ready-fast-path behavior, bounded hard recovery, privacy-safe
  diagnostics only, and green build/tests.

## Event And Test Sources

- Live event log: `~/Library/Application Support/Transcripted/logs/events.jsonl`
- Controlled policy harness:
  `ruby scripts/ops/dictation-recovery-autoeval.rb --details`
- Build budget: `scripts/ops/performance-budget.rb`
- Synthetic reliability check: `bash run-daily-audio-reliability.sh --synthetic`
- Manual checklist reference: `docs/qa-parakeet-start-failure-smoke.md`

Existing relevant events found in code/logs:

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
- `microphone_start_timeout`
- `audio_samples_detected`

## Historical Baseline

Command source: live local events log, refreshed on 2026-05-31.

Raw slice:

```text
events_total=15053
first=2026-05-09T11:01:58.936Z
last=2026-05-31T19:56:36.271Z
```

| Metric | Raw result |
| --- | ---: |
| `dictation_started_after_wait` samples | 65 |
| wait min | 349 ms |
| wait p50 | 386 ms |
| wait p90 | 407 ms |
| wait p95 | 681 ms |
| wait max | 6547 ms |
| `dictation_recording_retry` | 61 |
| `dictation_fast_start_fell_back_to_wait` | 5 |
| `dictation_recording_recovery_start` | 6 |
| `input_readiness_recovery_forced` | 4 |
| `dictation_readiness_refresh_timeout` | 2 |
| `microphone_start_timeout` | 2 |
| `audio_format_unavailable` | 6 |
| `audio_engine_start_failed` | 0 |
| `audio_samples_detected` start-to-first-sample p95 | 232 ms |

Last 24h recovery counts:

```text
dictation_started_after_wait=1
dictation_fast_start_fell_back_to_wait=1
dictation_recording_retry=0
dictation_recording_recovery_start=1
dictation_readiness_refresh_timeout=1
input_readiness_recovery_forced=0
microphone_start_timeout=0
```

The live log is useful for failure shape, but it is not enough to compare knobs:
the hard cases are sparse and depend on physical route timing. The harness below
is the repeatable scoring command for knob testing.

## Controlled Baseline

Command:

```bash
ruby scripts/ops/dictation-recovery-autoeval.rb --details
```

Baseline raw results:

| Scenario | Outcome | Time | Normal | Recovery | Refreshes | Forced | Timeouts | Reason |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| fast_ready_no_recovery | success | 85 ms | 1 | 0 | 0 | 0 | 0 | ready_start |
| cold_launch_unready_then_ready | success | 840 ms | 1 | 0 | 3 | 0 | 0 | ready_start |
| wake_recovery_finishes | success | 1290 ms | 1 | 0 | 0 | 0 | 0 | ready_start |
| bluetooth_reconnect_stale_flag | success | 1170 ms | 0 | 1 | 4 | 0 | 0 | recovery_start |
| bluetooth_late_ready_stale_flag | success | 1170 ms | 0 | 1 | 4 | 0 | 0 | recovery_start |
| slow_refresh_would_recover | success | 2440 ms | 1 | 1 | 0 | 1 | 0 | ready_start |
| selected_input_stale_until_force | success | 2440 ms | 1 | 1 | 0 | 1 | 0 | ready_start |
| first_start_fails_retry_succeeds | success | 330 ms | 2 | 0 | 1 | 0 | 0 | ready_start |
| ready_flag_start_keeps_failing | success | 1600 ms | 4 | 0 | 0 | 1 | 0 | ready_start |
| refresh_times_out_then_recovery_start | success | 1000 ms | 0 | 1 | 1 | 0 | 1 | recovery_start |
| unrecoverable_route_times_out | timeout | 6000 ms | 0 | 2 | 5 | 2 | 0 | microphone_start_timeout |

## Knobs Tested

| # | Knob | Status | Raw result | Decision |
| ---: | --- | --- | --- | --- |
| 1 | Poll interval 150 -> 100 ms | kept | p95 2440 -> 2290 ms, starts unchanged, refreshes +1 | Safe responsiveness win |
| 2 | Poll interval 150 -> 75 ms | rejected | p95 unchanged, refreshes +4 | More churn for no p95 win |
| 3 | Refresh interval 300 -> 200 ms | rejected | p95 unchanged | No standalone win |
| 4 | Refresh interval 300 -> 150 ms | rejected | p95 -570 ms but starts +2, refreshes +5, forced +2, Bluetooth +700 ms | Too much churn and Bluetooth regression |
| 5 | Recovery start after 3 refreshes | rejected | Bluetooth early case -300 ms, late Bluetooth +1300 ms, p95 +30 ms | Burns guarded attempt too early |
| 6 | Recovery start after 2 refreshes | rejected | cold launch -290 ms, Bluetooth +1300 ms, starts +2, forced +2 | Too aggressive |
| 7 | Ready-start cap 3 -> 2 | kept | ready-flag-start-failing 1600 -> 1350 ms, starts -1 | Fewer retries without hurting first-fail retry-success |
| 8 | Ready-start cap 3 -> 1 | rejected | first-fail retry-success +600 ms, ready-flag-start-failing +500 ms, forced +2 | Removes useful single retry |
| 9 | Forced recovery threshold 6 -> 5 | kept | p95 2440 -> 2140 ms, starts unchanged, forced unchanged, refreshes +2 | Earlier hard recovery after one guarded start |
| 10 | Forced recovery threshold 6 -> 4 | rejected | p95 -540 ms but Bluetooth +730 ms, recovery starts -5, forced +2 | Rebuilds too early |
| 11 | Combo: poll100 + force5 | tested | p95 1990 ms, starts unchanged, refreshes +3 | Good, but keep attempt cap too |
| 12 | Combo: poll100 + ready cap 2 | tested | p95 2290 ms, starts -1 | Safe but smaller win |
| 13 | Combo: poll100 + force5 + ready cap 2 | kept | p95 2440 -> 1990 ms, starts 18 -> 17, forced unchanged, no new timeouts | Best safe overall |
| 14 | Combo: poll100 + refresh200 + ready cap 2 | rejected | p95 1920 ms, but late Bluetooth +750 ms, refreshes +4, forced +1 | Faster aggregate, worse route-switch guardrail |
| 15 | Device recovery timeout 4 s -> lower | ruled out | Historical logs have no successful device-recovery duration event | Too likely to abandon slow real hardware |
| 16 | Recovery budget 6 s -> lower | ruled out | Would only make failure faster, not recovery more reliable | Risks false timeouts |
| 17 | Audio tap buffer size | not run | An unrelated worktree change appeared, but this pass did not test it | Kept out of this commit |

Winning combo raw scenario deltas:

| Scenario | Baseline | Winner | Delta |
| --- | ---: | ---: | ---: |
| fast_ready_no_recovery | 85 ms | 85 ms | 0 |
| cold_launch_unready_then_ready | 840 ms | 790 ms | -50 |
| wake_recovery_finishes | 1290 ms | 1290 ms | 0 |
| bluetooth_reconnect_stale_flag | 1170 ms | 1120 ms | -50 |
| bluetooth_late_ready_stale_flag | 1170 ms | 1120 ms | -50 |
| slow_refresh_would_recover | 2440 ms | 1990 ms | -450 |
| selected_input_stale_until_force | 2440 ms | 1990 ms | -450 |
| first_start_fails_retry_succeeds | 330 ms | 280 ms | -50 |
| ready_flag_start_keeps_failing | 1600 ms | 1200 ms | -400 |
| refresh_times_out_then_recovery_start | 1000 ms | 1000 ms | 0 |
| unrecoverable_route_times_out | 6000 ms | 6000 ms | 0 |

## Kept Changes

- `Sources/Support/TranscriptedConstants.swift`
  - `dictationReadinessPollInterval`: 150 ms -> 100 ms.
  - `dictationReadinessForcedRecoveryRefreshes`: 6 -> 5.
- `Sources/Speech/DictationReadinessWaitPolicy.swift`
  - Ready-format start failure cap: 3 -> 2.
- `Tests/DictationReadinessWaitPolicyTests.swift`
  - Updated retry-cap assertions and added default forced-threshold coverage.
- `scripts/ops/dictation-recovery-autoeval.rb`
  - Added repeatable controlled recovery harness for this class of changes.

## Rejected Attempts

- Did not lower refresh interval. The best-looking refresh interval run created
  more starts, refreshes, and forced recoveries, and regressed late Bluetooth.
- Did not lower guarded recovery start threshold. It helps if Bluetooth is ready
  early, but late Bluetooth burns the one guarded attempt and gets slower.
- Did not force after 4 refreshes. It rebuilds before the guarded recovery start
  can prove whether audio is already recordable.
- Did not cap ready starts at 1. One retry is still useful and tested.
- Did not reduce device recovery timeout or total recovery budget. Those would
  make failure faster without proving recovery is safer.
- Did not include the unrelated `audioTapBufferSize` 1024 -> 256 worktree
  change. It was not tested in this autoeval.

## Tests Run

```bash
ruby -c scripts/ops/dictation-recovery-autoeval.rb
ruby scripts/ops/dictation-recovery-autoeval.rb --details
bash build.sh --no-open
bash run-tests.sh
bash run-integration-smoke.sh
swift test
bash run-e2e-smoke.sh
bash run-daily-audio-reliability.sh --synthetic
ruby -c scripts/ops/performance-budget.rb
ruby scripts/ops/performance-budget.rb --allow-missing-parakeet-model --events "$HOME/Library/Application Support/Transcripted/logs/events.jsonl" --stats "$HOME/Library/Application Support/Transcripted/state/stats.sqlite"
```

Results:

- Harness: passed; winning combo p95/max 1990 ms.
- `bash build.sh --no-open`: passed, including built-in performance budget.
- `bash run-tests.sh`: passed, 2936 passed / 0 failed.
- `bash run-integration-smoke.sh`: passed.
- `swift test`: passed, 339 passed / 0 failed / 1 skipped live capture test.
- `bash run-e2e-smoke.sh`: passed.
- `bash run-daily-audio-reliability.sh --synthetic`: passed, 72 passed / 0
  failed / 0 skipped.
- `ruby -c scripts/ops/performance-budget.rb`: passed.
- Full historical `performance-budget.rb --events --stats`: failed existing
  non-recovery budgets: dictation transcription p95 RTF 0.053 > 0.050 and
  meeting processing p95 RTF 0.065 > 0.050.

## Remaining Risks

- Live Bluetooth reconnect/sleep testing was not run because it needs physical
  route manipulation and microphone capture. The deterministic harness covers
  those timing shapes, but it is still not a hardware trace.
- The historical 6547 ms outlier is still a device/route settling long tail.
  This patch should shorten the recovery loop before hard rebuild, but it does
  not prove every physical device will settle under 2 seconds.
- The new harness is intentionally conservative and synthetic. It should be
  rerun with fresh hardware logs as soon as a route-switch capture is available.

## Next Run

Run 10-20 fresh dictation starts each for built-in input, Bluetooth reconnect,
and wake-from-sleep on this branch. Compare:

- `dictation_started_after_wait.wait_ms`
- `dictation_started_after_wait.request_to_recording_ms`
- `dictation_recording_retry`
- `dictation_recording_recovery_start`
- `input_readiness_recovery_forced`
- `dictation_readiness_refresh_timeout`
- `microphone_start_timeout`
