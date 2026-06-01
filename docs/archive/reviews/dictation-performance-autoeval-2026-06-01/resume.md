# Autoeval Resume: Dictation Performance

- Status: running
- Current best: fresh-window scorer plus fresh dictation and meeting baselines
- Primary metric: p95 stop-to-paste latency, lower is better
- Guardrails: no transcript text, paths, app names, bundle IDs, raw device names, or raw milliseconds off-device; build and fast tests must pass
- Scoring command: `ruby scripts/ops/performance-budget.rb --app build/Transcripted.app --allow-missing-parakeet-model --events "$HOME/Library/Application Support/Transcripted/logs/events.jsonl" --events-since 2026-06-01T01:13:00Z --require-dictation-stop-latency-samples 3 --min-transcription-samples 3`
- Editable surface: dictation stop pipeline timing, analytics buckets, performance-budget checks, small timing constants after fresh samples exist
- Frozen surface: privacy sanitizer, allowlisted analytics policy, build/test gates, local event log format
- Planned knobs: stop timing instrumentation kept; fresh stop baseline captured; model eager warmup tested/rejected for default-on; file prefetch delay not run; model poll interval not run; auto-enter delay not run; paste/save ordering ruled out as first knob; fresh-window scorer kept; dictation fresh RTF passing; meeting fresh RTF passing with one sample
- Last attempt: attempt 5, fresh meeting throughput sample passed with RTF 0.012
- Next attempt: collect more fresh meeting samples or build a repeatable meeting RTF fixture before changing meeting throughput code
- Noise rule: treat changes under 10% as no-change unless repeated samples show the same direction
