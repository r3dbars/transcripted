# Autoeval Resume: Dictation Performance

- Status: ready for fresh samples
- Current best: stop latency instrumentation, verified by build and fast tests
- Primary metric: p95 stop-to-paste latency, lower is better
- Guardrails: no transcript text, paths, app names, bundle IDs, raw device names, or raw milliseconds off-device; build and fast tests must pass
- Scoring command: `ruby scripts/ops/performance-budget.rb --app build/Transcripted.app --allow-missing-parakeet-model --events "$HOME/Library/Application Support/Transcripted/logs/events.jsonl" --stats "$HOME/Library/Application Support/Transcripted/state/stats.sqlite" --require-dictation-stop-latency-samples 3`
- Editable surface: dictation stop pipeline timing, analytics buckets, performance-budget checks, small timing constants after fresh samples exist
- Frozen surface: privacy sanitizer, allowlisted analytics policy, build/test gates, local event log format
- Planned knobs: stop timing instrumentation kept; model eager warmup not run; file prefetch delay not run; model poll interval not run; auto-enter delay not run; paste/save ordering not run; dictation and meeting RTF tuning not run
- Last attempt: attempt 1, kept; `bash build.sh --no-open` passed; `bash run-tests.sh` passed 3158 tests
- Next attempt: collect at least 3 fresh stop samples, then tune the largest measured segment
- Noise rule: treat changes under 10% as no-change unless repeated samples show the same direction
