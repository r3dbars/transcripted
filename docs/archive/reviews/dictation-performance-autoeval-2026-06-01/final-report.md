# Autoeval: Dictation Performance

## Verdict

This pass kept three product changes: measure the whole stop pipeline precisely, make the scorer name the slowest stop stage, and shorten the opt-in auto-enter delay.

The app already starts dictation quickly in the normal warm path. The weak spot is that stop used to feel like one black box. Now each stop can say where the time went: mic stop, model wait, decode, cleanup, paste, auto-enter, save, and done.

## Baseline

Historical local logs, before this patch:

- Dictation fast start: n=747, p50=85ms, p90=126ms, p95=203ms, max=1178ms
- Dictation stop-to-paste: n=0, not measured before this patch
- Dictation decode after stop: n=597, p50=0.108s, p90=0.331s, p95=0.466s, max=1.134s
- Dictation RTF: p95=0.056, above the current 0.050 budget
- Meeting RTF: p95=0.065, above the current 0.050 budget

Fresh samples from this branch:

- Default-style dictation stop-to-paste: n=9, p95=175ms
- Full fresh dictation window after auto-enter samples: n=12, stop-to-paste p95=109ms, stop pipeline p95=233ms
- Dictation fast start: n=12, p95=155ms
- Dictation RTF: n=12, p95=0.016
- Meeting RTF: n=5, p95=0.023
- Default stop bottleneck: decode, p95=156ms
- Opt-in auto-enter bottleneck: auto-enter, p95=157ms
- Paste: p95=3ms
- Save: p95=2ms
- Auto-enter opt-in path: 200ms delay measured 212ms; 150ms delay measured 155-157ms

## Kept Change

Added `dictation_stop_latency_measured`.

Local-only event fields include exact milliseconds:

- `stop_to_mic_stop_ms`
- `mic_stop_to_decode_start_ms`
- `model_wait_ms`
- `decode_ms`
- `cleanup_ms`
- `paste_ms`
- `auto_enter_ms`
- `save_ms`
- `stop_to_paste_ms`
- `stop_to_save_ms`
- `stop_to_done_ms`

PostHog only gets coarse buckets, like `250_499ms` or `1_2s`. It does not get raw milliseconds.

Added fresh-window scoring to `scripts/ops/performance-budget.rb`:

- `--events-since`
- `--stats-since`
- `--min-transcription-samples`
- `--min-meeting-samples`

The default full-history scorer is still strict. The new options let experiments score only the fresh samples they produced.

Added stop-stage scoring to `scripts/ops/performance-budget.rb`:

- Prints p95, max, and count for each stop segment.
- Prints the slowest stop segment directly.

Changed `TranscriptedConstants.dictationAutoEnterDelay`:

- From `200ms` to `150ms`.
- This still leaves the auto-enter keypress after the `120ms` clipboard restore delay.

## Tested Knobs

Model eager warmup:

- Lazy launch did not load the model after 4 seconds.
- Lazy first dictation fast-start was 142ms.
- `TRANSCRIPTED_EAGER_MODEL_WARMUP=1` loaded the cached model 133ms after launch.
- Eager first dictation fast-start was 134ms.
- Decision: do not make eager warmup default from this evidence. The 8ms win is below the 10% meaningful-win bar, and it moves model work into launch.

Paste/save ordering:

- Paste p95 was 3ms.
- Save p95 was 2ms.
- Decision: rule out as a first tuning knob. It is not the slow edge.

Model load poll interval:

- Current 200ms poll: model-ready-to-recording was 154ms; fast-start was 150ms.
- Temporary 100ms poll: model-ready-to-recording was 148ms; fast-start was 145ms.
- Decision: reject and revert. The 5-6ms change is below the 10% meaningful-win bar.

Meeting throughput:

- Fresh batch: four 38s meetings, all saved.
- Processing times were 847-872ms.
- Fresh batch p95 RTF was 0.023.
- Combined fresh meeting window since 2026-06-01T01:19:00Z: n=5, p95 RTF 0.023.
- Decision: do not tune meeting throughput code from this evidence. The fresh failure did not reproduce.

Auto-enter delay:

- Current 200ms baseline: auto-enter 212ms, stop-to-done 300ms.
- Candidate 150ms: auto-enter 155ms and 157ms, stop-to-done 228ms and 233ms.
- `stop_to_paste` stayed fast at 70-84ms.
- Decision: keep 150ms. It improves the opt-in stop path while preserving clipboard-restore ordering.

## Verification

- `bash build.sh --no-open` passed.
- `bash run-tests.sh` passed 3163 tests.
- `ruby -c scripts/ops/performance-budget.rb` passed.
- `scripts/dev/agent-preflight.sh` passed.
- `python3 -m py_compile scripts/ops/generate-nightly-digest.py && python3 scripts/ops/generate-nightly-digest.py --self-test` passed.
- Fresh-window dictation budget passed with `--events-since 2026-06-01T01:13:00Z`.
- Before auto-enter samples, stop-stage scorer reported `decode_ms` as the slowest default stage, p95 156ms.
- After auto-enter samples, the mixed fresh window reported `auto_enter_ms` as the slowest opt-in stage, p95 157ms.
- Fresh meeting batch budget passed with `--stats-since 2026-06-01T01:37:44Z --min-meeting-samples 4`.

## Test Knobs

Run these one at a time after fresh samples exist:

1. Model warm state: lazy default vs `TRANSCRIPTED_EAGER_MODEL_WARMUP=1`. Tested; rejected as default-on for cached model path.
2. Existing-install model prefetch delay: ruled out for this cached-model speed pass. That path caches files after launch; it does not load the model into memory.
3. Model poll interval: tested 100ms vs 200ms; rejected.
4. Paste and save ordering: ruled out as first knob; measured cost is tiny.
5. Auto-enter delay: tested and kept 150ms.
6. Dictation decode throughput: fresh p95 RTF is 0.016, under the 0.050 budget.
7. Meeting processing throughput: tested with 5 fresh samples; p95 RTF 0.023, so no code tuning needed now.
8. Start tail latency: fresh starts stayed healthy with n=12, p95 155ms, and zero fallback/retry events. Eager warmup and model polling were tested; no code change kept for start.

Update after fresh meeting samples:

- A 56s meeting processed in 692ms.
- Four more 38s meetings processed in 847-872ms.
- Fresh meeting RTF p95 was 0.023.
- This does not reproduce the old full-history 0.065 p95 failure.
- Next meeting step, if we want more confidence, should be a repeatable larger fixture, not a blind code change.

## Score Command

After collecting fresh stop samples:

```bash
ruby scripts/ops/performance-budget.rb \
  --app build/Transcripted.app \
  --allow-missing-parakeet-model \
  --events "$HOME/Library/Application Support/Transcripted/logs/events.jsonl" \
  --events-since 2026-06-01T01:13:00Z \
  --require-dictation-stop-latency-samples 3 \
  --min-transcription-samples 3
```

## Simple Explanation

Think of stop dictation like a relay race.

Before, we only knew the race finished eventually. Now we time each runner. If paste feels slow, we can see whether the slow part was stopping the mic, waiting for the model, turning speech into text, pasting, auto-enter, or saving the Markdown file.

That means the next tuning pass can be boring in the good way: find the biggest slow segment, change one knob, measure again, keep it only if the number improves.
