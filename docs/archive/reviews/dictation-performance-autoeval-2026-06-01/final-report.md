# Autoeval: Dictation Performance

## Verdict

First pass kept one product change: measure the whole stop pipeline precisely.

The app already starts dictation quickly in the normal warm path. The weak spot is that stop used to feel like one black box. Now each stop can say where the time went: mic stop, model wait, decode, cleanup, paste, auto-enter, save, and done.

## Baseline

Historical local logs, before this patch:

- Dictation fast start: n=747, p50=85ms, p90=126ms, p95=203ms, max=1178ms
- Dictation stop-to-paste: n=0, not measured before this patch
- Dictation decode after stop: n=597, p50=0.108s, p90=0.331s, p95=0.466s, max=1.134s
- Dictation RTF: p95=0.056, above the current 0.050 budget
- Meeting RTF: p95=0.065, above the current 0.050 budget

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

## Verification

- `bash build.sh --no-open` passed.
- `bash run-tests.sh` passed 3158 tests.
- `ruby -c scripts/ops/performance-budget.rb` passed.

## Test Knobs

Run these one at a time after fresh samples exist:

1. Model warm state: lazy default vs `TRANSCRIPTED_EAGER_MODEL_WARMUP=1`.
2. Existing-install model prefetch delay: 0s, 5s, 12s, 30s.
3. Model poll interval: 100ms, 200ms, 500ms.
4. Paste and save ordering: measure whether saving Markdown should stay after paste or move farther off the visible path.
5. Auto-enter delay: current 200ms vs shorter values for allowed apps.
6. Dictation decode throughput: reduce p95 RTF from 0.056 toward 0.050 or lower.
7. Meeting processing throughput: reduce p95 RTF from 0.065 toward 0.050 or lower.
8. Start tail latency: investigate the rare >1s starts while keeping p95 under 250ms.

## Score Command

After collecting fresh stop samples:

```bash
ruby scripts/ops/performance-budget.rb \
  --app build/Transcripted.app \
  --allow-missing-parakeet-model \
  --events "$HOME/Library/Application Support/Transcripted/logs/events.jsonl" \
  --stats "$HOME/Library/Application Support/Transcripted/state/stats.sqlite" \
  --require-dictation-stop-latency-samples 3
```

## Simple Explanation

Think of stop dictation like a relay race.

Before, we only knew the race finished eventually. Now we time each runner. If paste feels slow, we can see whether the slow part was stopping the mic, waiting for the model, turning speech into text, pasting, auto-enter, or saving the Markdown file.

That means the next tuning pass can be boring in the good way: find the biggest slow segment, change one knob, measure again, keep it only if the number improves.
