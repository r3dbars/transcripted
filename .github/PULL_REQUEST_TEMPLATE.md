## Why

<!-- What problem does this change solve? -->

## Product Impact

- Affects: `dictation` / `meetings` / `agent artifacts` / `docs only`
- Why this matters:

## What changed

-

## How I checked it

- [ ] `bash build.sh`
- [ ] `bash run-tests.sh`
- [ ] Performance budget passed (`bash build.sh` runs the bundle gate; run `scripts/ops/performance-budget.rb --events "$HOME/Library/Application Support/Transcripted/logs/events.jsonl"` for runtime-sensitive changes)
- [ ] `bash run-integration-smoke.sh` if I touched `Sources/Meeting/` or `Sources/TranscriptedCore/`
- [ ] Manual check:

## Risk Review

- [ ] Privacy / local-first behavior reviewed
- [ ] Storage path or migration impact reviewed
- [ ] Public-facing copy stays concrete and matches current product scope
- [ ] Release/update impact reviewed (`CFBundleShortVersionString`, `docs/appcast.xml`, or user-facing caveats if applicable)

## Notes

<!-- Related issues, follow-ups, screenshots, or legacy-branch impact -->
