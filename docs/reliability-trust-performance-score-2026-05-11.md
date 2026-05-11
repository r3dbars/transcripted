# Transcripted Reliability, Trust, and Performance Score

Date: 2026-05-11
Branch: `codex/reliability-trust-score-20260511`
Base: `origin/main` at `29925428`

This score is current-state evidence, not vibes. A category cannot be A+ if the
proof is missing, live production still shows current-release failures, or the
latest fix is not shipped.

## Summary

| Area | Weight | Score | Grade | A+ status |
| --- | ---: | ---: | --- | --- |
| Reliability | 45 | 39 | B+ | Blocked |
| Trustworthiness | 40 | 36 | A- | Blocked |
| Performance | 15 | 14 | A | Close |
| Total | 100 | 89 | B+ | Blocked |

## Hard A+ Gates

| Gate | Status | Evidence |
| --- | --- | --- |
| Local build passes | Pass | `bash build.sh` passed; signed app, launch smoke, performance budget OK |
| Fast tests pass | Pass | `bash run-tests.sh` passed, 1727/1727 |
| Integration smoke passes | Pass | `bash run-integration-smoke.sh` passed |
| Core package tests pass | Pass | `swift test` passed, 135/135 |
| Synthetic audio reliability passes | Pass | `bash run-daily-audio-reliability.sh --synthetic --skip-build --no-launch` passed, 72/72 |
| Live release surfaces agree | Pass | `Info.plist`, GitHub latest release, `docs/appcast.xml`, cask, and website download all point at `1.1.34` |
| No current-release production failures | Fail | Sentry has 2 `dictation.microphone_start_timeout` and 2 matching `app.session_stall_detected` events on `transcripted@1.1.34` in the last 24h |
| Product-success telemetry available | Blocked | `POSTHOG_PERSONAL_API_KEY is required` |
| Known open reliability issues closed | Fail | GitHub issue #500 is still open: mic audio recording is quieter |
| Live manual device-change/sleep/wake proof current | Blocked | Only deterministic synthetic audio proof was run in this pass |

## Reliability - 39/45

Strong:

- App build and all automated test layers are green.
- Dictation recovery policy has direct fast-test coverage.
- Wake recovery smoke passed.
- Synthetic failure-state matrix passed 72/72 and answers the required retry/artifact/user-state questions.
- Release `1.1.34` is live and coherent across GitHub, Sparkle, Homebrew, and the website.

Blocked:

- Current release still has a production microphone-start timeout cluster.
- The matching runtime-stall events mean users can still hit a stuck start path.
- Issue #500 remains open for quieter mic audio.
- Manual Bluetooth, input-device change, and sleep/wake checks were not rerun live in this pass.

Patch made:

- Sentry observability events now add safe diagnostic tags for allowlisted events.
- Future timeout/stall events will be searchable by coarse fields like `format_ready`, `recovering`, `start_attempts`, `readiness_refreshes`, `recovery_start_attempts`, `forced_readiness_recoveries`, `input_device_class`, `route_shape`, `trigger`, and bucketed wait time.
- Raw device names, transcript text, audio paths, secrets, URLs, and similar sensitive values stay out of Sentry tags.

## Trustworthiness - 36/40

Strong:

- Local-first storage contract is clear and tested.
- Sentry and analytics payload sanitizers are covered by tests.
- Crash reporting and analytics preferences default on but remain user-controllable.
- Release truth is coherent for `1.1.34`: app metadata, appcast, cask, GitHub release asset, and website download agree.
- Support diagnostics and reliability packets are privacy-safe and coarse.

Blocked:

- PostHog live usage/product-success proof could not be pulled without `POSTHOG_PERSONAL_API_KEY`.
- Current production Sentry failures mean the public app cannot honestly be called fully trustworthy yet.
- The latest observability fix is only on this branch until it is merged and released.

## Performance - 14/15

Strong:

- `bash build.sh` performance budget passed.
- Thin app build is 104.8 MiB expanded.
- Latest release DMG is about 30.7 MB and defaults to runtime model download instead of bundling the large Parakeet model.
- Website download page serves the latest `Transcripted-1.1.34.dmg`.

Gap:

- I did not rerun live UI CPU/RSS sampling or a real meeting transcription RTF benchmark in this pass.

## Commands Run

```bash
git status --short --branch
git log --oneline --decorate -n 12
gh release view --repo r3dbars/transcripted --json tagName,name,publishedAt,assets,url,targetCommitish,isPrerelease,isDraft
gh pr list --repo r3dbars/transcripted --state open --json number,title,headRefName,isDraft,mergeable,reviewDecision,statusCheckRollup,updatedAt,url
/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist
/usr/libexec/PlistBuddy -c "Print CFBundleVersion" Info.plist
/usr/libexec/PlistBuddy -c "Print SUFeedURL" Info.plist
curl -ILs https://transcripted.app/download
curl -Ls https://transcripted.app/download | rg -n "1\\.1\\.34|Transcripted-1\\.1\\.34|github.com/r3dbars/transcripted/releases|Download"
python3 /Users/redbars/.codex/skills/transcripted-health/scripts/github_snapshot.py
python3 /Users/redbars/.codex/skills/transcripted-health/scripts/cloudflare_pages_snapshot.py
python3 /Users/redbars/.codex/skills/transcripted-health/scripts/posthog_snapshot.py
scripts/dev/agent-preflight.sh
bash build-deps.sh --force
bash build.sh
bash run-tests.sh
bash run-integration-smoke.sh
swift test
bash run-daily-audio-reliability.sh --synthetic --skip-build --no-launch
```

## Current Next Loop

1. Merge and release the safe Sentry diagnostic-tag patch so the next production timeout is actually diagnosable.
2. Rerun Sentry after enough `1.1.34+` usage exists; A+ reliability requires zero current-release timeout/stall events.
3. Provide `POSTHOG_PERSONAL_API_KEY` and rerun product-success scoring.
4. Run the live daily audio reliability matrix, especially Bluetooth/input-device change and sleep/wake.
5. Triage issue #500 with fresh retained-audio diagnostics and close or downgrade it with proof.

