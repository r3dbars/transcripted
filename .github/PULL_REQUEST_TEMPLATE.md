## Why

<!-- What problem does this change solve? -->

## Product Impact

- Affects: `dictation` / `meetings` / `agent artifacts` / `docs only`
- Lane: `activation` / `dictation reliability` / `meeting reliability` / `release ops` / `agent workflow`
- Why this matters:

## What changed

-

## How I checked it

- [ ] `scripts/dev/agent-preflight.sh`
- [ ] Selected checks from `.agents/test-matrix.yml` for the files changed
- [ ] `bash build.sh --no-open`
- [ ] `bash run-tests.sh`
- [ ] Performance budget passed (`bash build.sh --no-open` runs the bundle gate; for runtime-sensitive changes run `TRANSCRIPTED_RUNTIME_BUDGET=1 bash build.sh --no-open`, which scores your local event log against the ratchet ceilings — a bare `performance-budget.rb --events <log>` scores the aspirational targets the app does not meet yet and is expected to fail)
- [ ] `bash run-integration-smoke.sh` if I touched `Sources/Meeting/` or `Sources/TranscriptedCore/`
- [ ] `swift test` if I touched `Package.swift`, `Sources/TranscriptedCore/`, or the public core seam
- [ ] Manual check:

## Risk Review

- [ ] Privacy / local-first behavior reviewed
- [ ] Storage path or migration impact reviewed
- [ ] Public-facing copy stays concrete and matches current product scope
- [ ] Release/update impact reviewed (`CFBundleShortVersionString`, `docs/appcast.xml`, or user-facing caveats if applicable)
- [ ] Agent PRs link the issue/workpad and stay draft until human review
- [ ] UI changes include sanitized `.agent-review/visuals/` evidence
- [ ] No private transcripts, audio, tokens, personal paths, or customer data are included

## Notes

<!-- Related issues, follow-ups, screenshots, or legacy-branch impact -->

## Agent handoff

<!-- For delegated work, paste the one-line closeout from docs/agent-closeout.md. -->

`COORD_DONE: GREEN/BRIEF/RED | PR URL if any | changes made | GitHub cleanup recommendations | decisions needed | tests/checks run | smallest next action`
