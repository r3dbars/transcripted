# Autoeval Resume: Dictation Performance

- Status: complete
- Current best: fresh-window scorer with per-stage stop breakdown, 150ms auto-enter delay, and fresh dictation/meeting baselines
- Primary metric: p95 stop-to-paste latency, lower is better
- Guardrails: no transcript text, paths, app names, bundle IDs, raw device names, or raw milliseconds off-device; build and fast tests must pass
- Scoring command: `ruby scripts/ops/performance-budget.rb --app build/Transcripted.app --allow-missing-parakeet-model --events "$HOME/Library/Application Support/Transcripted/logs/events.jsonl" --events-since 2026-06-01T01:13:00Z --require-dictation-stop-latency-samples 3 --min-transcription-samples 3`
- Editable surface: dictation stop pipeline timing, analytics buckets, performance-budget checks, small timing constants after fresh samples exist
- Frozen surface: privacy sanitizer, allowlisted analytics policy, build/test gates, local event log format
- Planned knobs: stop timing instrumentation kept; fresh stop baseline captured; stop stage scorer kept; model eager warmup tested/rejected for default-on; model poll interval tested/rejected; file prefetch delay ruled out for this cached-model speed pass; auto-enter delay kept at 150ms; paste/save ordering ruled out as first knob; fresh-window scorer kept; dictation fresh RTF passing; meeting fresh RTF passing with 5 fresh samples
- Last attempt: attempt 9, auto-enter delay was kept because it reduced opt-in auto-enter from 212ms to 155-157ms
- Next attempt: optional future work only; build a repeatable larger meeting RTF fixture if more confidence is needed
- Noise rule: treat changes under 10% as no-change unless repeated samples show the same direction
